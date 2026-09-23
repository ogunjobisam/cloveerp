set lock_timeout = '30s';

-- =============================================================================
-- 20260923800000  An order moves with what it delivers
-- -----------------------------------------------------------------------------
-- PR6, M1: nodes S2 and S3 of docs/spec/simplification-review.md, as checked
-- against the built database before this was written.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
-- A sales order part-despatched stayed Confirmed: erp.advance_orders_for_
-- delivery() moves an order only when every line is delivered, and the
-- lifecycle had no state for "some of it has gone". Every confirmed order in
-- the demonstration was half delivered. While it read Confirmed it could be
-- cancelled, though goods had left. And nothing ever closed a sales order:
-- the seeders pressed Close by hand.
--
-- ── WHAT VERSION 3 OF THE SALES LIFECYCLE CHANGES ────────────────────────────
--
--   * A state, Part despatched, between Confirmed (or Picking) and
--     Despatched. A part delivery moves the order there; the delivery that
--     completes it moves it on to Despatched. Both moves are the delivery's
--     (erp.advance_orders_for_delivery), not a person's, and no screen
--     draws them. Cancel is a move out of Confirmed only, so an order part
--     despatched cannot be cancelled.
--   * An invoiced order closes itself once every invoice raised for its
--     deliveries is paid or credited: erp.close_sales_order_when_settled(),
--     asked after every move of an invoice, with the authority of the fact
--     (PR4 decision 6), as a purchase order closes on its bill.
--     Close by hand stays a person's move.
--   * Every place that named the states an order can still be delivered
--     from, confirmed and picking, names Part despatched too: the door that
--     raises a delivery, stock demand, the release sequence and the screens.
--
-- Picking stays what it is, a waypoint: nothing allocates stock onto an
-- order in a way that could derive it (the spec's "derive picking from
-- allocation" has nothing to build on), and the moves a person pressed stay
-- as they were.
--
-- ── WHAT CHANGES FOR DOCUMENTS IN FLIGHT ─────────────────────────────────────
--
-- Nothing moves on its own. An order stays on the lifecycle version it
-- started on; an organisation on version 2 is offered version 3 as an
-- upgrade, and a demonstration takes it in its catch-up. The derived close
-- applies to any invoiced order whose invoices are settled, on any version.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- B1. The sales order's lifecycle, version 3, from one helper
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.sales_order_lifecycle_item()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  -- Version 3 of the sales order lifecycle (20260923800000), read by
  -- erp.configure_sales() for a new install and by the upgrade register for
  -- an organisation on an earlier version, so the two cannot disagree.
  select jsonb_build_object('kind','state_machine','key','sales_order','payload',
        jsonb_build_object(
          'code','sales_order','object_type','document','name','Sales order',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','pending_approval','name','Pending approval','sort_order',20),
            jsonb_build_object('code','confirmed','name','Confirmed','is_committed',true,'sort_order',30),
            jsonb_build_object('code','picking','name','Picking','is_committed',true,'sort_order',40),
            jsonb_build_object('code','partially_despatched','name','Part despatched','is_committed',true,'sort_order',45),
            jsonb_build_object('code','despatched','name','Despatched','is_committed',true,'sort_order',50),
            jsonb_build_object('code','invoiced','name','Invoiced','is_committed',true,'sort_order',60),
            jsonb_build_object('code','closed','name','Closed','is_terminal',true,'is_committed',true,'sort_order',70),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','submit','name','Submit','from','draft','to','pending_approval','required_permission','sales.order','effects',jsonb_build_array(jsonb_build_object('kind','require_approval'))),
            jsonb_build_object('code','approve','name','Approve','from','pending_approval','to','confirmed','required_permission','sales.order'),
            jsonb_build_object('code','reject','name','Reject','from','pending_approval','to','draft','required_permission','sales.order'),
            jsonb_build_object('code','pick','name','Start picking','from','confirmed','to','picking','required_permission','sales.despatch'),
            jsonb_build_object('code','despatch','name','Despatch','from','picking','to','despatched','required_permission','sales.despatch'),
            -- A part delivery moves the order on, from where it stands, and the
            -- rest completes it (20260923800000). Made by the delivery, never by
            -- hand: erp.advance_orders_for_delivery().
            jsonb_build_object('code','despatch_part','name','Despatch in part','from','confirmed','to','partially_despatched','required_permission','sales.despatch'),
            jsonb_build_object('code','despatch_part_picked','name','Despatch in part','from','picking','to','partially_despatched','required_permission','sales.despatch'),
            jsonb_build_object('code','despatch_rest','name','Despatch the rest','from','partially_despatched','to','despatched','required_permission','sales.despatch'),
            jsonb_build_object('code','invoice','name','Invoice','from','despatched','to','invoiced','required_permission','sales.invoice'),
            jsonb_build_object('code','close','name','Close','from','invoiced','to','closed','required_permission','sales.order'),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','sales.order'),
            jsonb_build_object('code','cancel_confirmed','name','Cancel','from','confirmed','to','cancelled','required_permission','sales.order'))))
$$;

comment on function erp.sales_order_lifecycle_item() is
  'The sales order''s lifecycle as version 3 of the sales lifecycle installs it '
  '(20260923800000): the configuration item erp.configure_sales() and the upgrade '
  'register both read.';

do $configure$
declare
  v_sig constant text := 'erp.configure_sales(numeric,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$      jsonb_build_object('kind','state_machine','key','sales_order','payload',
        jsonb_build_object(
          'code','sales_order','object_type','document','name','Sales order',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','pending_approval','name','Pending approval','sort_order',20),
            jsonb_build_object('code','confirmed','name','Confirmed','is_committed',true,'sort_order',30),
            jsonb_build_object('code','picking','name','Picking','is_committed',true,'sort_order',40),
            jsonb_build_object('code','despatched','name','Despatched','is_committed',true,'sort_order',50),
            jsonb_build_object('code','invoiced','name','Invoiced','is_committed',true,'sort_order',60),
            jsonb_build_object('code','closed','name','Closed','is_terminal',true,'is_committed',true,'sort_order',70),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','submit','name','Submit','from','draft','to','pending_approval','required_permission','sales.order','effects',jsonb_build_array(jsonb_build_object('kind','require_approval'))),
            jsonb_build_object('code','approve','name','Approve','from','pending_approval','to','confirmed','required_permission','sales.order'),
            jsonb_build_object('code','reject','name','Reject','from','pending_approval','to','draft','required_permission','sales.order'),
            jsonb_build_object('code','pick','name','Start picking','from','confirmed','to','picking','required_permission','sales.despatch'),
            jsonb_build_object('code','despatch','name','Despatch','from','picking','to','despatched','required_permission','sales.despatch'),
            jsonb_build_object('code','invoice','name','Invoice','from','despatched','to','invoiced','required_permission','sales.invoice'),
            jsonb_build_object('code','close','name','Close','from','invoiced','to','closed','required_permission','sales.order'),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','sales.order'),
            jsonb_build_object('code','cancel_confirmed','name','Cancel','from','confirmed','to','cancelled','required_permission','sales.order')))),
