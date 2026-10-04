set lock_timeout = '30s';

-- =============================================================================
-- 20261006111000  A cancelled order gives its requisition back
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-08).
-- A tester converted a requisition into a purchase order, cancelled the
-- order, and was left with a requisition reading Ordered and nothing on order
-- for it. Converting it again was refused: Ordered was terminal, and the sums
-- that say how much of a requisition is on order counted every 'converts'
-- relation, the cancelled order's included. Nothing ran when an order was
-- cancelled, as erp.cancelled_receipt_gives_back() runs for a receipt.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.converted_quantity(line): how much of a requisition or quotation
--      line is on a live order, counting no order cancelled by its flag or by
--      its lifecycle and no order line removed. erp.document_is_fully_converted()
--      and erp.convert_document()'s two sums read it, so a cancelled order's
--      quantity is open to convert again. A quotation's lines are read the
--      same way; a cancelled sales order does not move an accepted quotation
--      back, which nobody asked for, but its quantity converts again.
--   B. Procurement lifecycle version 6: a requisition's Ordered is no longer
--      terminal (it stays committed), and it gains two moves:
--        reopen           Ordered -> Approved, the system's, made only while
--                         the requisition is no longer on a live order in full
--        cancel_approved  Approved -> Cancelled, under procurement.approve
--      The second is needed, not only useful: a lifecycle in which Approved
--      and Ordered lead only to each other has a state that cannot finish,
--      which erp.validate_state_machine_version() refuses. It also closes an
--      approved requisition nobody will order. Version 6 restates the
--      purchase order machine unchanged, so the current version still ships
--      both.
--   C. erp.reopen_requisitions(ids, reason) makes the move for each
--      requisition that is Ordered, no longer on a live order in full, and on
--      a version that declares it, naming it in erp.deriving_move as
--      erp.convert_document() names 'order'. erp.derived_move_fact() reads
--      the fact again with the requisition locked, and erp.transition_document()
--      refuses the move pressed by anybody (CLOVEERP_REQUISITION_REOPENED_BY_ITS_ORDER),
--      which erp.transition_refusal() reports to the menu. Two callers:
--        - a purchase order reaching Cancelled (cancel, cancel_approved or
--          cancel_sent), through erp.cancelled_receipt_gives_back(), the
--          trigger function already fired on every state change of a
--          document. Extended rather than adding a trigger, because a new
--          trigger on erp.object_state is DDL on a table every move writes;
--        - erp.remove_document_line(), for the requisition a removed draft
--          line was converted from.
--      Owner's decision: lowering a converted line's quantity on a draft
--      order gives nothing back. Lowering is the buyer's decision about the
--      same need; only removing the line or cancelling the order does.
--   D. erp_test.requisition_given_back_suite.
--
-- Documents already in flight stay on the version they started on
-- (erp.perform_transition reads the version the document is pinned to): a
-- requisition raised before version 6 reaches its organisation stays Ordered
-- when its order is cancelled, although its quantity now converts again only
-- once it is Approved, which it cannot be. The demonstration takes version 6
-- through erp.demonstration_catch_up(); a customer's organisation through
-- Upgrade.
--
-- Production: no row is changed and no demonstration repair is made. The 59
-- demonstration requisitions found Ordered with no live order (J-08's live
-- check) were ordered by the seeder's own Convert to order press, which
-- erp.seed_demo_history() made with no order behind it until 20260922360000;
-- no order was ever raised for them, so none was cancelled, and they are
-- history, not stranded work.
--
-- Proof: erp_test.requisition_given_back_suite; erp_test.procurement_policy_suite
-- re-pinned to version 6.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- A. What is on a live order
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.converted_quantity(p_line_id uuid)
returns numeric
language sql
stable
set search_path = ''
as $$
  -- How much of a requisition or quotation line is on an order raised from it
  -- and still live (20261006111000): an order cancelled by its flag or by its
  -- lifecycle, or a line removed from one, holds nothing of it. The filter
  -- erp.conversion_keeps_approval() already applies to the family it sums.
  select coalesce(sum(r.quantity), 0)
    from erp.document_relation r
    join erp.document o
      on o.tenant_id = r.tenant_id and o.id = r.from_document_id
    left join erp.document_line ol
      on ol.tenant_id = r.tenant_id and ol.id = r.from_line_id
   where r.tenant_id = erp.current_tenant_id()
     and r.relation_kind = 'converts'
     and r.to_line_id = p_line_id
     and not coalesce(o.is_cancelled, false)
     and not coalesce(ol.is_cancelled, false)
     and coalesce(erp.object_current_state('document', o.id), '') <> 'cancelled'
$$;

revoke all on function erp.converted_quantity(uuid) from public, anon;

