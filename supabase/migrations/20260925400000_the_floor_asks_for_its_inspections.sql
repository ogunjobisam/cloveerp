set lock_timeout = '30s';

-- =============================================================================
-- 20260925400000  The floor asks for its inspections
-- -----------------------------------------------------------------------------
-- PR8, M6b: the second half of node M6 of docs/spec/simplification-review.md.
-- M6a (20260925300000) gave quality a door and a release that asks for a
-- signature only where a plan sampled the batch; this half raises the floor's
-- inspections without anybody asking.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
--   * In-process and pre-release inspection were words in the specification
--     and nowhere else. A plan could say trigger point 'in_process' and
--     nothing read it; a works order's output went into quarantine only if
--     its item said so, and nothing was inspected at any operation.
--   * An inspection could not name the works order it was of, so one made on
--     the floor, before there was a batch, could stand between nothing and
--     release.
--
-- ── WHAT CHANGES ─────────────────────────────────────────────────────────────
--
--   * A plan may name the operation it inspects (inspection_plan.
--     operation_code), and an inspection its works order and operation.
--   * In process: completing work at an operation opens an inspection of the
--     order where a plan for the product, or its class, names that operation
--     or none. Once an order operation; a plan for everything never fires on
--     the floor, so nothing is inspected that nobody asked for.
--   * Pre-release: finished goods taken in as a batch open an inspection of
--     the batch where a pre-release plan covers the product, or, for an item
--     quarantined on receipt, the generic one. They go into quarantine where
--     the item says so, where that inspection was raised, or where an
--     in-process inspection of the order is not yet accepted.
--   * The release of a batch reads the inspections of the order that made it,
--     as well as its own: anything but acceptance on the floor stops every
--     batch the order made, and nobody releases a batch whose floor
--     inspection they decided.
--   * Finished goods taken in before an operation a plan names was booked
--     open that operation's inspection then, and wait for it.
--   * Rework or a hold decided on the floor is inspected anew when the
--     operation is booked again, and the new inspection decides.
--   * A batch's audit export carries the floor's inspections too.
--   * Finished goods taken back out cancel the pre-release inspection nobody
--     decided, once none of the batch is left in quarantine.
--   * Output that is not batch-controlled is not held by the floor's
--     inspections: nothing releases stock without a batch.
--   * A batch where it is held is not inspected against a plan for the floor,
--     and an inspection on the floor does not count as an open inspection of
--     the product when one is asked for.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. What a plan and an inspection may name
-- ─────────────────────────────────────────────────────────────────────────────

alter table erp.inspection_plan add column if not exists operation_code text;
comment on column erp.inspection_plan.operation_code is
  'The routing operation an in-process plan inspects, by code; null is any (20260925400000).';

alter table erp.inspection add column if not exists works_order_id uuid;
alter table erp.inspection add column if not exists operation_seq integer;
do $fk$
begin
  if not exists (select 1 from pg_constraint where conname = 'inspection_works_order_fkey') then
    alter table erp.inspection add constraint inspection_works_order_fkey
      foreign key (tenant_id, works_order_id) references erp.works_order (tenant_id, id);
  end if;
end
$fk$;
create index if not exists inspection_tenant_id_works_order_id_idx
  on erp.inspection (tenant_id, works_order_id) where works_order_id is not null;
comment on column erp.inspection.works_order_id is
  'The works order an inspection on the floor was of (20260925400000).';
comment on column erp.inspection.operation_seq is
  'The operation of the works order an in-process inspection was raised at (20260925400000).';

do $promote$
declare
  v_sig constant text := 'erp.apply_change_set_item(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$          characteristics, status)$o$,
    $n$          characteristics, operation_code, status)$n$,
    $o$                coalesce(p -> 'characteristics', '[]'::jsonb), 'active')$o$,
    $n$                coalesce(p -> 'characteristics', '[]'::jsonb),
                -- The operation an in-process plan inspects (20260925400000).
                nullif(p ->> 'operation_code', ''), 'active')$n$,
    $o$              characteristics = excluded.characteristics,$o$,
    $n$              characteristics = excluded.characteristics,
              operation_code = excluded.operation_code,$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$promote$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. The plan the floor reads
-- ─────────────────────────────────────────────────────────────────────────────

-- For the product or its class, never for everything: the floor inspects what
-- somebody asked to have inspected. Tied to the site first, the product before
-- its class, and a plan naming the operation before one that names none.
create or replace function erp.production_plan_for(p_item_id uuid, p_site_id uuid, p_trigger text,
                                                   p_operation_code text default null)
returns uuid
language sql
stable
set search_path = ''
as $$
  select p.id
    from erp.inspection_plan p
    join erp.item i on i.tenant_id = p.tenant_id and i.id = p_item_id
   where p.tenant_id = erp.current_tenant_id() and p.status = 'active'
     and p.trigger_point = p_trigger
     and (p.site_id is null or p.site_id = p_site_id)
     and (p.item_id = p_item_id or (p.item_id is null and p.item_class = i.item_class))
     and (p.operation_code is null or p.operation_code = p_operation_code)
   order by (p.site_id is not null) desc, (p.item_id is not null) desc,
            (p.operation_code is not null) desc, p.code
   limit 1
$$;