$o$;
  v_new constant text := $n$      -- Version 3 (20260923800000), from its one helper.
      erp.sales_order_lifecycle_item(),
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % sales order block found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$configure$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B2. The upgrade register: version 3 for an organisation on version 2
-- ─────────────────────────────────────────────────────────────────────────────

update erp_ref.module_installer
   set current_version = 3,
       description = description
         || ' Version 3 (20260923800000): an order part despatched says so and cannot be '
         || 'cancelled, and an invoiced order closes itself once its invoices are settled.'
 where install_code = 'sales-lifecycle' and current_version = 2;

insert into erp_ref.module_upgrade_item (install_code, to_version, object_kind, object_key, payload, seq)
select 'sales-lifecycle', 3, 'state_machine', 'sales_order',
       (erp.sales_order_lifecycle_item() -> 'payload') - 'entity', 100
on conflict (install_code, to_version, object_kind, object_key)
  do update set payload = excluded.payload, seq = excluded.seq;

do $register$
begin
  if (select current_version from erp_ref.module_installer
       where install_code = 'sales-lifecycle') is distinct from 3 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: the sales lifecycle installer is not at version 3';
  end if;
  if (select count(*) from erp_ref.module_upgrade_item ui
       where ui.install_code = 'sales-lifecycle' and ui.to_version = 3
         and ui.object_kind = 'state_machine' and ui.object_key = 'sales_order'
         and ui.payload = (erp.sales_order_lifecycle_item() -> 'payload') - 'entity') <> 1
     or (select count(*) from erp_ref.module_upgrade_item ui
          where ui.install_code = 'sales-lifecycle' and ui.to_version = 3) <> 1 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: version 3 of the sales lifecycle is not the one item it ships';
  end if;
end
$register$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B3. The demonstration takes version 3 in its catch-up
--
-- As the procurement lifecycle's newer version is taken (20260922380000): in
-- a block of its own, before the trading, a refusal a note.
-- ─────────────────────────────────────────────────────────────────────────────

do $catch_up$
declare
  v_sig constant text := 'erp.demonstration_catch_up()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  -- ── Trading, up to the day this runs or the time this statement has ────────
$o$;
  v_new constant text := $n$  -- ── The sales lifecycle's newer version (20260923800000) ──────────────────
  begin
    if exists (select 1 from erp.module_installation i
                where i.tenant_id = v_tenant and i.install_code = 'sales-lifecycle') then
      if exists (select 1 from erp.plan_module_upgrade('sales-lifecycle')) then
        perform erp.upgrade_module_configuration('sales-lifecycle');
        v_notes := v_notes || to_jsonb(format(
          'The sales lifecycle was upgraded to version %s.',
          (select mi.current_version from erp_ref.module_installer mi
            where mi.install_code = 'sales-lifecycle')));
      end if;
    end if;
  exception when others then
    v_notes := v_notes || to_jsonb(format(
      'The sales lifecycle was not upgraded, so it trades on the version it has: %s', sqlerrm));
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
-- B4. A part delivery moves the order to Part despatched
--
-- By the move its own lifecycle declares from where it stands, as the full
-- delivery's move is found; a lifecycle with none (version 2) leaves the
-- order where it is, as before. The delivery has posted whatever the order
-- does.
-- ─────────────────────────────────────────────────────────────────────────────

do $part$
declare
  v_sig constant text := 'erp.advance_orders_for_delivery(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$    -- A part delivery leaves the order where it is.
    if not v_full then
      continue;
    end if;
$o$;
  v_new constant text := $n$    -- A part delivery moves the order to Part despatched where its
    -- lifecycle declares the move (20260923800000); on one that does not,
    -- it leaves the order where it is, as it always did.
    if not v_full then
      if exists (select 1 from erp.document_line dl
                  where dl.tenant_id = v_tenant and dl.document_id = r.order_id
                    and not dl.is_cancelled and coalesce(dl.quantity_fulfilled, 0) > 0) then
        v_step := null;
        select t.code into v_step
          from erp.object_state os
          join erp.transition t
            on t.tenant_id = os.tenant_id
           and t.state_machine_version_id = os.state_machine_version_id
           and t.from_state_id = os.current_state_id
          join erp.state ts on ts.tenant_id = t.tenant_id and ts.id = t.to_state_id
         where os.tenant_id = v_tenant and os.object_type = 'document' and os.object_id = r.order_id
           and ts.code = 'partially_despatched'
           and not t.is_automatic
         order by t.sort_order, t.code
         limit 1;
        if v_step is not null then
          begin
            perform erp.transition_document(r.order_id, v_step,
                                            format('Delivered in part by %s', v_number));
            v_moved := v_moved + 1;
          exception when others then
            raise warning 'sales order % was delivered in part by %, and stays where it is: %',
              r.order_id, v_number, sqlerrm;
          end;
        end if;
      end if;
      continue;
    end if;
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % part-delivery anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$part$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B5. An order part despatched is still one to deliver
-- ─────────────────────────────────────────────────────────────────────────────

do $deliver$
declare
  v_sig constant text := 'erp.create_delivery_from_order(uuid,jsonb,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  if d.is_cancelled or coalesce(v_state, '') not in ('confirmed', 'picking') then
    raise exception 'CLOVEERP_ORDER_NOT_READY_TO_DELIVER: % is %, and a delivery is created from an order that is confirmed or being picked',
      d.document_number,
      case when d.is_cancelled then 'cancelled' else lower(coalesce(v_state_name, 'not started')) end
      using errcode = '23514',
            hint = 'Submit the order and have it approved first. An order already despatched, invoiced, closed or cancelled takes no new delivery.';