comment on function erp.converted_quantity(uuid) is
  'How much of a requisition or quotation line is on a live order raised from it: no cancelled order and no removed '
  'order line counted (20261006111000). Read by erp.document_is_fully_converted() and erp.convert_document().';

do $converted$
declare
  v_sig constant text := 'erp.document_is_fully_converted(uuid)';
  v_src text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
begin
  if strpos(v_src, '20261006111000') > 0 then
    raise notice '% already reads erp.converted_quantity; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '1969b7fd288e339b0847341d85669057' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006111000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  execute $f$
create or replace function erp.document_is_fully_converted(p_document_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $body$
  -- Every line that is not cancelled is on a live order raised from it. The
  -- same test erp.convert_document() makes before it moves the source, asked
  -- line by line rather than as one sum, so no over-converted line can hide
  -- one still outstanding. What is on order is erp.converted_quantity()'s
  -- to say (20261006111000): a cancelled order holds none of it.
  select exists (select 1 from erp.document_line dl
                  where dl.tenant_id = erp.current_tenant_id()
                    and dl.document_id = p_document_id
                    and not dl.is_cancelled)
     and not exists (
       select 1 from erp.document_line dl
        where dl.tenant_id = erp.current_tenant_id()
          and dl.document_id = p_document_id
          and not dl.is_cancelled
          and dl.quantity > erp.converted_quantity(dl.id))
$body$
$f$;
end
$converted$;

do $convert$
declare
  v_sig   constant text := 'erp.convert_document(uuid,uuid,uuid,jsonb,text)';
  v_src   text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def   text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_a_old constant text := $a$    select dl.*,
           dl.quantity - coalesce((
             select sum(r.quantity) from erp.document_relation r
              where r.tenant_id = v_tenant
                and r.relation_kind = 'converts'
                and r.to_line_id = dl.id), 0) as outstanding$a$;
  v_a_new constant text := $a$    select dl.*,
           -- What a live order does not hold (20261006111000).
           dl.quantity - erp.converted_quantity(dl.id) as outstanding$a$;
  v_b_old constant text := $b$  select coalesce(sum(dl.quantity - coalesce((
           select sum(r.quantity) from erp.document_relation r
            where r.tenant_id = v_tenant
              and r.relation_kind = 'converts'
              and r.to_line_id = dl.id), 0)), 0)$b$;
  v_b_new constant text := $b$  select coalesce(sum(dl.quantity - erp.converted_quantity(dl.id)), 0)$b$;
begin
  if strpos(v_src, '20261006111000') > 0 then
    raise notice '% already reads erp.converted_quantity; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '21fec5fe5a4210a1f0426ffe46a2d307' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006111000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_a_old, ''))) / length(v_a_old) <> 1
     or (length(v_def) - length(replace(v_def, v_b_old, ''))) / length(v_b_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchors found other than once', v_sig;
  end if;
  execute replace(replace(v_def, v_a_old, v_a_new), v_b_old, v_b_new);
end
$convert$;

-- ═════════════════════════════════════════════════════════════════════════════
-- B. Procurement lifecycle version 6
-- ═════════════════════════════════════════════════════════════════════════════

do $lifecycle$
declare
  v_sig   constant text := 'erp.procurement_lifecycle_items(text,bigint,text)';
  v_src   text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def   text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_a_old constant text := $a$            jsonb_build_object('code','ordered','name','Ordered','is_terminal',true,'is_committed',true,'sort_order',40),$a$;
  v_a_new constant text := $a$            -- Not the end since 20261006111000: a requisition whose order is
            -- cancelled is approved again, to be ordered once more.
            jsonb_build_object('code','ordered','name','Ordered','is_committed',true,'sort_order',40),$a$;
  v_b_old constant text := $b$            jsonb_build_object('code','cancel_submitted','name','Cancel','from','submitted','to','cancelled','required_permission','procurement.approve')))),$b$;
  v_b_new constant text := $b$            jsonb_build_object('code','cancel_submitted','name','Cancel','from','submitted','to','cancelled','required_permission','procurement.approve'),
            -- Approved again when the order raised from it is cancelled, or a
            -- line ordered from it is removed from a draft order: the
            -- system's move, by erp.reopen_requisitions (20261006111000).
            jsonb_build_object('code','reopen','name','Reopened','from','ordered','to','approved','required_permission','procurement.order','is_automatic',true),
            -- And closed when nobody will order it, which also gives Approved
            -- a way to finish now that Ordered is not the end.
            jsonb_build_object('code','cancel_approved','name','Cancel','from','approved','to','cancelled','required_permission','procurement.approve')))),$b$;