revoke all on function erp.production_plan_for(uuid, uuid, text, text) from public, anon;

comment on function erp.production_plan_for(uuid, uuid, text, text) is
  'The in-process or pre-release plan for a product at a site and operation: one naming the '
  'product or its class, never one for everything (20260925400000).';

-- The inspections a batch's release rests on: its own, and the floor's of the
-- order that made it.
create or replace function erp.inspections_of_batch(p_batch_id uuid)
returns setof uuid
language sql
stable
set search_path = ''
as $$
  select ins.id from erp.inspection ins
   where ins.tenant_id = erp.current_tenant_id() and ins.batch_id = p_batch_id
  union
  select ins.id from erp.inspection ins
   where ins.tenant_id = erp.current_tenant_id() and ins.batch_id is null
     and ins.works_order_id is not null
     and exists (select 1 from erp.stock_movement m
                  where m.tenant_id = ins.tenant_id and m.works_order_id = ins.works_order_id
                    and m.movement_type = 'production_output' and m.batch_id = p_batch_id)
$$;

revoke all on function erp.inspections_of_batch(uuid) from public, anon;

comment on function erp.inspections_of_batch(uuid) is
  'The inspections a batch''s release rests on: its own, and those on the floor of the works '
  'order that made it (20260925400000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- A3. In process: completing work at an operation
-- ─────────────────────────────────────────────────────────────────────────────