$o$;
  v_new constant text := $n$  if d.is_cancelled or coalesce(v_state, '') not in ('confirmed', 'picking', 'partially_despatched') then
    raise exception 'CLOVEERP_ORDER_NOT_READY_TO_DELIVER: % is %, and a delivery is created from an order that is confirmed, being picked or part despatched',
      d.document_number,
      case when d.is_cancelled then 'cancelled' else lower(coalesce(v_state_name, 'not started')) end
      using errcode = '23514',
            hint = 'Submit the order and have it approved first. An order despatched in full, invoiced, closed or cancelled takes no new delivery.';
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % state anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$deliver$;
do $demand$
declare
  v_sig constant text := 'erp.stock_forecast_lines(uuid,integer)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$       -- Demand is what customers are still owed: orders confirmed or being
       -- picked (20260914076000). A despatched, invoiced or closed order is
       -- not demand, whatever its lines count as fulfilled.
       and exists (select 1
                     from erp.object_state os
                     join erp.state s on s.id = os.current_state_id
                    where os.tenant_id = d.tenant_id and os.object_type = 'document'
                      and os.object_id = d.id and s.code in ('confirmed', 'picking'))
$o$;
  v_new constant text := $n$       -- Demand is what customers are still owed: orders confirmed, being
       -- picked or part despatched (20260914076000, 20260923800000). A despatched, invoiced or closed order is
       -- not demand, whatever its lines count as fulfilled.
       and exists (select 1
                     from erp.object_state os
                     join erp.state s on s.id = os.current_state_id
                    where os.tenant_id = d.tenant_id and os.object_type = 'document'
                      and os.object_id = d.id and s.code in ('confirmed', 'picking', 'partially_despatched'))
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % demand anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$demand$;
do $release$
declare
  v_sig constant text := 'public.erp_release_sequence(uuid,integer)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$           and s.code in ('confirmed', 'picking')