begin
  if strpos(v_src, '20261006111000') > 0 then
    raise notice '% already gives a requisition back; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '25b5b5f5f244a403aafb72c0381df069' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006111000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_a_old, ''))) / length(v_a_old) <> 1
     or (length(v_def) - length(replace(v_def, v_b_old, ''))) / length(v_b_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchors found other than once', v_sig;
  end if;
  execute replace(replace(v_def, v_a_old, v_a_new), v_b_old, v_b_new);
end
$lifecycle$;

update erp_ref.module_installer
   set current_version = 6,
       description = description
         || ' Version 6 (20261006111000): a requisition whose order is cancelled is approved again, and an approved one can be cancelled.'
 where install_code = 'procurement-lifecycle' and current_version = 5;

-- The requisition, changed; and the purchase order, restated as version 5
-- left it, so the current version ships both machines.
insert into erp_ref.module_upgrade_item (install_code, to_version, object_kind, object_key, payload, seq)
select 'procurement-lifecycle', 6, x.value ->> 'kind', x.value ->> 'key', (x.value -> 'payload') - 'entity',
       case x.value ->> 'key' when 'requisition' then 100 else 110 end
  from jsonb_array_elements(erp.procurement_lifecycle_items(null, 1000000, 'administrator')) x
 where (x.value ->> 'kind', x.value ->> 'key') in (('state_machine', 'requisition'), ('state_machine', 'purchase_order'))
on conflict (install_code, to_version, object_kind, object_key)
  do update set payload = excluded.payload, seq = excluded.seq;

do $register$
begin
  if (select current_version from erp_ref.module_installer
       where install_code = 'procurement-lifecycle') is distinct from 6 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: the procurement lifecycle installer is not at version 6';
  end if;
  if (select count(*) from erp_ref.module_upgrade_item ui
       where ui.install_code = 'procurement-lifecycle' and ui.to_version = 6
         and ui.object_key = 'requisition'
         and ui.payload -> 'transitions' @> '[{"code": "reopen"}, {"code": "cancel_approved"}]'::jsonb
         and not ui.payload -> 'states' @> '[{"code": "ordered", "is_terminal": true}]'::jsonb) <> 1
     or (select count(*) from erp_ref.module_upgrade_item ui
          where ui.install_code = 'procurement-lifecycle' and ui.to_version = 6
            and ui.object_key = 'purchase_order'
            and ui.payload = (select v5.payload from erp_ref.module_upgrade_item v5
                               where v5.install_code = 'procurement-lifecycle' and v5.to_version = 5
                                 and v5.object_key = 'purchase_order')) <> 1 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: version 6 of procurement lifecycle is not the requisition that reopens with the purchase order of version 5';
  end if;
end
$register$;

do $drivers$
declare
  v_sig  constant text := 'erp.transition_driver_register()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$      ('requisition',        'cancel_submitted',       'screen', ''),$o$;
  v_new  constant text := $n$      ('requisition',        'cancel_submitted',       'screen', ''),
      -- Approved again by the order's cancellation, or a removed line, and
      -- by nothing else; closed by hand once approved (20261006111000).
      ('requisition',        'reopen',                 'routine', 'erp.reopen_requisitions(uuid[],text)'),
      ('requisition',        'cancel_approved',        'screen', ''),$n$;
begin
  if strpos(v_src, 'reopen_requisitions') > 0 then
    raise notice '% already names reopen; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '819ac157fcf114e0e143c4eff3b98b8b' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006111000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$drivers$;

-- ═════════════════════════════════════════════════════════════════════════════
-- C. The move, who makes it, and who may not
-- ═════════════════════════════════════════════════════════════════════════════

select erp.register_refusal('CLOVEERP_REQUISITION_REOPENED_BY_ITS_ORDER',
  'Marking an ordered requisition approved again by hand.',
  'A requisition is approved again because the order raised from it was cancelled or lost a line, so what it asked for is no longer on order. Pressed by hand, it would say a supplier had stopped being asked when one had not.',
  'Cancel the order raised from it, or remove the line from that order while it is a draft. The requisition is approved again by itself.');

create or replace function erp.reopen_requisitions(p_requisition_ids uuid[], p_reason text)
returns text[]
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_prev   text := coalesce(current_setting('erp.deriving_move', true), '');
  v_done   text[] := '{}';
  r        record;
begin
  -- Each requisition named that reads Ordered, is no longer on a live order
  -- in full, and stands on a version that declares the move
  -- (20261006111000). A requisition raised under an earlier version stays
  -- where it is: its lifecycle has no way back.
  for r in
    select d.id, d.document_number
      from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
     where d.tenant_id = v_tenant
       and d.id = any(coalesce(p_requisition_ids, '{}'))
       and dt.base_type_code = 'requisition'
       and not d.is_cancelled
       and erp.object_current_state('document', d.id) = 'ordered'
       and erp.document_declares_move(d.id, 'reopen')
       and not erp.document_is_fully_converted(d.id)
     order by d.document_number, d.id
  loop
    -- Named immediately before the move and put back immediately after, as
    -- erp.convert_document() names 'order': erp.derived_move_fact() reads
    -- the fact again inside the door. Put back, not cleared, because the
    -- cancellation that brought us here may be a routine's own move.
    begin
      perform set_config('erp.deriving_move', r.id::text || ':reopen', true);
      perform erp.transition_document(r.id, 'reopen', p_reason);
      perform set_config('erp.deriving_move', v_prev, true);
    exception when others then
      perform set_config('erp.deriving_move', v_prev, true);
      raise;
    end;
    v_done := v_done || r.document_number;
  end loop;
  return v_done;
end;
$$;

create or replace function erp.reopen_requisitions_of(p_order_id uuid)
returns text[]
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_number text;
begin
  select d.document_number into v_number
    from erp.document d where d.tenant_id = v_tenant and d.id = p_order_id;
  -- Every requisition the order was converted from (20261006111000).
  return erp.reopen_requisitions(
    array(select distinct rel.to_document_id
            from erp.document_relation rel
           where rel.tenant_id = v_tenant
             and rel.from_document_id = p_order_id
             and rel.relation_kind = 'converts'),
    format('%s, raised from it, was cancelled', coalesce(v_number, 'The order')));
end;
$$;

revoke all on function erp.reopen_requisitions(uuid[], text) from public, anon;
revoke all on function erp.reopen_requisitions_of(uuid) from public, anon;

comment on function erp.reopen_requisitions(uuid[], text) is
  'Approves again each requisition named that reads Ordered and is no longer on a live order in full, on a version that '
  'declares the move; the system''s move, named in erp.deriving_move (20261006111000).';
comment on function erp.reopen_requisitions_of(uuid) is
  'Approves again the requisitions a purchase order was converted from, once the order is cancelled (20261006111000).';

do $fact$
declare
  v_sig  constant text := 'erp.derived_move_fact(text,uuid,text)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$           when dt.base_type_code = 'requisition' and p_transition_code = 'order'
            and erp.document_is_fully_converted(p_object_id)
             then 'erp.document_is_fully_converted'$o$;
  v_new  constant text := $n$           when dt.base_type_code = 'requisition' and p_transition_code = 'order'
            and erp.document_is_fully_converted(p_object_id)
             then 'erp.document_is_fully_converted'
           -- And approved again once it is not (20261006111000), asked for
           -- by erp.reopen_requisitions() as its order is cancelled or a line
           -- ordered from it is removed.
           when dt.base_type_code = 'requisition' and p_transition_code = 'reopen'
            and erp.object_current_state('document', p_object_id) = 'ordered'
            and not erp.document_is_fully_converted(p_object_id)
             then 'erp.document_is_fully_converted'$n$;
begin
  if strpos(v_src, '20261006111000') > 0 then
    raise notice '% already derives reopen; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '68dffef58e3a70faa3ae4f49087acddc' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006111000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$fact$;

do $transition$
declare
  v_sig  constant text := 'erp.transition_document(uuid,text,text)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$            hint = 'Convert it into a purchase order. It reads Ordered once every line ' ||
                   'is on an order raised from it.';
  end if;$o$;
  v_new  constant text := $n$            hint = 'Convert it into a purchase order. It reads Ordered once every line ' ||
                   'is on an order raised from it.';
  end if;

  -- And approved again only because its order was cancelled or lost a line
  -- (20261006111000): erp.reopen_requisitions() names the move, and the fact
  -- is read again here. Pressed by anybody, an administrator included, it
  -- would say a supplier had stopped being asked when one had not.
  if dt.base_type_code = 'requisition' and p_transition_code = 'reopen'
     and erp.derived_move_fact('document', p_document_id, 'reopen') is null
  then
    raise exception
      'CLOVEERP_REQUISITION_REOPENED_BY_ITS_ORDER: % is approved again only when an order raised from it is cancelled or loses a line',
      coalesce(d.document_number, p_document_id::text)
      using errcode = '23514',
            hint = 'Cancel the order raised from it, or remove the line from that order while it is a draft. The requisition is approved again by itself.';
  end if;$n$;
begin
  if strpos(v_src, '20261006111000') > 0 then
    raise notice '% already refuses reopen by hand; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '6b456043923633fd3e8f1889213b4fd6' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006111000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$transition$;

do $refusal$
declare
  v_sig  constant text := 'erp.transition_refusal(uuid,text)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  -- Reject, of a transfer order or stock adjustment waiting for approval,
  -- is the approvers' and the asker's (20260928500000).$o$;
  v_new  constant text := $n$  -- Reopen, of a requisition, is its order's (20261006111000): the same
  -- read erp.transition_document() makes.
  if p_transition_code = 'reopen' and v_tenant is not null
     and exists (select 1 from erp.document d
                   join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
                  where d.tenant_id = v_tenant and d.id = p_document_id
                    and dt.base_type_code = 'requisition')
     and erp.derived_move_fact('document', p_document_id, 'reopen') is null then
    return 'CLOVEERP_REQUISITION_REOPENED_BY_ITS_ORDER';
  end if;

  -- Reject, of a transfer order or stock adjustment waiting for approval,
  -- is the approvers' and the asker's (20260928500000).$n$;
begin
  if strpos(v_src, '20261006111000') > 0 then
    raise notice '% already reports reopen; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '7c98ee2b9a7eaea39df28c7a18f75e37' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006111000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$refusal$;

-- A purchase order reaching Cancelled, by whichever move, gives its
-- requisitions back. The trigger function every document state change already
-- fires, extended; a new trigger on erp.object_state would be DDL on a table
-- every move writes.

do $cancelled$
declare
  v_sig  constant text := 'erp.cancelled_receipt_gives_back()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$      perform erp.refresh_order_line_progress(r.to_line_id);
    end loop;
  end if;
  return new;$o$;
  v_new  constant text := $n$      perform erp.refresh_order_line_progress(r.to_line_id);
    end loop;
  end if;

  -- And a purchase order that moves to cancelled gives back the requisitions
  -- it was converted from (20261006111000): each that reads Ordered and is no
  -- longer on a live order in full is approved again, to be ordered once more.
  if new.object_type = 'document'
     and new.current_state_id is distinct from old.current_state_id
     and exists (select 1 from erp.state s where s.id = new.current_state_id and s.code = 'cancelled')
     and exists (select 1
                   from erp.document d
                   join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
                  where d.tenant_id = new.tenant_id and d.id = new.object_id
                    and dt.base_type_code = 'purchase_order')
     and exists (select 1 from erp.document_relation rel
                  where rel.tenant_id = new.tenant_id and rel.from_document_id = new.object_id
                    and rel.relation_kind = 'converts') then
    perform erp.reopen_requisitions_of(new.object_id);
  end if;
  return new;$n$;
begin
  if strpos(v_src, '20261006111000') > 0 then
    raise notice '% already gives a requisition back; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '7b6a1cc7f291124743a6ffa724025e1c' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006111000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$cancelled$;

comment on function erp.cancelled_receipt_gives_back() is
  'A cancelled receipt gives its order lines back to receive (20261005800000); a cancelled purchase order gives the '
  'requisitions it was converted from back to order (20261006111000).';

-- A converted line removed from a draft order gives its requisition back.

do $remove$
declare
  v_sig   constant text := 'erp.remove_document_line(uuid)';
  v_src   text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def   text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_a_old constant text := $a$  v_perm   text;
  r        record;
begin$a$;
  v_a_new constant text := $a$  v_perm   text;
  r        record;
  v_from   uuid[];
  v_back   text[];
begin$a$;
  v_b_old constant text := $b$  -- The relations the line itself raised. A draft line nobody committed$b$;
  v_b_new constant text := $b$  -- What the line was converted from, read before its relations go
  -- (20261006111000), to be given back below.
  v_from := array(select distinct rel.to_document_id
                    from erp.document_relation rel
                   where rel.tenant_id = v_tenant and rel.from_line_id = p_line_id
                     and rel.relation_kind = 'converts');

  -- The relations the line itself raised. A draft line nobody committed$b$;
  v_c_old constant text := $c$  perform erp.release_what_hangs_off_a_line(p_line_id);

  return jsonb_build_object(
    'line_id', p_line_id,
    'document_id', l.document_id,
    'document_total_minor', erp.document_value_minor(l.document_id));$c$;
  v_c_new constant text := $c$  perform erp.release_what_hangs_off_a_line(p_line_id);

  -- A requisition the line was ordered from, no longer on order in full, is
  -- approved again to be ordered (20261006111000). Lowering a line gives
  -- nothing back (owner, 4 October); removing it does.
  v_back := erp.reopen_requisitions(v_from,
              format('A line ordered from it was removed from %s', d.document_number));

  return jsonb_build_object(
    'line_id', p_line_id,
    'document_id', l.document_id,
    'document_total_minor', erp.document_value_minor(l.document_id),
    'reopened', to_jsonb(v_back));$c$;
begin
  if strpos(v_src, '20261006111000') > 0 then
    raise notice '% already gives a requisition back; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'fd64dbebab4aca6a8c44ac8c8b9ef487' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006111000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_a_old, ''))) / length(v_a_old) <> 1
     or (length(v_def) - length(replace(v_def, v_b_old, ''))) / length(v_b_old) <> 1
     or (length(v_def) - length(replace(v_def, v_c_old, ''))) / length(v_c_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchors found other than once', v_sig;
  end if;
  execute replace(replace(replace(v_def, v_a_old, v_a_new), v_b_old, v_b_new), v_c_old, v_c_new);
end
$remove$;

-- ═════════════════════════════════════════════════════════════════════════════
-- D. The proof
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.requisition_given_back_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 8;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  res      jsonb;
  v_step   text := 'provisioning';
  v_state  text;
  v_entity uuid; v_site uuid; v_uom uuid; v_item uuid; v_item2 uuid; v_sup uuid;
  v_r      uuid; v_rl uuid; v_rl2 uuid;
  v_po     uuid; v_po2 uuid; v_pl uuid; v_pl2 uuid;
  v_cancel text;
  v_x      text; v_x2 text; v_x3 text;
  v_q      numeric; v_q2 numeric;
  v_ok     boolean;
begin
  begin
    -- ── The fixture ───────────────────────────────────────────────────────────
    v_step := 'an organisation that buys, not yet live';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzrgb-' || v_tag, 'Requisition Given Back Suite',
      'admin@zzrgb-' || v_tag || '.test', 'Given Back Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzrgb-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    res := erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    v_entity := (res ->> 'entity_id')::uuid;
    v_site := (res ->> 'site_id')::uuid;
    select u.id into v_uom from erp.uom u
     where u.tenant_id = rb.tenant_id and u.is_base and u.uom_class = 'quantity' and u.status = 'active'
     order by u.code limit 1;
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZRGBSUP', 'Given Back Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZRGBWID', 'Given Back Widget', v_uom, 'active') returning id into v_item;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZRGBBOLT', 'Given Back Bolt', v_uom, 'active') returning id into v_item2;

    -- ── 1. Its only order cancelled as a draft ────────────────────────────────
    -- A requisition naming no supplier: its order is raised as a draft.
    v_step := 'a requisition whose order is cancelled as a draft';
    v_r := erp.open_document('requisition', null, v_entity, v_site);
    v_rl := erp.add_document_line(v_r, v_item, 10, 1000, 'ten widgets');
    v_rl2 := erp.add_document_line(v_r, v_item2, 4, 500, 'four bolts');
    perform erp.transition_document(v_r, 'submit', null);
    perform erp.approve_my_document_tasks(v_r, 'the given back suite');
    if erp.object_current_state('document', v_r) = 'submitted' then
      perform erp.transition_document(v_r, 'approve', null);
    end if;
    res := erp.convert_document(v_r, v_sup, null, null);
    v_po := (res ->> 'document_id')::uuid;
    v_x := erp.object_current_state('document', v_r);
    v_x2 := erp.transition_document(v_po, 'cancel', 'Raised against the wrong supplier');
    v_cases := v_cases + 1;
    case_name := 'a requisition whose only order is cancelled as a draft is approved again, by the system and with the reason';
    passed := v_state is null and v_x = 'ordered' and v_x2 = 'cancelled'
          and erp.object_current_state('document', v_r) = 'approved'
          and erp.converted_quantity(v_rl) = 0
          and exists (select 1 from erp.state_transition_log l
                       where l.tenant_id = rb.tenant_id and l.object_id = v_r and l.transition_code = 'reopen'
                         and l.guard_data -> 'derived' ->> 'fact' = 'erp.document_is_fully_converted'
                         and l.reason like '%, raised from it, was cancelled');
    detail := coalesce(v_state, format('before %s; order %s; requisition %s; on order %s', v_x, v_x2,
                erp.object_current_state('document', v_r), erp.converted_quantity(v_rl)));
    return next;

    -- ── 2. And it converts in full again ──────────────────────────────────────
    v_step := 'converting it again';
    res := erp.convert_document(v_r, v_sup, null, null);
    v_po2 := (res ->> 'document_id')::uuid;
    select coalesce(sum(l.quantity), 0) into v_q
      from erp.document_line l where l.tenant_id = rb.tenant_id and l.document_id = v_po2 and not l.is_cancelled;
    v_cases := v_cases + 1;
    case_name := 'given back, it converts again in full, and reads Ordered once more';
    passed := v_state is null and v_q = 14 and (res ->> 'lines')::integer = 2
          and erp.object_current_state('document', v_r) = 'ordered';
    detail := coalesce(v_state, format('%s line(s) holding %s; requisition %s', res ->> 'lines', v_q,
                erp.object_current_state('document', v_r)));
    return next;

    -- ── 3. A converted line removed from a draft order; another lowered ───────
    v_step := 'lowering one draft line and removing the other';
    select l.id into v_pl from erp.document_line l
     where l.tenant_id = rb.tenant_id and l.document_id = v_po2 and l.item_id = v_item;
    select l.id into v_pl2 from erp.document_line l
     where l.tenant_id = rb.tenant_id and l.document_id = v_po2 and l.item_id = v_item2;
    perform public.erp_change_document_line(v_pl, 6, null, null);
    v_x := erp.object_current_state('document', v_r);
    res := public.erp_remove_document_line(v_pl2);
    v_q := erp.converted_quantity(v_rl);
    v_q2 := erp.converted_quantity(v_rl2);
    v_cases := v_cases + 1;
    case_name := 'a converted line lowered on a draft order gives nothing back; removed, it gives its requisition back';
    passed := v_state is null and v_x = 'ordered'
          and erp.object_current_state('document', v_r) = 'approved'
          and res -> 'reopened' = to_jsonb(array[(select d.document_number from erp.document d where d.id = v_r)])
          and v_q = 10 and v_q2 = 0;
    detail := coalesce(v_state, format('after lowering %s; after removing %s (%s); on order %s and %s', v_x,
                erp.object_current_state('document', v_r), res -> 'reopened', v_q, v_q2));
    return next;

    -- ── 4. Only what was given back converts ──────────────────────────────────
    v_step := 'converting what was given back';
    res := erp.convert_document(v_r, v_sup, null, null);
    v_x := erp.object_current_state('document', v_r);
    v_cases := v_cases + 1;
    case_name := 'converted again, only the removed line is ordered, and the requisition reads Ordered';
    passed := v_state is null and (res ->> 'lines')::integer = 1 and v_x = 'ordered'
          and (select l.item_id from erp.document_line l
                where l.document_id = (res ->> 'document_id')::uuid) = v_item2;
    detail := coalesce(v_state, format('%s line(s); requisition %s', res ->> 'lines', v_x));
    return next;

    -- ── 5. Approved with it, then cancelled ───────────────────────────────────
    v_step := 'an order approved with its requisition, cancelled';
    v_r := erp.open_document('requisition', v_sup, v_entity, v_site);
    v_rl := erp.add_document_line(v_r, v_item, 5, 1000, 'five widgets');
    perform erp.transition_document(v_r, 'submit', null);
    perform erp.approve_my_document_tasks(v_r, 'the given back suite');
    if erp.object_current_state('document', v_r) = 'submitted' then
      perform erp.transition_document(v_r, 'approve', null);
    end if;
    res := erp.convert_document(v_r, null, null, null);
    v_po := (res ->> 'document_id')::uuid;
    v_x := erp.object_current_state('document', v_po);
    v_x2 := erp.transition_document(v_po, 'cancel_approved', 'Not needed after all');
    v_cases := v_cases + 1;
    case_name := 'an order approved with its requisition and then cancelled gives the requisition back';
    passed := v_state is null and v_x = 'approved' and v_x2 = 'cancelled'
          and erp.object_current_state('document', v_r) = 'approved';
    detail := coalesce(v_state, format('order %s then %s; requisition %s', v_x, v_x2,
                erp.object_current_state('document', v_r)));
    return next;

    -- ── 6. Sent, nothing received, then cancelled ─────────────────────────────
    v_step := 'an order sent and then cancelled';
    res := erp.convert_document(v_r, null, null, null);
    v_po := (res ->> 'document_id')::uuid;
    if erp.object_current_state('document', v_po) = 'draft' then
      perform erp.transition_document(v_po, 'submit', null);
      perform erp_test.approve_document(v_po, null);
    end if;
    perform erp.transition_document(v_po, 'send', null);
    v_x := erp.object_current_state('document', v_r);
    res := erp.cancel_sent_order(v_po, 'The supplier cannot make them');
    v_cases := v_cases + 1;
    case_name := 'an order cancelled once sent, nothing received, gives its requisition back';
    passed := v_state is null and v_x = 'ordered' and res ->> 'state' = 'cancelled'
          and erp.object_current_state('document', v_r) = 'approved';
    detail := coalesce(v_state, format('requisition %s; order %s; requisition %s', v_x, res ->> 'state',
                erp.object_current_state('document', v_r)));
    return next;

    -- ── 7. Of two orders, one cancelled ───────────────────────────────────────
    v_step := 'two orders from one requisition, one cancelled';
    v_r := erp.open_document('requisition', null, v_entity, v_site);
    v_rl := erp.add_document_line(v_r, v_item, 10, 1000, 'ten widgets');
    perform erp.transition_document(v_r, 'submit', null);
    perform erp.approve_my_document_tasks(v_r, 'the given back suite');
    if erp.object_current_state('document', v_r) = 'submitted' then
      perform erp.transition_document(v_r, 'approve', null);
    end if;
    res := erp.convert_document(v_r, v_sup, null,
             jsonb_build_array(jsonb_build_object('line_id', v_rl, 'quantity', 4)));
    v_po := (res ->> 'document_id')::uuid;
    v_x := erp.object_current_state('document', v_r);
    res := erp.convert_document(v_r, v_sup, null, null);
    v_po2 := (res ->> 'document_id')::uuid;
    v_x2 := erp.object_current_state('document', v_r);
    select x ->> 'code' into v_cancel
      from jsonb_array_elements(public.erp_available_transitions(v_po)) x
     where x ->> 'to_state' = 'cancelled' limit 1;
    perform erp.transition_document(v_po, v_cancel, 'Four were found in the stores');
    v_q := erp.converted_quantity(v_rl);
    v_x3 := erp.object_current_state('document', v_r);
    res := erp.convert_document(v_r, v_sup, null, null);
    v_cases := v_cases + 1;
    case_name := 'of two orders raised from one requisition, cancelling one opens only its quantity to order again';
    passed := v_state is null and v_x = 'approved' and v_x2 = 'ordered' and v_cancel is not null
          and v_q = 6 and v_x3 = 'approved'
          and (select l.quantity from erp.document_line l
                where l.document_id = (res ->> 'document_id')::uuid) = 4
          and erp.object_current_state('document', v_r) = 'ordered';
    detail := coalesce(v_state, format('after 4: %s; after the rest: %s; cancelled by %s: on order %s, %s; converted %s',
                v_x, v_x2, coalesce(v_cancel, 'no move'), v_q, v_x3, res ->> 'lines'));
    return next;

    -- ── 8. Nobody reopens one by hand; an approved one is cancelled ───────────
    v_step := 'reopen pressed by hand';
    v_x := null;
    begin
      perform erp.transition_document(v_r, 'reopen', 'by hand');
      v_x := 'reopened';
    exception when others then v_x := left(sqlerrm, 200);
    end;
    v_x2 := erp.transition_refusal(v_r, 'reopen');
    v_r := erp.open_document('requisition', v_sup, v_entity, v_site);
    perform erp.add_document_line(v_r, v_item, 1, 1000, 'one widget');
    perform erp.transition_document(v_r, 'submit', null);
    perform erp.approve_my_document_tasks(v_r, 'the given back suite');
    if erp.object_current_state('document', v_r) = 'submitted' then
      perform erp.transition_document(v_r, 'approve', null);
    end if;
    v_x3 := erp.transition_document(v_r, 'cancel_approved', 'Nobody will order it');
    v_cases := v_cases + 1;
    case_name := 'nobody approves an ordered requisition again by hand, and the menu says so; an approved one nobody will order is cancelled';
    passed := v_state is null
          and v_x like 'CLOVEERP_REQUISITION_REOPENED_BY_ITS_ORDER%'
          and v_x2 = 'CLOVEERP_REQUISITION_REOPENED_BY_ITS_ORDER'
          and v_x3 = 'cancelled'
          and coalesce(current_setting('erp.deriving_move', true), '') = '';
    detail := coalesce(v_state, format('by hand: %s; menu: %s; approved cancelled: %s', v_x, v_x2, v_x3));
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
    raise exception 'CLOVEERP_REQUISITION_GIVEN_BACK_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.requisition_given_back_suite() from public, anon;

comment on function erp_test.requisition_given_back_suite() is
  'A cancelled order gives its requisition back (20261006111000): cancelled from draft, approved and sent, one of '
  'two orders cancelled, a converted line removed and another lowered, and the move refused by hand.';

create or replace function erp_test.assert_requisition_given_back_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)), count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.requisition_given_back_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_REQUISITION_GIVEN_BACK_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A requisition would read Ordered with nothing on order for it, or be approved again with its order still live. Read the case that failed.';
  end if;
  if v_total <> 8 then
    raise exception 'CLOVEERP_REQUISITION_GIVEN_BACK_SUITE_SHRANK: % case(s), expected 8', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('requisition given back: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_requisition_given_back_suite() from public, anon;

comment on function erp_test.assert_requisition_given_back_suite() is
  'A cancelled order, or a converted line removed from a draft, gives its requisition back to order again (20261006111000).';

-- The procurement policy suite pinned a new install at version 5.

do $repin$
declare
  v_sig  constant text := 'erp_test.procurement_policy_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$      -- Version 5 since 20261006110000: an approved order goes back to draft.
      v_ver = 5
$o$;
  v_new  constant text := $n$      -- Version 6 since 20261006111000: a cancelled order gives its requisition back.
      v_ver = 6
$n$;
begin
  if strpos(v_src, '20261006111000') > 0 then
    raise notice '% already re-pinned; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'da8173b8bd86ace1d8f6f8267333515d' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006111000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$repin$;

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
select erp.assert_every_transition_is_driven();
select erp.assert_parameter_budget();