do $book$
declare
  v_sig constant text := 'erp.book_operation_time(uuid,integer,numeric,numeric,numeric)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  v_after  bigint;$o$,
    $n$  v_after  bigint;
  v_op_code text;
  v_plan    uuid;
  v_rule    jsonb;$n$,
    $o$  insert into erp.production_event (
    tenant_id, works_order_id, operation_seq, event_kind, quantity, minutes,$o$,
    $n$  -- Work completed at an operation a plan names opens its inspection
  -- (20260925400000): once an order operation, of the order, before there is
  -- a batch to name; and again once one there was sent for rework or held,
  -- so the work done since is inspected anew.
  if p_completed > 0 then
    select o.code into v_op_code from erp.works_order_operation o
     where o.tenant_id = v_tenant and o.works_order_id = p_works_order_id and o.seq = p_operation_seq;
    v_plan := erp.production_plan_for(wo.item_id, wo.site_id, 'in_process', v_op_code);
    if v_plan is not null and not exists (
         select 1 from erp.inspection ins
          where ins.tenant_id = v_tenant and ins.works_order_id = p_works_order_id
            and ins.operation_seq = p_operation_seq and ins.status <> 'cancelled'
            and ins.disposition not in ('rework', 'quarantine')) then
      select p.sampling_rule into v_rule from erp.inspection_plan p where p.id = v_plan;
      insert into erp.inspection (
        tenant_id, entity_id, site_id, inspection_plan_id, item_id, batch_id, document_id,
        works_order_id, operation_seq, quantity_inspected, sample_size, status, started_at)
      values (v_tenant, wo.entity_id, wo.site_id, v_plan, wo.item_id, null, null,
              p_works_order_id, p_operation_seq, wo.quantity,
              greatest(ceil(erp.sample_size(v_rule, wo.quantity)), 1)::integer, 'planned', now());
    end if;
  end if;

  insert into erp.production_event (
    tenant_id, works_order_id, operation_seq, event_kind, quantity, minutes,$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$book$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A4. Pre-release: finished goods taken in
-- ─────────────────────────────────────────────────────────────────────────────

do $receive$
declare
  v_sig constant text := 'erp.receive_works_order_output(uuid,numeric,text,uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  v_moved   bigint;$o$,
    $n$  v_moved   bigint;
  v_plan    uuid;
  v_rule    jsonb;
  v_hold    boolean;$n$,
    $o$  v_loc := coalesce(p_location_id,
                    erp.default_posting_location(wo.site_id, 'in'));$o$,
    $n$  -- Held for inspection (20260925400000): where the item says so; where a
  -- pre-release plan covers the batch, which opens its inspection; and where
  -- the floor's inspection of the order is not yet accepted. Only a batch is
  -- held, since only a batch is released.
  v_hold := it.quarantine_on_receipt;
  if v_batch is not null then
    v_plan := coalesce(erp.production_plan_for(wo.item_id, wo.site_id, 'pre_release', null),
                       case when it.quarantine_on_receipt
                            then erp.inspection_plan_for(wo.item_id, wo.site_id, 'pre_release') end);
    if v_plan is not null then
      select p.sampling_rule into v_rule from erp.inspection_plan p where p.id = v_plan;
      insert into erp.inspection (
        tenant_id, entity_id, site_id, inspection_plan_id, item_id, batch_id, document_id,
        works_order_id, quantity_inspected, sample_size, status, started_at)
      values (v_tenant, wo.entity_id, wo.site_id, v_plan, wo.item_id, v_batch, null,
              p_works_order_id, p_quantity,
              greatest(ceil(erp.sample_size(v_rule, p_quantity)), 1)::integer, 'planned', now());
      v_hold := true;
    end if;
    -- An operation a plan names that was never booked is still inspected
    -- (found on review: output taken in before the booking went out
    -- available, and a later reject on the floor never reached it).
    insert into erp.inspection (
      tenant_id, entity_id, site_id, inspection_plan_id, item_id, batch_id, document_id,
      works_order_id, operation_seq, quantity_inspected, sample_size, status, started_at)
    select v_tenant, wo.entity_id, wo.site_id, q.plan_id, wo.item_id, null, null,
           p_works_order_id, q.seq, wo.quantity,
           greatest(ceil(erp.sample_size(pl.sampling_rule, wo.quantity)), 1)::integer, 'planned', now()
      from (select o.seq, erp.production_plan_for(wo.item_id, wo.site_id, 'in_process', o.code) as plan_id
              from erp.works_order_operation o
             where o.tenant_id = v_tenant and o.works_order_id = p_works_order_id) q
      join erp.inspection_plan pl on pl.tenant_id = v_tenant and pl.id = q.plan_id
     where not exists (select 1 from erp.inspection ins
                        where ins.tenant_id = v_tenant and ins.works_order_id = p_works_order_id
                          and ins.operation_seq = q.seq and ins.status <> 'cancelled'
                          and ins.disposition not in ('rework', 'quarantine'));
    if exists (select 1 from erp.inspection ins
                where ins.tenant_id = v_tenant and ins.works_order_id = p_works_order_id
                  and ins.batch_id is null and ins.status <> 'cancelled'
                  and ins.disposition not in ('accept', 'accept_with_concession')
                  -- Rework or a hold the floor has since inspected again is
                  -- superseded by that inspection.
                  and (ins.disposition not in ('rework', 'quarantine') or not exists (
                   select 1 from erp.inspection nx
                    where nx.tenant_id = ins.tenant_id and nx.works_order_id = ins.works_order_id
                      and nx.operation_seq is not distinct from ins.operation_seq
                      and nx.batch_id is null and nx.status <> 'cancelled' and nx.id <> ins.id
                      and nx.disposition not in ('rework', 'quarantine')))) then
      v_hold := true;
    end if;
  end if;

  v_loc := coalesce(p_location_id,
                    erp.default_posting_location(wo.site_id, 'in'));$n$,
    $o$          case when it.quarantine_on_receipt then 'quarantine'::erp.stock_status
               else 'available'::erp.stock_status end,$o$,
    $n$          case when v_hold then 'quarantine'::erp.stock_status
               else 'available'::erp.stock_status end,$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$receive$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A5. The release reads the floor's inspections too
-- ─────────────────────────────────────────────────────────────────────────────

do $release$
declare
  v_sig constant text := 'erp.release_batch(uuid,uuid,text,text,uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    -- A plan's inspection on the floor samples the batch as its own does.
    $o$     where ins.tenant_id = v_tenant and ins.batch_id = p_batch_id
       and ins.status <> 'cancelled' and ins.inspection_plan_id is not null);$o$,
    $n$     where ins.tenant_id = v_tenant and ins.id in (select erp.inspections_of_batch(p_batch_id))
       and ins.status <> 'cancelled' and ins.inspection_plan_id is not null);$n$,
    -- The inspection named may be the floor's of the order that made it.
    $o$      if v_named_batch is distinct from p_batch_id then$o$,
    $n$      -- One of the batch's own, or the floor's of the order that made it
      -- (20260925400000).
      if p_inspection_id not in (select erp.inspections_of_batch(p_batch_id)) then$n$,
    $o$                hint = 'Choose one of this batch''s own inspections. A release rests on what was found in the batch released.';$o$,
    $n$                hint = 'Choose one of this batch''s own inspections, or one of the works order that made it. A release rests on what was found in the batch released.';$n$,
    -- Out of specification on the one named, whichever it is.
    $o$       and ins.batch_id = p_batch_id
       and ins.id in (v_last_insp, p_inspection_id)$o$,
    $n$       and ins.id in (v_last_insp, p_inspection_id)$n$,
    -- Undecided on the floor holds the batch as undecided of its own does.
    $o$              where ins.tenant_id = v_tenant and ins.batch_id = p_batch_id and ins.site_id = p_site_id$o$,
    $n$              where ins.tenant_id = v_tenant and ins.id in (select erp.inspections_of_batch(p_batch_id))
                and ins.site_id = p_site_id$n$,
    $o$                        'batch', p_batch_id);$o$,
    $n$                        'batch', p_batch_id);

  -- What the release rests on cannot be decided again under it
  -- (20260925400000).
  perform 1 from erp.inspection ins
   where ins.tenant_id = v_tenant and ins.id in (select erp.inspections_of_batch(p_batch_id))
     for share;$n$,
    $o$  -- §5.8: the inspection the receipt raised stands between quarantine and release.$o$,
    $n$  -- The floor's decisions on the order that made the batch (20260925400000).
  -- Anything but acceptance on the floor stands over every batch the order
  -- made, whatever the batch's own inspection later found, until rework or a
  -- hold is inspected again at the operation (found on review: rework was
  -- otherwise final, and cleared only by a concession nobody made); and nobody
  -- releases a batch whose floor inspection they decided (found on review: a
  -- later decision on the floor hid who decided the batch's own).
  declare
    v_floor_order text;
    v_floor_seq   integer;
    v_floor_disp  erp.disposition;
  begin
    select wo.order_number, ins.operation_seq, ins.disposition
      into v_floor_order, v_floor_seq, v_floor_disp
      from erp.inspection ins
      join erp.works_order wo on wo.tenant_id = ins.tenant_id and wo.id = ins.works_order_id
     where ins.tenant_id = v_tenant
       and ins.id in (select erp.inspections_of_batch(p_batch_id))
       and ins.batch_id is null and ins.status <> 'cancelled'
       and ins.disposition not in ('pending', 'accept', 'accept_with_concession')
       -- Rework or a hold is superseded once the floor inspects again.
       and (ins.disposition not in ('rework', 'quarantine') or not exists (
                   select 1 from erp.inspection nx
                    where nx.tenant_id = ins.tenant_id and nx.works_order_id = ins.works_order_id
                      and nx.operation_seq is not distinct from ins.operation_seq
                      and nx.batch_id is null and nx.status <> 'cancelled' and nx.id <> ins.id
                      and nx.disposition not in ('rework', 'quarantine')))
     order by ins.operation_seq nulls last, ins.id
     limit 1;
    if found then
      raise exception 'CLOVEERP_ORDER_INSPECTION_NOT_ACCEPTED: batch % was made by works order %, whose inspection on the floor at operation % was dispositioned %',
        b.batch_number, v_floor_order, coalesce(v_floor_seq::text, '-'), v_floor_disp
        using errcode = '23514',
              hint = 'A decision on the floor stands over every batch the order made. After rework, or once a hold is resolved, book the operation again and inspect it anew; a batch rejected or destroyed on the floor is not released.';
    end if;

    if erp.tenant_is_live(v_tenant) and exists (
         select 1 from erp.inspection ins
          where ins.tenant_id = v_tenant
            and ins.id in (select erp.inspections_of_batch(p_batch_id))
            and ins.batch_id is null and ins.status <> 'cancelled'
            and ins.disposition_by = erp.current_principal_id()) then
      raise exception 'CLOVEERP_BATCH_SELF_RELEASE: you dispositioned the inspection on the floor batch % rests on, so somebody else releases it',
        b.batch_number
        using errcode = '42501',
              hint = 'Ask somebody else who may release batches to review the inspection and sign the release. Nobody releases a batch they dispositioned once the organisation is live.';
    end if;
  end;

  -- §5.8: the inspection the receipt raised stands between quarantine and release.$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$release$;

select erp.register_refusal('CLOVEERP_ORDER_INSPECTION_NOT_ACCEPTED',
  'Releasing a batch made by a works order whose inspection on the floor was decided against it.',
  'A decision on the floor is about everything the order made; the batch''s own inspection cannot overrule it.',
  'After rework, or once a hold is resolved, book the operation again and decide the new inspection there. Rejected or destroyed on the floor, the batch is not released.');

-- A batch's audit export carries the floor's inspections its release rests
-- on, and says which each was of (found on review: a release naming the
-- floor's inspection pointed at one the export left out).
do $audit$
declare
  v_sig constant text := 'erp.batch_audit_export(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$               'at', ins.completed_at, 'disposition', ins.disposition,$o$,
    $n$               'inspection_id', ins.id, 'works_order_id', ins.works_order_id,
               'operation_seq', ins.operation_seq,
               'at', ins.completed_at, 'disposition', ins.disposition,$n$,
    $o$        from erp.inspection ins where ins.batch_id = b.id), '[]'::jsonb),$o$,
    $n$        from erp.inspection ins where ins.id in (select erp.inspections_of_batch(b.id))), '[]'::jsonb),$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$audit$;