$o$;
  v_new constant text := $n$           and s.code in ('confirmed', 'picking', 'partially_despatched')
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % release anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$release$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B6. An invoiced order closes itself once its invoices are settled
--
-- The mirror of a purchase order closing on its bill (PR4 decision 6): the
-- fact is read by one function, the close is asked for by one routine with
-- the order and the move named around it, and erp.derived_move_fact() reads
-- the fact again inside the door. The settlement, the credit and the
-- invoicing each ask; asking twice is harmless.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.sales_order_is_settled(p_order_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- Every delivery made against the order is invoiced, and every invoice
  -- raised for them is paid or credited. An order with no delivery, or no
  -- invoice, is not settled.
  with deliveries as (
    select dn.id
      from erp.related_documents(p_order_id, 'fulfils') as f(delivery_id)
      join erp.document dn on dn.tenant_id = erp.current_tenant_id() and dn.id = f.delivery_id
      join erp.document_type dnt on dnt.tenant_id = dn.tenant_id and dnt.id = dn.document_type_id
     where dnt.base_type_code = 'delivery' and not dn.is_cancelled
  ),
  invoices as (
    select distinct iv.id, erp.object_current_state('document', iv.id) as state
      from deliveries d
      cross join lateral erp.related_documents(d.id, 'invoices') as b(invoice_id)
      join erp.document iv on iv.tenant_id = erp.current_tenant_id() and iv.id = b.invoice_id
      join erp.document_type it on it.tenant_id = iv.tenant_id and it.id = iv.document_type_id
     where it.base_type_code = 'invoice_reference' and not iv.is_cancelled
  )
  select exists (select 1 from deliveries)
     and exists (select 1 from invoices)
     and not exists (
       select 1 from deliveries d
        where not exists (
          select 1 from erp.related_documents(d.id, 'invoices') as b(invoice_id)
            join invoices i on i.id = b.invoice_id))
     and not exists (select 1 from invoices i where coalesce(i.state, '') not in ('paid', 'credited'))
$$;

comment on function erp.sales_order_is_settled(uuid) is
  'Whether every delivery of a sales order is invoiced and every such invoice paid or '
  'credited (20260923800000): the fact an invoiced order closes on.';

create or replace function erp.close_sales_order_when_settled(p_order_id uuid, p_reason text)
returns boolean
language plpgsql
set search_path = ''
as $$
begin
  if erp.object_current_state('document', p_order_id) is distinct from 'invoiced'
     or not erp.sales_order_is_settled(p_order_id) then
    return false;
  end if;

  -- The close is the system's, derived from the settled invoices, so it does
  -- not wait for somebody who may close orders. Named immediately before the
  -- move and cleared immediately after; erp.derived_move_fact() reads the
  -- fact again inside the door. The cash or the credit is already committed:
  -- an order that still cannot close is recorded, not undone for.
  begin
    perform set_config('erp.deriving_move', p_order_id::text || ':close', true);
    perform erp.transition_document(p_order_id, 'close', p_reason);
    perform set_config('erp.deriving_move', '', true);
    return true;
  exception when others then
    perform set_config('erp.deriving_move', '', true);
    perform erp.append_event(
      'document.progress_not_advanced', 'document', p_order_id,
      jsonb_build_object('transition', 'close', 'reason', sqlerrm),
      null, null);
    return false;
  end;
end $$;

comment on function erp.close_sales_order_when_settled(uuid, text) is
  'Closes an invoiced sales order whose invoices are all paid or credited, with the '
  'authority of the fact (20260923800000). Asked for after every move of an invoice.';

create or replace function erp.close_sales_orders_for_invoice(p_invoice_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_number text;
  r        record;
  v_closed integer := 0;
begin
  select d.document_number into v_number
    from erp.document d where d.tenant_id = v_tenant and d.id = p_invoice_id;
  for r in
    select distinct od.id as order_id
      from erp.related_documents(p_invoice_id, 'invoices') as billed(delivery_id)
      join erp.document dn on dn.tenant_id = v_tenant and dn.id = billed.delivery_id
      join erp.document_type dnt on dnt.tenant_id = dn.tenant_id and dnt.id = dn.document_type_id
      cross join lateral erp.related_documents(dn.id, 'fulfils') as fulfilled(order_id)
      join erp.document od on od.tenant_id = v_tenant and od.id = fulfilled.order_id
      join erp.document_type odt on odt.tenant_id = od.tenant_id and odt.id = od.document_type_id
     where dnt.base_type_code = 'delivery'
       and odt.base_type_code = 'sales_order'
       and not od.is_cancelled
  loop
    if erp.close_sales_order_when_settled(r.order_id, format('Settled with %s', coalesce(v_number, 'its invoice'))) then
      v_closed := v_closed + 1;
    end if;
  end loop;
  return v_closed;
end $$;

comment on function erp.close_sales_orders_for_invoice(uuid) is
  'Asks each sales order an invoice bills to close itself if it is now settled '
  '(20260923800000).';

create or replace function erp.derived_move_fact(p_object_type text, p_object_id uuid, p_transition_code text)
returns text
language sql
stable
set search_path = ''
as $function$
  -- The fact a move is derived from, when the system is making it, and null
  -- in every other case (decision 6, 20260922380000). Two moves, each asked
  -- for by one routine, which names the document and the move in
  -- erp.deriving_move immediately before it asks and clears it immediately
  -- after:
  --
  --   a purchase order's close   erp.close_order_when_settled(), from the
  --                              bill, the receipt and the received hook
  --   a requisition's order      erp.convert_document()
  --   a sales order's close      erp.close_sales_order_when_settled(), from
  --                              the settlement, the credit and the invoice
  --
  -- The routine's own test is not trusted. The fact is read again here, by
  -- the same two functions, with the object's state row already locked by
  -- erp.perform_transition(). Any other move, object or document type, a
  -- cancelled document and a fact that no longer holds return null, and the
  -- person's own permission is all there is, as it always was.
  select case
           when dt.base_type_code = 'purchase_order' and p_transition_code = 'close'
            and erp.object_current_state('document', p_object_id) = 'received'
            and erp.order_is_settled(p_object_id)
             then 'erp.order_is_settled'
           when dt.base_type_code = 'requisition' and p_transition_code = 'order'
            and erp.document_is_fully_converted(p_object_id)
             then 'erp.document_is_fully_converted'
           -- A sales order's close, from its settled invoices (20260923800000),
           -- asked for by erp.close_sales_order_when_settled().
           when dt.base_type_code = 'sales_order' and p_transition_code = 'close'
            and erp.object_current_state('document', p_object_id) = 'invoiced'
            and erp.sales_order_is_settled(p_object_id)
             then 'erp.sales_order_is_settled'
         end
    from erp.document d
    join erp.document_type dt
      on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
   where p_object_type = 'document'
     and coalesce(current_setting('erp.deriving_move', true), '')
           = p_object_id::text || ':' || p_transition_code
     and d.tenant_id = erp.current_tenant_id()
     and d.id = p_object_id
     and not d.is_cancelled
$function$;

do $hook$
declare
  v_sig constant text := 'erp.transition_document(uuid,text,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  if dt.base_type_code = 'invoice_reference' then
    perform erp.close_orders_billed_by(p_document_id);
  end if;
$o$;
  v_new constant text := $n$  if dt.base_type_code = 'invoice_reference' then
    perform erp.close_orders_billed_by(p_document_id);
    -- And a sales order is closed by the invoices that settle it
    -- (20260923800000): after every move of an invoice, so a payment, a
    -- credit or the issue that completes the order's invoicing is what
    -- closes it, whichever route made the move. The routine reads each
    -- order afresh and does nothing to one not invoiced and settled.
    perform erp.close_sales_orders_for_invoice(p_document_id);
  end if;
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % bill anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$hook$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B7. The register: the three part-despatch moves are the delivery's
--
-- Restated whole, from 20260923500000, so the register the screens are
-- checked against (src/lib/stage-records.test.ts) is the one the database
-- holds. Close stays a screen's: a person may still close an order by hand.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.transition_driver_register()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_agg(to_jsonb(x) order by x.machine_code, x.transition_code)
    from (values
      -- ── Procurement ───────────────────────────────────────────────────────
      ('requisition'::text,  'submit'::text,           'screen'::text, ''::text),
      ('requisition',        'approve',                'screen', ''),
      ('requisition',        'reject',                 'screen', ''),
      -- Ordered because an order was raised from all of it (20260922360000).
      -- The routine's move takes its authority from that fact, whatever
      -- permission the organisation puts on the move (PR4 decision 6, D8,
      -- 20260922380000); the permission governs only a move made by hand.
      ('requisition',        'order',                  'routine', 'erp.convert_document(uuid,uuid,uuid,jsonb,text)'),
      ('requisition',        'cancel',                 'screen', ''),
      ('requisition',        'cancel_submitted',       'screen', ''),

      ('purchase_order',     'submit',                 'screen', ''),
      ('purchase_order',     'approve',                'screen', ''),
      -- Approved with its requisition, by the conversion that raises it and
      -- by nothing else (20260922380000).
      ('purchase_order',     'inherit_approval',       'routine', 'erp.convert_document(uuid,uuid,uuid,jsonb,text)'),
      ('purchase_order',     'reject',                 'screen', ''),
      ('purchase_order',     'send',                   'screen', ''),
      ('purchase_order',     'receive_partial',        'routine', 'erp.advance_orders_for_receipt(uuid)'),
      -- The receipt makes it, and a person may, with a reason, when nothing
      -- more is coming (20260922360000).
      ('purchase_order',     'receive_rest',           'screen', ''),
      ('purchase_order',     'receive_all',            'routine', 'erp.advance_orders_for_receipt(uuid)'),
      -- The bill makes it (erp.close_order_when_settled), and a person may,
      -- with a reason, when the bill is kept elsewhere (20260922360000). The
      -- bill's close takes its authority from erp.order_is_settled(), whatever
      -- permission the organisation puts on the move (PR4 decision 6, D8,
      -- 20260922380000); the permission governs only the close by hand.
      ('purchase_order',     'close',                  'screen', ''),
      ('purchase_order',     'cancel',                 'screen', ''),
      ('purchase_order',     'cancel_approved',        'screen', ''),

      ('goods_receipt',      'post',                   'screen', ''),
      ('goods_receipt',      'cancel',                 'screen', ''),

      ('purchase_invoice',   'register',               'screen', ''),
      ('purchase_invoice',   'dispute',                'screen', ''),
      ('purchase_invoice',   'resolve',                'screen', ''),
      ('purchase_invoice',   'pay',                    'routine', 'erp.settle_paid_document(uuid,text)'),
      ('purchase_invoice',   'cancel',                 'screen', ''),

      ('purchase_credit_note', 'issue',                'screen', ''),
      ('purchase_credit_note', 'cancel',               'screen', ''),

      -- ── Sales ─────────────────────────────────────────────────────────────
      ('quotation',          'send',                   'screen', ''),
      ('quotation',          'accept',                 'routine', 'erp.convert_document(uuid,uuid,uuid,jsonb,text)'),
      ('quotation',          'decline',                'screen', ''),
      ('quotation',          'expire',                 'screen', ''),

      ('sales_order',        'submit',                 'screen', ''),
      ('sales_order',        'approve',                'screen', ''),
      ('sales_order',        'reject',                 'screen', ''),
      ('sales_order',        'pick',                   'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'despatch',               'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'despatch_part',          'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'despatch_part_picked',   'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'despatch_rest',          'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'invoice',                'routine', 'erp.advance_orders_for_invoice(uuid)'),
      ('sales_order',        'close',                  'screen', ''),
      ('sales_order',        'cancel',                 'screen', ''),
      ('sales_order',        'cancel_confirmed',       'screen', ''),

      ('delivery',           'post',                   'screen', ''),
      ('delivery',           'cancel',                 'screen', ''),

      ('sales_invoice',      'issue',                  'routine', 'erp.issue_sales_invoice(uuid,uuid,uuid)'),
      ('sales_invoice',      'settle',                 'routine', 'erp.settle_paid_document(uuid,text)'),
      ('sales_invoice',      'credit',                 'routine', 'erp.credit_invoices_for_credit_note(uuid)'),
      ('sales_invoice',      'cancel',                 'screen', ''),

      ('sales_credit_note',  'issue',                  'screen', ''),
      ('sales_credit_note',  'cancel',                 'screen', ''),

      -- ── Commercial ────────────────────────────────────────────────────────
      ('commercial_quote',   'submit',                 'screen', ''),
      ('commercial_quote',   'approve',                'screen', ''),
      ('commercial_quote',   'reject',                 'screen', ''),
      ('commercial_quote',   'issue',                  'screen', ''),
      ('commercial_quote',   'accept',                 'screen', ''),
      ('commercial_quote',   'decline',                'screen', ''),
      ('commercial_quote',   'expire',                 'screen', ''),
      ('commercial_quote',   'supersede_draft',        'screen', ''),
      ('commercial_quote',   'supersede_approved',     'screen', ''),
      ('commercial_quote',   'supersede_issued',       'screen', ''),

      -- ── Inventory ─────────────────────────────────────────────────────────
      ('transfer_order',     'approved',               'screen', ''),
      ('transfer_order',     'issued',                 'screen', ''),
      ('transfer_order',     'in_transit',             'screen', ''),
      ('transfer_order',     'received',               'screen', ''),
      ('transfer_order',     'closed',                 'screen', ''),
      ('transfer_order',     'draft_to_discrepancy',   'screen', ''),
      ('transfer_order',     'approved_to_discrepancy','screen', ''),
      ('transfer_order',     'issued_to_discrepancy',  'screen', ''),
      ('transfer_order',     'in_transit_to_discrepancy', 'screen', ''),
      ('transfer_order',     'received_to_discrepancy','screen', ''),
      ('transfer_order',     'discrepancy_to_received','screen', ''),
      ('transfer_order',     'draft_to_cancelled',     'screen', ''),
      ('transfer_order',     'approved_to_cancelled',  'screen', ''),
      ('transfer_order',     'issued_to_cancelled',    'screen', ''),
      ('transfer_order',     'in_transit_to_cancelled','screen', ''),
      ('transfer_order',     'received_to_cancelled',  'screen', ''),

      ('stock_adjustment',   'approve',                'screen', ''),
      ('stock_adjustment',   'post',                   'screen', ''),
      ('stock_adjustment',   'cancel',                 'screen', ''),
      ('stock_adjustment',   'approved_to_cancelled',  'screen', ''),

      -- ── The base content pack's own document lifecycles ───────────────────
      -- Installed by applying the base pack rather than by a module installer
      -- (20260903160000, Starter Content Packs §5.1): the five nothing else
      -- creates, less the transfer order above, which the inventory installer
      -- now ships identically. None of them is left to a door, so the document
      -- page draws every move each one declares.
      ('works_order',          'firmed',                    'screen', ''),
      ('works_order',          'released',                  'screen', ''),
      ('works_order',          'in_progress',               'screen', ''),
      ('works_order',          'completed',                 'screen', ''),
      ('works_order',          'closed',                    'screen', ''),
      ('works_order',          'planned_to_held',           'screen', ''),
      ('works_order',          'firmed_to_held',            'screen', ''),
      ('works_order',          'released_to_held',          'screen', ''),
      ('works_order',          'in_progress_to_held',       'screen', ''),
      ('works_order',          'completed_to_held',         'screen', ''),
      ('works_order',          'held_to_released',          'screen', ''),
      ('works_order',          'planned_to_cancelled',      'screen', ''),
      ('works_order',          'firmed_to_cancelled',       'screen', ''),
      ('works_order',          'released_to_cancelled',     'screen', ''),
      ('works_order',          'in_progress_to_cancelled',  'screen', ''),
      ('works_order',          'completed_to_cancelled',    'screen', ''),
      ('works_order',          'planned_to_scrapped',       'screen', ''),
      ('works_order',          'firmed_to_scrapped',        'screen', ''),
      ('works_order',          'released_to_scrapped',      'screen', ''),
      ('works_order',          'in_progress_to_scrapped',   'screen', ''),
      ('works_order',          'completed_to_scrapped',     'screen', ''),
      ('count',                'in_progress',               'screen', ''),
      ('count',                'counted',                   'screen', ''),
      ('count',                'under_review',              'screen', ''),
      ('count',                'approved',                  'screen', ''),
      ('count',                'posted',                    'screen', ''),
      ('count',                'scheduled_to_recount',      'screen', ''),
      ('count',                'in_progress_to_recount',    'screen', ''),
      ('count',                'counted_to_recount',        'screen', ''),
      ('count',                'under_review_to_recount',   'screen', ''),
      ('count',                'approved_to_recount',       'screen', ''),
      ('count',                'recount_to_in_progress',    'screen', ''),
      ('count',                'scheduled_to_cancelled',    'screen', ''),
      ('count',                'in_progress_to_cancelled',  'screen', ''),
      ('count',                'counted_to_cancelled',      'screen', ''),
      ('count',                'under_review_to_cancelled', 'screen', ''),
      ('count',                'approved_to_cancelled',     'screen', ''),
      ('return',               'authorised',                'screen', ''),
      ('return',               'received',                  'screen', ''),
      ('return',               'inspected',                 'screen', ''),
      ('return',               'dispositioned',             'screen', ''),
      ('return',               'closed',                    'screen', ''),
      ('return',               'requested_to_refused',      'screen', ''),
      ('return',               'authorised_to_refused',     'screen', ''),
      ('return',               'received_to_refused',       'screen', ''),
      ('return',               'inspected_to_refused',      'screen', ''),
      ('return',               'dispositioned_to_refused',  'screen', ''),
      ('supplier_invoice',     'matched',                   'screen', ''),
      ('supplier_invoice',     'approved',                  'screen', ''),
      ('supplier_invoice',     'posted',                    'screen', ''),
      ('supplier_invoice',     'received_to_disputed',      'screen', ''),
      ('supplier_invoice',     'matched_to_disputed',       'screen', ''),
      ('supplier_invoice',     'approved_to_disputed',      'screen', ''),
      ('supplier_invoice',     'disputed_to_matched',       'screen', ''),
      ('supplier_invoice',     'received_to_rejected',      'screen', ''),
      ('supplier_invoice',     'matched_to_rejected',       'screen', ''),
      ('supplier_invoice',     'approved_to_rejected',      'screen', '')
    ) as x(machine_code, transition_code, driver, detail)
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B9. Version 2 of the sales order's lifecycle, for the suite that compares
--
-- The configuration item erp.configure_sales() installed before this, as it
-- stood. Tests only.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.sales_order_v2_item()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select
      jsonb_build_object('kind','state_machine','key','sales_order','payload',
        jsonb_build_object(
          'code','sales_order','object_type','document','name','Sales order',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','pending_approval','name','Pending approval','sort_order',20),
            jsonb_build_object('code','confirmed','name','Confirmed','is_committed',true,'sort_order',30),
            jsonb_build_object('code','picking','name','Picking','is_committed',true,'sort_order',40),
            jsonb_build_object('code','despatched','name','Despatched','is_committed',true,'sort_order',50),
            jsonb_build_object('code','invoiced','name','Invoiced','is_committed',true,'sort_order',60),
            jsonb_build_object('code','closed','name','Closed','is_terminal',true,'is_committed',true,'sort_order',70),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','submit','name','Submit','from','draft','to','pending_approval','required_permission','sales.order','effects',jsonb_build_array(jsonb_build_object('kind','require_approval'))),
            jsonb_build_object('code','approve','name','Approve','from','pending_approval','to','confirmed','required_permission','sales.order'),
            jsonb_build_object('code','reject','name','Reject','from','pending_approval','to','draft','required_permission','sales.order'),
            jsonb_build_object('code','pick','name','Start picking','from','confirmed','to','picking','required_permission','sales.despatch'),
            jsonb_build_object('code','despatch','name','Despatch','from','picking','to','despatched','required_permission','sales.despatch'),
            jsonb_build_object('code','invoice','name','Invoice','from','despatched','to','invoiced','required_permission','sales.invoice'),
            jsonb_build_object('code','close','name','Close','from','invoiced','to','closed','required_permission','sales.order'),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','sales.order'),
            jsonb_build_object('code','cancel_confirmed','name','Cancel','from','confirmed','to','cancelled','required_permission','sales.order'))))
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- B10. The suites version 3 changes the answer for
--
-- A part delivery on version 3 moves the order to Part despatched, where the
-- delivery and demonstration suites pinned Picking and Confirmed; and two
-- upgrade suites pinned the sales lifecycle's current version as 2 where
-- they mean "its current version". Each keeps its cases.
-- ─────────────────────────────────────────────────────────────────────────────

do $dfo$
declare
  v_sig constant text := 'erp_test.delivery_from_order_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a0 constant text := $o$  case_name := 'posting the part delivery counts it on the order line and leaves the order being picked';
  passed := coalesce(v_state is null and v_so2_mid_done = 8 and v_so2_mid = 'picking', false);$o$;
  b0 constant text := $n$  case_name := 'posting the part delivery counts it on the order line and moves the order being picked to part despatched';
  passed := coalesce(v_state is null and v_so2_mid_done = 8 and v_so2_mid = 'partially_despatched', false);$n$;
  n integer;
begin
  foreach n in array array[
      (length(v_def) - length(replace(v_def, a0, ''))) / length(a0)] loop
    if n <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % part delivery anchor found % time(s)', v_sig, n;
    end if;
  end loop;
  execute replace(v_def, a0, b0);
end
$dfo$;
do $dhs$
declare
  v_sig constant text := 'erp_test.demo_history_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a0 constant text := $o$not in ('cancelled', 'pending_approval', 'confirmed', 'despatched', 'invoiced', 'closed'))$o$;
  b0 constant text := $n$not in ('cancelled', 'pending_approval', 'confirmed', 'partially_despatched', 'despatched', 'invoiced', 'closed'))$n$;
  a1 constant text := $o$  -- ── 8h. The month despatches part of an order ──────────────────────────────
  v_cases := v_cases + 1;
  select count(*), coalesce(sum(x.left_over), 0) into v_n, v_left
    from (select (select coalesce(sum(dl.open_quantity), 0)
                    from erp.deliverable_lines(o.id) dl) as left_over
            from erp.document o
            join erp.document_type ot on ot.tenant_id = o.tenant_id and ot.id = o.document_type_id
           where o.tenant_id = v_tenant and ot.code = 'sales_order'
             and erp.object_current_state('document', o.id) = 'confirmed'
             and exists (select 1 from erp.document_relation fr
                          where fr.tenant_id = o.tenant_id and fr.to_document_id = o.id
                            and fr.relation_kind = 'fulfils' and fr.to_line_id is not null)) x;
  return query select 'the month despatches part of an order: on a Thursday half of it leaves, the order stays confirmed with the rest to deliver, stock and cost of sales move by what left and no more, and what left is what is billed'::text,
    v_n >= 1 and v_left > 0
    and not exists (
      select 1
        from erp.document o
        join erp.document_type ot on ot.tenant_id = o.tenant_id and ot.id = o.document_type_id
        join erp.document_relation fr
          on fr.tenant_id = o.tenant_id and fr.to_document_id = o.id
         and fr.relation_kind = 'fulfils' and fr.to_line_id is not null
        join erp.document dn on dn.tenant_id = fr.tenant_id and dn.id = fr.from_document_id
        join erp.document_line ol on ol.tenant_id = fr.tenant_id and ol.id = fr.to_line_id
       where o.tenant_id = v_tenant and ot.code = 'sales_order'
         and erp.object_current_state('document', o.id) = 'confirmed'
         and (   extract(isodow from dn.document_date) <> 4
$o$;
  b1 constant text := $n$  -- ── 8h. The month despatches part of an order (part despatched since 20260923800000) ──────────────────────────────
  v_cases := v_cases + 1;
  select count(*), coalesce(sum(x.left_over), 0) into v_n, v_left
    from (select (select coalesce(sum(dl.open_quantity), 0)
                    from erp.deliverable_lines(o.id) dl) as left_over
            from erp.document o
            join erp.document_type ot on ot.tenant_id = o.tenant_id and ot.id = o.document_type_id
           where o.tenant_id = v_tenant and ot.code = 'sales_order'
             and erp.object_current_state('document', o.id) = 'partially_despatched'
             and exists (select 1 from erp.document_relation fr
                          where fr.tenant_id = o.tenant_id and fr.to_document_id = o.id
                            and fr.relation_kind = 'fulfils' and fr.to_line_id is not null)) x;
  return query select 'the month despatches part of an order: on a Thursday half of it leaves, the order reads part despatched with the rest to deliver, stock and cost of sales move by what left and no more, and what left is what is billed'::text,
    v_n >= 1 and v_left > 0
    and not exists (
      select 1
        from erp.document o
        join erp.document_type ot on ot.tenant_id = o.tenant_id and ot.id = o.document_type_id
        join erp.document_relation fr
          on fr.tenant_id = o.tenant_id and fr.to_document_id = o.id
         and fr.relation_kind = 'fulfils' and fr.to_line_id is not null
        join erp.document dn on dn.tenant_id = fr.tenant_id and dn.id = fr.from_document_id
        join erp.document_line ol on ol.tenant_id = fr.tenant_id and ol.id = fr.to_line_id
       where o.tenant_id = v_tenant and ot.code = 'sales_order'
         and erp.object_current_state('document', o.id) = 'partially_despatched'
         and (   extract(isodow from dn.document_date) <> 4
$n$;
  n integer;
begin
  foreach n in array array[
      (length(v_def) - length(replace(v_def, a0, ''))) / length(a0),
      (length(v_def) - length(replace(v_def, a1, ''))) / length(a1)] loop
    if n <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % part despatch anchor found % time(s)', v_sig, n;
    end if;
  end loop;
  execute replace(replace(v_def, a0, b0), a1, b1);
end
$dhs$;
do $dmcu$
declare
  v_sig constant text := 'erp_test.demonstration_module_catch_up_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a0 constant text := $o$  passed := v_stopped_notes is null
        and (select i.installer_version from erp.module_installation i
              where i.tenant_id = v_tenant and i.install_code = 'sales-lifecycle') = 2
$o$;
  b0 constant text := $n$  passed := v_stopped_notes is null
        and (select i.installer_version from erp.module_installation i
              where i.tenant_id = v_tenant and i.install_code = 'sales-lifecycle')
            = (select mi.current_version from erp_ref.module_installer mi
                where mi.install_code = 'sales-lifecycle')
$n$;
  n integer;
begin
  foreach n in array array[
      (length(v_def) - length(replace(v_def, a0, ''))) / length(a0)] loop
    if n <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % current version anchor found % time(s)', v_sig, n;
    end if;
  end loop;
  execute replace(v_def, a0, b0);
end
$dmcu$;
do $pmu$
declare
  v_sig constant text := 'erp_test.plan_module_upgrade_finds_posting_rule_accounts_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a0 constant text := $o$        and (select i.installer_version from erp.module_installation i
              where i.tenant_id = v_tenant and i.install_code = 'sales-lifecycle') = 2;$o$;
  b0 constant text := $n$        and (select i.installer_version from erp.module_installation i
              where i.tenant_id = v_tenant and i.install_code = 'sales-lifecycle')
            = (select mi.current_version from erp_ref.module_installer mi
                where mi.install_code = 'sales-lifecycle');$n$;
  n integer;
begin
  foreach n in array array[
      (length(v_def) - length(replace(v_def, a0, ''))) / length(a0)] loop
    if n <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % current version anchor found % time(s)', v_sig, n;
    end if;
  end loop;
  execute replace(v_def, a0, b0);
end
$pmu$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B8. The proof: erp_test.sales_order_progress_suite
--
-- An organisation with the demonstration's configuration and two
-- administrators, as the cash settlement suite stands one up: an order part despatched says so and cannot be cancelled,
-- the rest completes it, and settling its invoices closes it. Undone at the
-- end.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.sales_order_progress_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_hex   text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1      uuid := gen_random_uuid();
  a2      uuid := gen_random_uuid();
  r       record;
  res     jsonb;
  v_second uuid; v_tok text;
  v_uom uuid; v_site uuid; v_sup uuid; v_cust uuid; v_item uuid; v_grn uuid;
  v_ver integer; v_states text; v_moves text;
  v_so uuid; v_l uuid; v_dn1 uuid; v_dn2 uuid; v_inv1 uuid; v_inv2 uuid;
  v_s1 text; v_s2 text; v_s3 text; v_s4 text; v_s5 text;
  v_cancel boolean; v_err text; v_log text; v_plan integer;
  v_pk uuid; v_pkl uuid; v_pk_state text;
begin
  begin
    select * into r from erp.provision_tenant(
      'zz-sop-' || v_hex, 'Sales order progress suite',
      'admin@zz-sop-' || v_hex || '.test', 'Progress Admin');
    update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@zz-sop-' || v_hex || '.test'), (a2, 'second@zz-sop-' || v_hex || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    perform erp.ensure_demo_configuration(r.tenant_id, r.admin_user_id);
    res := public.erp_invite_principal('second@zz-sop-' || v_hex || '.test', 'Second Admin');
    v_second := (res ->> 'app_user_id')::uuid;
    v_tok := res ->> 'token';
    perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    select s.id into v_site from erp.site s
     where s.tenant_id = r.tenant_id and s.entity_id = r.entity_id order by s.code limit 1;
    select u.id into v_uom from erp.uom u
     where u.tenant_id = r.tenant_id and u.is_base and u.uom_class = 'quantity' and u.status = 'active'
     order by u.code limit 1;
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'ZSOSUP', 'Progress Suite Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'ZSOCUS', 'Progress Suite Customer', 'active') returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, attributes, status)
    values (r.tenant_id, v_cust, 'customer', jsonb_build_object('credit_limit_minor', 100000000), 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'ZSOWID', 'Progress Suite Widget', v_uom, 'active') returning id into v_item;
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_item, 100, 1000, 'the stock');
    perform erp.transition_document(v_grn, 'post', 'sales order progress suite');

    -- 1. A new install is version 3.
    select i.installer_version into v_ver from erp.module_installation i
     where i.tenant_id = r.tenant_id and i.install_code = 'sales-lifecycle';
    select string_agg(s.code, ',' order by s.sort_order) into v_states
      from erp.state s
      join erp.state_machine_version v on v.id = s.state_machine_version_id and v.status = 'active'
      join erp.state_machine m on m.id = v.state_machine_id
     where m.tenant_id = r.tenant_id and m.code = 'sales_order';
    return query select 'a new install is version 3 of the sales lifecycle, with a state for an order part despatched',
      v_ver = 3 and v_states like '%picking,partially_despatched,despatched%',
      format('version %s; states %s', coalesce(v_ver::text, 'none'), v_states);

    -- 2. A part delivery moves a confirmed order to Part despatched, and it
    --    can no longer be cancelled.
    v_so := erp.open_document('sales_order', v_cust, null, v_site);
    v_l := erp.add_document_line(v_so, v_item, 20, 2500, 'Twenty widgets');
    perform erp.transition_document(v_so, 'submit', 'sales order progress suite');
    perform erp_test.approve_document(v_so, 'sales order progress suite');
    v_s1 := erp.object_current_state('document', v_so);
    v_dn1 := (erp.create_delivery_from_order(
      v_so, jsonb_build_array(jsonb_build_object('line_id', v_l, 'quantity', 8))) ->> 'document_id')::uuid;
    perform erp.transition_document(v_dn1, 'post', 'sales order progress suite');
    v_s2 := erp.object_current_state('document', v_so);
    select exists (select 1 from erp.available_transitions('document', v_so) t
                    where t.to_state = 'cancelled') into v_cancel;
    begin
      perform erp.transition_document(v_so, 'cancel_confirmed', 'suite');
      v_err := 'cancelled';
    exception when others then v_err := split_part(sqlerrm, ':', 1); end;
    return query select 'a part delivery moves a confirmed order to part despatched, and it can no longer be cancelled',
      v_s1 = 'confirmed' and v_s2 = 'partially_despatched' and not v_cancel and v_err <> 'cancelled',
      format('%s, then %s; cancel offered %s; pressed: %s', v_s1, v_s2, v_cancel, v_err);

    -- 3. It is still demand, and takes the delivery for the rest.
    v_dn2 := (erp.create_delivery_from_order(v_so) ->> 'document_id')::uuid;
    perform erp.transition_document(v_dn2, 'post', 'sales order progress suite');
    v_s3 := erp.object_current_state('document', v_so);
    select string_agg(l.transition_code || ':' || coalesce(l.reason, ''), ' / ' order by l.occurred_at)
      into v_log
      from erp.state_transition_log l
     where l.tenant_id = r.tenant_id and l.object_type = 'document' and l.object_id = v_so
       and l.transition_code like 'despatch%';
    return query select 'an order part despatched takes a delivery for the rest, which moves it to despatched',
      v_s3 = 'despatched' and v_log like 'despatch_part:Delivered in part by %' and v_log like '%despatch_rest:Delivered in full by %',
      format('%s; %s', v_s3, v_log);

    -- 4. An order being picked, delivered in part, reads Part despatched.
    v_pk := erp.open_document('sales_order', v_cust, null, v_site);
    v_pkl := erp.add_document_line(v_pk, v_item, 10, 2500, 'Ten widgets');
    perform erp.transition_document(v_pk, 'submit', 'sales order progress suite');
    perform erp_test.approve_document(v_pk, 'sales order progress suite');
    perform erp.transition_document(v_pk, 'pick', 'sales order progress suite');
    perform erp.transition_document((erp.create_delivery_from_order(
      v_pk, jsonb_build_array(jsonb_build_object('line_id', v_pkl, 'quantity', 4))) ->> 'document_id')::uuid,
      'post', 'sales order progress suite');
    v_pk_state := erp.object_current_state('document', v_pk);
    return query select 'an order being picked, delivered in part, reads part despatched',
      v_pk_state = 'partially_despatched', v_pk_state;

    -- 5. Invoiced, and closed by its settled invoices: not by the first
    --    alone, by both.
    -- Invoiced by the second administrator: the despatcher does not invoice
    -- what they despatched.
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    v_inv1 := erp.invoice_from_delivery(v_dn1);
    perform erp.transition_document(v_inv1, 'issue', 'sales order progress suite');
    v_inv2 := erp.invoice_from_delivery(v_dn2);
    perform erp.transition_document(v_inv2, 'issue', 'sales order progress suite');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_s4 := erp.object_current_state('document', v_so);
    perform erp.apply_cash(v_cust, (select sum(si.debit_minor - si.credit_minor) from erp.subledger_item si
                                     where si.tenant_id = r.tenant_id and si.document_id = v_inv1
                                       and si.control_kind = 'receivable')::bigint,
                           (select d.currency from erp.document d where d.id = v_inv1), 'first remittance', current_date);
    v_s5 := erp.object_current_state('document', v_so);
    perform erp.apply_cash(v_cust, (select sum(si.debit_minor - si.credit_minor) from erp.subledger_item si
                                     where si.tenant_id = r.tenant_id and si.document_id = v_inv2
                                       and si.control_kind = 'receivable')::bigint,
                           (select d.currency from erp.document d where d.id = v_inv2), 'second remittance', current_date);
    select l.reason into v_log
      from erp.state_transition_log l
     where l.tenant_id = r.tenant_id and l.object_type = 'document' and l.object_id = v_so
       and l.transition_code = 'close'
     order by l.occurred_at desc limit 1;
    return query select 'an invoiced order closes itself once every invoice for its deliveries is settled, and not before',
      v_s4 = 'invoiced' and v_s5 = 'invoiced'
      and erp.object_current_state('document', v_so) = 'closed'
      and v_log like 'Settled with %',
      format('invoiced %s; after the first payment %s; after the second %s (%s)', v_s4, v_s5,
             erp.object_current_state('document', v_so), coalesce(v_log, 'no close'));

    -- 6. An organisation on version 2 is offered version 3: the upgrade
    --    register carries the helper's machine, which the version 2 machine
    --    does not hold, so erp.plan_module_upgrade() offers it.
    select count(*) into v_plan
      from erp_ref.module_upgrade_item ui
     where ui.install_code = 'sales-lifecycle' and ui.to_version = 3
       and ui.object_kind = 'state_machine' and ui.object_key = 'sales_order'
       and ui.payload = (erp.sales_order_lifecycle_item() -> 'payload') - 'entity'
       and not ((erp_test.sales_order_v2_item() -> 'payload') @> ui.payload);
    return query select 'an organisation on version 2 of the sales lifecycle is offered version 3 of the sales order''s lifecycle',
      v_plan = 1
      and (erp.sales_order_lifecycle_item() -> 'payload' -> 'states')::text like '%partially_despatched%'
      and (erp_test.sales_order_v2_item() -> 'payload' -> 'states')::text not like '%partially_despatched%',
      format('%s register item(s) a version 2 organisation lacks', v_plan);

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      case_name := 'the suite ran to its end';
      passed := false; detail := left(sqlerrm, 300);
      return next;
    end if;
  end;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant t where t.code = 'zz-sop-' || v_hex);
  detail := 'the organisation, its stock, orders, deliveries and invoices rolled back';
  return next;
end;
$$;

create or replace function erp_test.assert_sales_order_progress_suite()
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
    from erp_test.sales_order_progress_suite() s;
  if v_total <> 7 then
    raise exception 'CLOVEERP_SALES_ORDER_PROGRESS_SUITE_SHRANK: % case(s), expected 7', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  if v_failed > 0 then
    raise exception 'CLOVEERP_SALES_ORDER_PROGRESS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'An order that does not move with what it delivers reads the wrong state to everybody. Read the case that failed.';
  end if;
end;
$$;


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