-- A plan for the floor is not offered for inspecting a batch where it is
-- held (found on review: asking for an inspection chose the in-process plan).
do $planfor$
declare
  v_sig constant text := 'erp.inspection_plan_for(uuid,uuid,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$     and (p_trigger is null or p.trigger_point = p_trigger)$o$;
  v_new constant text := $n$     and (p.trigger_point = p_trigger
          or (p_trigger is null and p.trigger_point is distinct from 'in_process'))$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$planfor$;

-- An inspection on the floor is of the order, not a second open inspection of
-- the product (found on review: it blocked asking for one of stock without a
-- batch).
do $request$
declare
  v_sig constant text := 'erp.request_inspection(uuid,uuid,uuid,numeric,uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$               or (p_batch_id is null and ins.batch_id is null and ins.item_id = v_item))) then$o$;
  v_new constant text := $n$               or (p_batch_id is null and ins.batch_id is null and ins.item_id = v_item
                   and ins.works_order_id is null))) then$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$request$;

do $list$
declare
  v_sig constant text := 'public.erp_inspections(integer,uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  -- A batch's list carries the floor's inspections of the order that made it,
  -- and every row says which order and operation it was of, so one on the
  -- floor can be told from the batch's own (20260925400000).
  v_pairs constant text[] := array[
    $o$       and (p_batch_id is null or ins.batch_id = p_batch_id)$o$,
    $n$       and (p_batch_id is null or ins.id in (select erp.inspections_of_batch(p_batch_id)))$n$,
    $o$             'batch_id', ins.batch_id,$o$,
    $n$             'batch_id', ins.batch_id,
             'works_order', wo.order_number, 'operation_seq', ins.operation_seq,$n$,
    $o$      left join erp.batch b on b.tenant_id = ins.tenant_id and b.id = ins.batch_id$o$,
    $n$      left join erp.batch b on b.tenant_id = ins.tenant_id and b.id = ins.batch_id
      left join erp.works_order wo on wo.tenant_id = ins.tenant_id and wo.id = ins.works_order_id$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$list$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A6. Finished goods taken back out take their undecided inspection with them
-- ─────────────────────────────────────────────────────────────────────────────

do $reverse$
declare
  v_sig constant text := 'erp.reverse_works_order_output(bigint,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  perform erp.post_works_order_finance(wo.id, 'works_order_output', null, v_new);$o$;
  v_new constant text := $n$  perform erp.post_works_order_finance(wo.id, 'works_order_output', null, v_new);

  -- Nothing of the batch left to decide on: its pre-release inspection, not
  -- yet decided, is cancelled rather than left open over nothing
  -- (20260925400000).
  if m.batch_id is not null and not exists (
       select 1 from erp.stock_balance sb
        where sb.tenant_id = v_tenant and sb.batch_id = m.batch_id and sb.site_id = m.site_id
          and sb.stock_status = 'quarantine' and sb.quantity > 0) then
    update erp.inspection ins
       set status = 'cancelled', updated_at = now()
     where ins.tenant_id = v_tenant and ins.batch_id = m.batch_id and ins.works_order_id = wo.id
       and ins.disposition = 'pending' and ins.status <> 'cancelled';
  end if;$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$reverse$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B1. The proof: erp_test.production_inspection_suite
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.production_inspection_suite()
 returns table(case_name text, passed boolean, detail text)
 language plpgsql
 set search_path to ''
as $function$
declare
  v_hex   text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1 uuid := gen_random_uuid(); a2 uuid := gen_random_uuid();
  r       record;
  res     jsonb;
  v_tok   text; v_second uuid;
  csf uuid; csp uuid; csi uuid; csq uuid; csr uuid; v_cs uuid;
  v_uom uuid; v_site uuid; v_recv uuid; v_sup uuid;
  v_fg uuid; v_plain uuid; v_comp uuid; v_bom uuid; v_rout uuid; v_bomp uuid; v_grn uuid;
  v_wo uuid; v_wo2 uuid; v_wo3 uuid; v_wo4 uuid; v_wo5 uuid;
  v_b1 uuid; v_b2 uuid; v_b3 uuid; v_b4 uuid; v_b5 uuid; v_ins uuid; v_pre uuid; v_out bigint;
  v_err2 text;
  v_n integer; v_err text;
begin
  begin
    select * into r from erp.provision_tenant(
      'zz-pis-' || v_hex, 'Production inspection suite', 'a@zz-pis-' || v_hex || '.test', 'Suite Admin');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    res := public.erp_invite_principal('second@zz-pis-' || v_hex || '.test', 'Second Admin');
    v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
    perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');
    csf := erp.configure_finance();
    csp := erp.configure_procurement(100000000);
    csi := erp.configure_inventory('average');
    csq := erp.configure_quality('4 hours', '24 hours');
    csr := erp.configure_production('manual');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok);
    perform erp.approve_change_set(csf); perform erp.promote_change_set(csf);
    perform erp.approve_change_set(csp); perform erp.promote_change_set(csp);
    perform erp.approve_change_set(csi); perform erp.promote_change_set(csi);
    perform erp.approve_change_set(csq); perform erp.promote_change_set(csq);
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
    -- A batch-controlled finished good, not quarantined on receipt of its own
    -- accord; a plain one with no plan; a component.
    insert into erp.item (tenant_id, code, name, stock_uom_id, is_batch_controlled, item_class, status)
    values (r.tenant_id, 'FG', 'Finished good', v_uom, true, 'FG', 'active') returning id into v_fg;
    insert into erp.item (tenant_id, code, name, stock_uom_id, is_batch_controlled, item_class, status)
    values (r.tenant_id, 'PLAIN', 'Plain good', v_uom, true, 'FG', 'active') returning id into v_plain;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'C1', 'Component', v_uom, 'active') returning id into v_comp;
    insert into erp.bom (tenant_id, code, item_id, site_id, version, name, output_quantity, yield_factor, status, effective_from)
    values (r.tenant_id, 'FG-1', v_fg, v_site, 1, 'Finished good', 1, 1, 'active', current_date - 1) returning id into v_bom;
    insert into erp.bom_line (tenant_id, bom_id, seq, component_item_id, quantity, uom_id, scrap_factor, is_phantom)
    values (r.tenant_id, v_bom, 10, v_comp, 1, v_uom, 0, false);
    insert into erp.bom (tenant_id, code, item_id, site_id, version, name, output_quantity, yield_factor, status, effective_from)
    values (r.tenant_id, 'PLAIN-1', v_plain, v_site, 1, 'Plain good', 1, 1, 'active', current_date - 1) returning id into v_bomp;
    insert into erp.bom_line (tenant_id, bom_id, seq, component_item_id, quantity, uom_id, scrap_factor, is_phantom)
    values (r.tenant_id, v_bomp, 10, v_comp, 1, v_uom, 0, false);
    insert into erp.routing (tenant_id, code, item_id, site_id, version, name, status, effective_from)
    values (r.tenant_id, 'FG-R1', v_fg, v_site, 1, 'Make', 'active', current_date - 1) returning id into v_rout;
    insert into erp.routing_operation (tenant_id, routing_id, seq, code, name, work_centre_code,
                                       setup_minutes, run_minutes_per_unit, cost_rate_minor_per_hour)
    values (r.tenant_id, v_rout, 10, 'MIX', 'Mix', 'WC1', 0, 1, 6000),
           (r.tenant_id, v_rout, 20, 'FILL', 'Fill', 'WC1', 0, 1, 6000);
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_comp, 500, 100, 'component');
    perform erp.transition_document(v_grn, 'post');

    -- The plans, promoted: an in-process check at MIX for FG, and a
    -- pre-release check for FG.
    v_cs := erp.create_change_set('pis-plans-' || v_hex, 'Floor plans', 'The suite promotes the floor''s plans.');
    perform erp.add_change_set_item(v_cs, 'inspection_plan', 'fg_mix',
      jsonb_build_object('code', 'fg_mix', 'name', 'Mix check', 'item', 'FG', 'trigger_point', 'in_process',
                         'operation_code', 'MIX', 'sampling_rule', jsonb_build_object('scheme', 'fixed', 'size', 2),
                         'characteristics', jsonb_build_array(jsonb_build_object('code', 'viscosity', 'name', 'Viscosity', 'lower', 1, 'upper', 5))),
      'upsert', null, 'suite');
    perform erp.add_change_set_item(v_cs, 'inspection_plan', 'fg_release',
      jsonb_build_object('code', 'fg_release', 'name', 'Release check', 'item', 'FG', 'trigger_point', 'pre_release',
                         'sampling_rule', jsonb_build_object('scheme', 'fixed', 'size', 1),
                         'characteristics', jsonb_build_array(jsonb_build_object('code', 'label', 'name', 'Label', 'expected', 'correct'))),
      'upsert', null, 'suite');
    perform erp.submit_change_set(v_cs);
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.approve_change_set(v_cs); perform erp.promote_change_set(v_cs);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    -- 1. A promoted plan names its operation.
    return query select 'a promoted in-process plan names the operation it inspects',
      (select ip.operation_code = 'MIX' and ip.item_id = v_fg and ip.trigger_point = 'in_process'
         from erp.inspection_plan ip where ip.tenant_id = r.tenant_id and ip.code = 'fg_mix'),
      (select ip.operation_code from erp.inspection_plan ip where ip.tenant_id = r.tenant_id and ip.code = 'fg_mix');

    -- 2. Work completed at the operation opens one inspection of the order.
    v_wo := erp.raise_works_order(v_fg, v_site, 10);
    perform erp.release_works_order(v_wo);
    perform erp.book_operation_time(v_wo, 10, 5, 5, 0);
    perform erp.book_operation_time(v_wo, 10, 5, 5, 0);
    select ins.id into v_ins from erp.inspection ins where ins.works_order_id = v_wo and ins.operation_seq = 10;
    return query select 'work completed at the operation a plan names opens one inspection of the order, however many bookings',
      (select count(*) from erp.inspection ins where ins.works_order_id = v_wo and ins.operation_seq = 10) = 1
      and (select ins.batch_id is null and ins.sample_size = 2 and ins.quantity_inspected = 10
                  and ins.inspection_plan_id = (select ip.id from erp.inspection_plan ip where ip.tenant_id = r.tenant_id and ip.code = 'fg_mix')
             from erp.inspection ins where ins.id = v_ins),
      (select format('%s inspection(s)', count(*)) from erp.inspection ins where ins.works_order_id = v_wo);

    -- 3. Not at an operation it does not name, and a plan for everything
    -- never fires on the floor.
    perform erp.book_operation_time(v_wo, 20, 5, 5, 0);
    return query select 'work at an operation no plan names opens nothing, and the plan for everything never fires on the floor',
      not exists (select 1 from erp.inspection ins where ins.works_order_id = v_wo and ins.operation_seq = 20)
      and not exists (select 1 from erp.inspection ins
                       join erp.inspection_plan ip on ip.id = ins.inspection_plan_id
                      where ins.works_order_id = v_wo and ip.code = 'goods_in'),
      'FILL booked, nothing raised';

    -- 4. Taken in while the floor's inspection is undecided: held, with its
    -- own pre-release inspection, and its release refused as outstanding.
    perform erp.receive_works_order_output(v_wo, 4, 'FG-A', v_recv);
    select b.id into v_b1 from erp.batch b where b.tenant_id = r.tenant_id and b.batch_number = 'FG-A';
    select ins.id into v_pre from erp.inspection ins where ins.batch_id = v_b1;
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
      perform public.erp_release_batch(v_b1, v_site, 'Looked fine', 'Second Admin');
      v_err := 'released';
    exception when others then v_err := left(sqlerrm, 140); end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    return query select 'finished goods with a pre-release plan, and an undecided floor inspection, are held in quarantine and not released',
      (select sum(sb.quantity) from erp.stock_balance sb where sb.batch_id = v_b1 and sb.stock_status = 'quarantine') = 4
      and (select ins.works_order_id = v_wo and ins.sample_size = 1 from erp.inspection ins where ins.id = v_pre)
      and v_err like 'CLOVEERP_INSPECTION_OUTSTANDING:%',
      v_err;

    -- 5. The release form offers the floor's inspection with the batch's own.
    return query select 'the inspections offered for a batch include the floor''s of the order that made it',
      (select count(*) from jsonb_array_elements(public.erp_inspections(100, v_b1)) e
        where (e ->> 'inspection_id')::uuid in (v_ins, v_pre)) = 2,
      public.erp_inspections(100, v_b1)::text;

    -- 6. A reject on the floor stops every batch the order made, whatever
    -- the batch's own inspection found and whichever was decided last.
    perform erp.record_inspection_result(v_ins, 'viscosity', 9);
    perform erp.disposition_inspection(v_ins, 'reject', 'Too thick');
    perform erp.record_inspection_result(v_pre, 'label', null, 'correct');
    perform erp.disposition_inspection(v_pre, 'accept', null);
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
      perform public.erp_release_batch(v_b1, v_site, 'Label correct', 'Second Admin', v_pre);
      v_err := 'released';
    exception when others then v_err := left(sqlerrm, 140); end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    return query select 'a batch whose order was rejected on the floor is not released, though its own inspection passed',
      v_err like 'CLOVEERP_ORDER_INSPECTION_NOT_ACCEPTED:%', v_err;

    -- 7. A plain good with no plan, and a class that is quarantined on
    -- receipt by default, is taken in available.
    v_wo2 := erp.raise_works_order(v_plain, v_site, 5);
    perform erp.release_works_order(v_wo2);
    perform erp.receive_works_order_output(v_wo2, 5, 'PL-A', v_recv);
    select b.id into v_b2 from erp.batch b where b.tenant_id = r.tenant_id and b.batch_number = 'PL-A';
    return query select 'finished goods no plan covers are taken in available, whatever their class',
      (select sum(sb.quantity) from erp.stock_balance sb where sb.batch_id = v_b2 and sb.stock_status = 'available') = 5
      and not exists (select 1 from erp.inspection ins where ins.batch_id = v_b2),
      'PLAIN in FG class, available';

    -- 8. Taken back out, the undecided pre-release inspection goes with it.
    v_wo3 := erp.raise_works_order(v_fg, v_site, 3);
    perform erp.release_works_order(v_wo3);
    perform erp.receive_works_order_output(v_wo3, 3, 'FG-B', v_recv);
    select b.id into v_b3 from erp.batch b where b.tenant_id = r.tenant_id and b.batch_number = 'FG-B';
    select m.id into v_out from erp.stock_movement m
     where m.works_order_id = v_wo3 and m.movement_type = 'production_output' and m.batch_id = v_b3;
    perform public.erp_reverse_works_order_output(v_out, 'Taken in against the wrong order');
    return query select 'finished goods taken back out take their undecided pre-release inspection with them',
      (select ins.status = 'cancelled' from erp.inspection ins where ins.batch_id = v_b3),
      (select ins.status::text from erp.inspection ins where ins.batch_id = v_b3);

    -- 9. Taken in before the operation a plan names was booked: the floor's
    -- inspection is opened then, and the batch waits for it.
    v_wo4 := erp.raise_works_order(v_fg, v_site, 4);
    perform erp.release_works_order(v_wo4);
    perform erp.receive_works_order_output(v_wo4, 4, 'FG-C', v_recv);
    select b.id into v_b4 from erp.batch b where b.tenant_id = r.tenant_id and b.batch_number = 'FG-C';
    perform erp.book_operation_time(v_wo4, 10, 4, 4, 0);
    return query select 'finished goods taken in before the operation a plan names was booked are held, and the floor''s inspection is opened once',
      (select sum(sb.quantity) from erp.stock_balance sb where sb.batch_id = v_b4 and sb.stock_status = 'quarantine') = 4
      and (select count(*) from erp.inspection ins
            where ins.works_order_id = v_wo4 and ins.operation_seq = 10 and ins.status <> 'cancelled') = 1,
      (select format('%s floor inspection(s)', count(*)) from erp.inspection ins
        where ins.works_order_id = v_wo4 and ins.batch_id is null);

    -- 10. Rework decided on the floor is not overruled by the batch's own
    -- acceptance afterwards.
    select ins.id into v_ins from erp.inspection ins where ins.works_order_id = v_wo4 and ins.operation_seq = 10;
    select ins.id into v_pre from erp.inspection ins where ins.batch_id = v_b4;
    perform erp.record_inspection_result(v_ins, 'viscosity', 9);
    perform erp.disposition_inspection(v_ins, 'rework', 'Mix again');
    perform erp.record_inspection_result(v_pre, 'label', null, 'correct');
    perform erp.disposition_inspection(v_pre, 'accept', null);
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
      perform public.erp_release_batch(v_b4, v_site, 'Label correct', 'Second Admin');
      v_err := 'released';
    exception when others then v_err := left(sqlerrm, 140); end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    return query select 'rework decided on the floor is not overruled by the batch''s own acceptance afterwards',
      v_err like 'CLOVEERP_ORDER_INSPECTION_NOT_ACCEPTED:%', v_err;

    -- 11. The operation booked again after rework is inspected anew, and
    -- that inspection decides.
    perform erp.book_operation_time(v_wo4, 10, 0, 1, 0);
    perform erp.book_operation_time(v_wo4, 10, 1, 1, 0);
    select ins.id into v_ins from erp.inspection ins
     where ins.works_order_id = v_wo4 and ins.operation_seq = 10 and ins.disposition = 'pending';
    perform erp.record_inspection_result(v_ins, 'viscosity', 3);
    perform erp.disposition_inspection(v_ins, 'accept', null);
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
      perform public.erp_release_batch(v_b4, v_site, 'Reworked and passed', 'Second Admin', v_ins);
      v_err := 'released';
    exception when others then v_err := left(sqlerrm, 140); end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    return query select 'the operation booked again after rework is inspected anew, and its acceptance releases the batch',
      v_err = 'released'
      and (select count(*) from erp.inspection ins
            where ins.works_order_id = v_wo4 and ins.operation_seq = 10 and ins.status <> 'cancelled') = 2,
      v_err;

    -- 12. Once live, nobody releases a batch whose inspection they decided,
    -- on the floor or its own, whichever was decided last.
    v_wo5 := erp.raise_works_order(v_fg, v_site, 2);
    perform erp.release_works_order(v_wo5);
    perform erp.book_operation_time(v_wo5, 10, 2, 2, 0);
    perform erp.receive_works_order_output(v_wo5, 2, 'FG-D', v_recv);
    select b.id into v_b5 from erp.batch b where b.tenant_id = r.tenant_id and b.batch_number = 'FG-D';
    select ins.id into v_pre from erp.inspection ins where ins.batch_id = v_b5;
    select ins.id into v_ins from erp.inspection ins where ins.works_order_id = v_wo5 and ins.operation_seq = 10;
    perform erp.record_inspection_result(v_pre, 'label', null, 'correct');
    perform erp.disposition_inspection(v_pre, 'accept', null);
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.record_inspection_result(v_ins, 'viscosity', 3);
    perform erp.disposition_inspection(v_ins, 'accept', null);
    update erp.environment e set is_live = true where e.tenant_id = r.tenant_id and e.is_self;
    begin
      perform public.erp_release_batch(v_b5, v_site, 'Floor accepted', 'Second Admin');
      v_err := 'released';
    exception when others then v_err := left(sqlerrm, 140); end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    begin
      perform public.erp_release_batch(v_b5, v_site, 'Label correct', 'Suite Admin');
      v_err2 := 'released';
    exception when others then v_err2 := left(sqlerrm, 140); end;
    update erp.environment e set is_live = false where e.tenant_id = r.tenant_id and e.is_self;
    return query select 'once live, nobody releases a batch whose inspection they decided, on the floor or its own',
      v_err like 'CLOVEERP_BATCH_SELF_RELEASE:%' and v_err2 like 'CLOVEERP_BATCH_SELF_RELEASE:%',
      v_err || ' / ' || v_err2;

    -- 13. Accepted on the floor and on its own, the batch is released, signed,
    -- and becomes available.
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
      perform public.erp_release_batch(v_b5, v_site, 'Floor and label accepted', 'Second Admin', v_ins);
      v_err := 'released';
    exception when others then v_err := left(sqlerrm, 140); end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    return query select 'accepted on the floor and on its own, the batch is released on the floor''s inspection, becomes available, and its audit export carries both',
      v_err = 'released'
      and (select sum(sb.quantity) from erp.stock_balance sb where sb.batch_id = v_b5 and sb.stock_status = 'available') = 2
      and (select count(*) from jsonb_array_elements(erp.batch_audit_export(v_b5) -> 'inspections') e
            where (e ->> 'inspection_id')::uuid in (v_ins, v_pre)) = 2,
      v_err;

    -- 14. A batch where it is held is not inspected against the floor's plan.
    return query select 'an inspection asked for where a batch is held never takes the plan for the floor',
      erp.inspection_plan_for(v_fg, v_site) = (select ip.id from erp.inspection_plan ip
                                                 where ip.tenant_id = r.tenant_id and ip.code = 'fg_release'),
      (select ip.code from erp.inspection_plan ip where ip.id = erp.inspection_plan_for(v_fg, v_site));

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
  passed := not exists (select 1 from erp.tenant t where t.code = 'zz-pis-' || v_hex);
  detail := 'the organisation, its orders, batches and inspections rolled back';
  return next;
end;
$function$;

revoke all on function erp_test.production_inspection_suite() from public, anon;

create or replace function erp_test.assert_production_inspection_suite()
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
    from erp_test.production_inspection_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_PRODUCTION_INSPECTION_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'An inspection the floor should have opened and did not, finished goods let out while the floor''s inspection is undecided, or a reject on the floor that did not stop the batch, is the case that failed. Read it.';
  end if;
  if v_total <> 15 then
    raise exception 'CLOVEERP_PRODUCTION_INSPECTION_SUITE_SHRANK: % case(s), expected 15', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
end;
$$;

revoke all on function erp_test.assert_production_inspection_suite() from public, anon;

comment on function erp_test.assert_production_inspection_suite() is
  'The floor opens the inspections its plans name: in process at the operation, pre-release on '
  'the batch taken in; finished goods are held while either is undecided; anything but acceptance '
  'on the floor stops every batch the order made; and nobody releases what they decided (20260925400000).';

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
