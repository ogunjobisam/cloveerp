-- Controls that finish the job.
--
-- The persona walk of 14 September named three controls that stopped half
-- way (its items 12, 13 and 15), and writing the delivery chapter of the user
-- guide found three loose ends behind a delivery (PR 107). Each was checked
-- against the definitions as they stand after every patch before this file
-- was written, reading every later execute replace(pg_get_functiondef(...))
-- as well as every CREATE:
--
--   1. A count variance could not be approved. erp.record_count
--      (20260829240000, patched by 20260906070000) opens an approval request
--      for a count outside its programme's tolerance and sets the task
--      pending_approval. erp.decide_approval_task (20260831202427, patched by
--      20260914062000) decides the request and nothing else, so the task never
--      read approved and erp.post_count (20260906070000) refused it for ever.
--      A chain none of whose steps applied approved the request as it was
--      raised and still left the count waiting. The base pack's three count
--      programmes named no chain at all, so a variance on them sat at counted,
--      where posting refuses it too. And whoever counted could post their own
--      variance, holding the adjust permission.
--
--   2. A three-way match exception could not be accepted. erp.match_three_way
--      (20260829250000, never patched) raises the exception and its approval
--      request; resolved_at was written only by a later clean match, and
--      erp.propose_payment_run (20260909212619) holds the invoice while it is
--      unresolved. No door read the approval, so an approved variance held the
--      invoice exactly as a refused one did.
--
--   3. A rejected batch could be released. erp.release_batch (20260829290000,
--      patched by 20260906142000) refused a named inspection that was rejected,
--      and a batch with an inspection nobody had dispositioned; released
--      without naming one, a batch last dispositioned reject went to available
--      stock. Nothing compared the releaser with whoever dispositioned, a named
--      inspection could belong to another batch, and the desk's release form
--      never sent the inspection at all.
--
--   4. After a delivery. (a) Committed allocations stayed held: nothing ever
--      set an allocation consumed, so erp.available_to_promise and
--      erp.stock_availability subtracted a commitment for goods that had
--      already left, counting them twice. (b) erp.invoice_from_delivery
--      (20260829280000, never patched) billed max(unit price) times quantity:
--      a line's discount was dropped, and two lines of one product at
--      different terms became one line at the higher price. (c)
--      erp.advance_orders_for_receipt (20260910165931) records
--      document.progress_not_advanced when an order cannot move, and that
--      event type was never registered: erp.append_event refused it inside the
--      handler, so the receipt that should have posted failed instead.
--
-- What this file does, in order:
--
--   1. Counting. erp.settle_approval_outcome(request) moves what an approval
--      was about when the request is decided: a count waiting on its variance
--      approval is approved or refused with it, and a refused count releases
--      its soft lock. erp.decide_approval_task asks it on both decisions, and
--      erp.record_count approves a count whose request approved itself. Once
--      the organisation is live, erp.post_count refuses the person who counted
--      (CLOVEERP_COUNT_SELF_POSTING); a count with no variance moves nothing and
--      still posts, and before go-live one person may do both, as the approval
--      rules of 20260914062000 allow. The base pack's CYCLE_A, CYCLE_C and
--      STOCKTAKE name the count_variance chain, and the pack carries that chain:
--      one step, asked of warehouse_manager. Pack items are edited in place, as
--      20260914061500 did; an organisation that applied the pack before sees
--      both planned when it applies it again. The approval tasks still go to
--      every holder of the role, the counter included: a count is not refused
--      for lack of a second approver, and the posting is where the second
--      person stands.
--
--   2. Matching. public.erp_accept_match_exception(p_exception_id, p_note), under
--      procurement.match, the permission matching, billing and the workbench
--      already run under (a payment run reads the exception; it does not
--      raise it). It resolves an exception whose approval request is approved,
--      and refuses an unknown exception (CLOVEERP_UNKNOWN_MATCH_EXCEPTION), one
--      already resolved (CLOVEERP_MATCH_EXCEPTION_RESOLVED), one whose request
--      is pending, was asked again by a later match on the line, or was never
--      raised (CLOVEERP_MATCH_EXCEPTION_NOT_APPROVED), one whose request was
--      refused (CLOVEERP_MATCH_EXCEPTION_REFUSED), and, once live, the person
--      who raised the request when somebody was asked to decide it
--      (CLOVEERP_MATCH_EXCEPTION_SELF_ACCEPTANCE). Accepting the newest exception
--      on a line also resolves the older ones on that line whose requests it
--      superseded, so none is left holding an invoice with nothing that could
--      ever release it.
--
--   3. Batch release. erp.release_batch refuses a named inspection of another
--      batch (CLOVEERP_INSPECTION_NOT_OF_THIS_BATCH), a batch whose latest
--      disposition is reject or destroy (CLOVEERP_BATCH_REJECTED), a batch whose
--      latest or named inspection has a result out of specification and was
--      not accepted (CLOVEERP_BATCH_INSPECTION_FAILED), and, once live, a
--      releaser who dispositioned that inspection (CLOVEERP_BATCH_SELF_RELEASE).
--      public.erp_inspections gains p_batch_id, so the desk's release form
--      offers the chosen batch's own inspections and sends the one chosen.
--
--   4. Deliveries. erp.consume_allocations_for_delivery(delivery), asked by
--      erp.advance_orders_for_delivery when a delivery raised from an order
--      posts: each order line's allocations give up what the delivery took,
--      picked before committed before reserved, and committed lines at the
--      location and batch the goods left from first; an order line delivered
--      in full releases whatever is still held for it. A delivery not raised
--      from an order carries no line links and consumes nothing.
--      erp.invoice_from_delivery bills each price and discount as its own line,
--      net of the discount as sales lines are everywhere else. The event type
--      document.progress_not_advanced is registered, with its words.
--
--   5. The suites these rules touch: the inventory suite's second
--      administrator posts the count the first counted, the quality suite's
--      second administrator releases the batch the first dispositioned, and
--      the starter pack acceptance suite counts one more planned item (the
--      chain, where the inventory installer had asked administrator).
--
-- The desk: Release a batch asks for the inspection, Purchasing offers Accept a
-- match exception, and Stock audit offers Decide a count variance and says who
-- posts.
--
-- Proof: erp_test.controls_finish_suite(), twenty-nine cases, pinned by its
-- wrapper; and the suites it touches, run again at the end.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. A count follows its approval
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.settle_approval_outcome(p_request_id uuid)
returns text
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  q        erp.approval_request%rowtype;
  v_moved  integer := 0;
begin
  select * into q
    from erp.approval_request ar
   where ar.tenant_id = v_tenant and ar.id = p_request_id;

  if not found or q.status::text not in ('approved', 'rejected') then
    return null;
  end if;

  -- A count waiting on its variance approval is approved or refused with it.
  -- Only the task this request was raised for, and only while it waits: a
  -- request superseded by a recount does not move the recount.
  if q.object_type = 'count_task' then
    update erp.count_task t
       set status = q.status::text::erp.count_task_status,
           updated_at = now()
     where t.tenant_id = v_tenant
       and t.id = q.object_id
       and t.approval_request_id = q.id
       and t.status = 'pending_approval';
    get diagnostics v_moved = row_count;

    -- A refused count is not posted, so nothing else releases its soft lock,
    -- and the next count of the place would inherit what moved through it.
    if v_moved > 0 and q.status::text = 'rejected' then
      update erp.count_lock l
         set released_at = now(), updated_at = now()
       where l.tenant_id = v_tenant
         and l.count_task_id = q.object_id
         and l.released_at is null;
    end if;

    return case when v_moved > 0 then q.status::text end;
  end if;

  return null;
end;
$$;

comment on function erp.settle_approval_outcome(uuid) is
  'Called when an approval request is decided. Moves what the request was about: '
  'a count task waiting on its variance approval becomes approved or rejected with '
  'it, and a rejected count releases its soft lock. Returns the state it moved '
  'the object to, or null when it moved nothing. Authorises nothing: the decision '
  'was authorised by erp.decide_approval_task (20260914070000).';

revoke all on function erp.settle_approval_outcome(uuid) from public, anon, authenticated;

do $patch$
declare
  v_sig text := 'erp.decide_approval_task(uuid,boolean,text)';
  v_def text := pg_get_functiondef('erp.decide_approval_task(uuid,boolean,text)'::regprocedure);
  v_n1  text := $n$    update erp.approval_request
       set status = 'rejected', decided_at = now(), decision_note = p_comment, updated_at = now()
     where id = v_req.id;
$n$;
  v_r1  text := $r$    update erp.approval_request
       set status = 'rejected', decided_at = now(), decision_note = p_comment, updated_at = now()
     where id = v_req.id;

    -- What the approval was about is refused with it (20260914070000): a count
    -- waiting on its variance approval is refused and is not posted.
    perform erp.settle_approval_outcome(v_req.id);
$r$;
  v_n2  text := $n$    update erp.approval_request
       set status = 'approved', decided_at = now(), updated_at = now()
     where id = v_req.id;
    return 'approved';
$n$;
  v_r2  text := $r$    update erp.approval_request
       set status = 'approved', decided_at = now(), updated_at = now()
     where id = v_req.id;
    -- And approved with it (20260914070000): a count waiting on its variance
    -- approval can now be posted.
    perform erp.settle_approval_outcome(v_req.id);
    return 'approved';
$r$;
begin
  if position('erp.settle_approval_outcome(' in v_def) > 0 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % already settles what an approval was about', v_sig;
  end if;
  if (length(v_def) - length(replace(v_def, v_n1, ''))) / length(v_n1) <> 1
     or (length(v_def) - length(replace(v_def, v_n2, ''))) / length(v_n2) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % does not decide a request the way the 20260831202427 body does', v_sig
      using hint = 'A later migration changed how a request is decided. Read pg_get_functiondef() of it and patch that body.';
  end if;

  execute replace(replace(v_def, v_n1, v_r1), v_n2, v_r2);

  if (length(pg_get_functiondef(v_sig::regprocedure))
      - length(replace(pg_get_functiondef(v_sig::regprocedure), 'perform erp.settle_approval_outcome(v_req.id);', '')))
     / length('perform erp.settle_approval_outcome(v_req.id);') <> 2 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % was re-emitted without settling both decisions', v_sig;
  end if;
end
$patch$;

do $patch$
declare
  v_sig text := 'erp.record_count(uuid,numeric)';
  v_def text := pg_get_functiondef('erp.record_count(uuid,numeric)'::regprocedure);
  v_n   text := $n$      1, null, t.site_id);
    v_status := 'pending_approval';
$n$;
  v_r   text := $r$      1, null, t.site_id);
    v_status := 'pending_approval';
    -- A chain none of whose steps applies approves the request as it is
    -- raised, and nobody is asked: the count is approved with it
    -- (20260914070000). Otherwise it waits, and erp.settle_approval_outcome()
    -- moves it when the request is decided.
    if exists (select 1 from erp.approval_request ar
                where ar.tenant_id = v_tenant and ar.id = v_req
                  and ar.status = 'approved') then
      v_status := 'approved';
    end if;
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % does not ask for a variance approval the way the 20260829240000 body does', v_sig
      using hint = 'A later migration changed how a count asks for approval. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_n, v_r);
end
$patch$;

do $patch$
declare
  v_sig text := 'erp.post_count(uuid)';
  v_def text := pg_get_functiondef('erp.post_count(uuid)'::regprocedure);
  v_n   text := $n$  select i.stock_uom_id into v_uom from erp.item i where i.id = t.item_id;
$n$;
  v_r   text := $r$  -- A variance is not written into the ledger by the person who counted it,
  -- once the organisation is live (20260914070000): the count is one person's
  -- word, and correcting the stock by it is somebody else's. Before go-live one
  -- person often counts and posts, as the approval rules of 20260914062000
  -- allow. A count with no variance moved nothing and has posted above.
  if t.counted_by is not null
     and t.counted_by = erp.current_principal_id()
     and erp.tenant_is_live(v_tenant) then
    raise exception 'CLOVEERP_COUNT_SELF_POSTING: you counted %, so somebody else posts its variance of %',
      coalesce((select i.code from erp.item i where i.id = t.item_id), p_task_id::text),
      trim_scale(t.variance)
      using errcode = '42501',
            hint = 'Ask somebody else who may adjust stock to post the count. Nobody writes their own count into the stock once the organisation is live.';
  end if;

  select i.stock_uom_id into v_uom from erp.item i where i.id = t.item_id;
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % is not the body 20260906070000 restated', v_sig
      using hint = 'A later migration changed how a count posts. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_n, v_r);
end
$patch$;

-- The base pack's count programmes name the chain, and the pack carries it.

do $pack$
declare
  v_n integer;
begin
  update erp_ref.pack_item pi
     set payload = pi.payload || jsonb_build_object('approval_chain', 'count_variance')
   where pi.pack_code = 'base'
     and pi.object_kind = 'count_programme'
     and pi.object_key in ('CYCLE_A', 'CYCLE_C', 'STOCKTAKE')
     and not (pi.payload ? 'approval_chain');
  get diagnostics v_n = row_count;
  if v_n <> 3 then
    raise exception 'CLOVEERP_PACK_TEMPLATE_MISSING: % of the base pack''s three count programmes took the count_variance chain', v_n
      using hint = 'The programmes are registered by 20260903160000; a key changed, or a programme already names a chain.';
  end if;

  insert into erp_ref.pack_item (pack_code, object_kind, object_key, payload, provenance, seq)
  values ('base', 'approval_chain', 'count_variance',
          jsonb_build_object(
            'code', 'count_variance',
            'name', 'Count variance approval',
            'object_type', 'count_task',
            'applies_when', true,
            'priority', 100,
            'material_fields', jsonb_build_array('variance', 'counted'),
            'steps', jsonb_build_array(
              jsonb_build_object('seq', 1, 'code', 'warehouse_manager', 'name', 'Warehouse manager',
                                 'approver_kind', 'role', 'role', 'warehouse_manager',
                                 'min_approvals', 1))),
          'Starter Content Packs §7, count variance tolerance banded by value. A count '
          'outside its programme''s tolerance is agreed by the warehouse manager, who '
          'holds adjust and write-off, before it corrects the stock; once the '
          'organisation is live somebody other than the counter posts it (20260914070000).',
          3129)
  on conflict (pack_code, object_kind, object_key) do update set
    payload = excluded.payload, provenance = excluded.provenance, seq = excluded.seq;
end
$pack$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. A match exception is accepted once its approval is given
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.accept_match_exception(p_exception_id uuid, p_note text default null)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_me     uuid := erp.current_principal_id();
  e        erp.match_exception%rowtype;
  q        erp.approval_request%rowtype;
  v_order  text;
  v_line   integer;
  v_entity uuid;
  v_site   uuid;
  v_note   text := nullif(btrim(coalesce(p_note, '')), '');
  v_also   integer := 0;
  v_at     timestamptz := now();
begin
  select * into e
    from erp.match_exception x
   where x.tenant_id = v_tenant and x.id = p_exception_id
     for update;

  if not found then
    raise exception 'CLOVEERP_UNKNOWN_MATCH_EXCEPTION: no such match exception in this organisation'
      using errcode = '23503',
            hint = 'Choose the exception from the match workbench, which lists the ones still open.';
  end if;

  select d.document_number, ol.line_no, d.entity_id, d.site_id
    into v_order, v_line, v_entity, v_site
    from erp.document_line ol
    join erp.document d on d.tenant_id = ol.tenant_id and d.id = ol.document_id
   where ol.tenant_id = v_tenant and ol.id = e.order_line_id;

  -- Accepting a variance belongs with matching: the permission a bill is
  -- raised and matched under, for the order's company and site.
  perform erp.authorise('procurement.match', v_entity, v_site, null,
                        'match_exception', p_exception_id);

  if e.resolved_at is not null then
    raise exception 'CLOVEERP_MATCH_EXCEPTION_RESOLVED: the exception on line % of % is resolved already: %',
      v_line, coalesce(v_order, 'its order'), coalesce(e.resolution, 'resolved')
      using errcode = '23514',
            hint = 'Nothing is left to accept. The match workbench lists the exceptions still open.';
  end if;

  if e.approval_request_id is not null then
    select * into q
      from erp.approval_request ar
     where ar.tenant_id = v_tenant and ar.id = e.approval_request_id;
  end if;

  if q.status::text = 'rejected' then
    raise exception 'CLOVEERP_MATCH_EXCEPTION_REFUSED: the approval asked for the difference on line % of % was refused',
      v_line, coalesce(v_order, 'its order')
      using errcode = '23514',
            hint = 'Dispute the supplier''s invoice, or ask the supplier for a credit note, and match the line again.';
  end if;

  if q.id is null or q.status::text is distinct from 'approved' then
    raise exception 'CLOVEERP_MATCH_EXCEPTION_NOT_APPROVED: the difference on line % of % %',
      v_line, coalesce(v_order, 'its order'),
      case
        when q.id is null then 'was never sent for approval, because its match tolerance names no approval chain'
        when q.status::text = 'pending' then 'is still waiting on its approval'
        else 'was sent for approval again by a later match on the same line'
      end
      using errcode = '23514',
            hint = 'Accept it once the people asked have approved it under My approvals. Where a later match asked again, accept the newest exception on the line; where nothing asks, give the match tolerance an approval chain and match the line again.';
  end if;

  -- Maker and checker, as for a document's approval (20260914062000): once the
  -- organisation is live, whoever raised the request does not accept it, unless
  -- no step applied and nobody's judgement was needed.
  if q.requested_by = v_me
     and erp.tenant_is_live(v_tenant)
     and exists (select 1 from erp.approval_task t
                  where t.tenant_id = v_tenant and t.approval_request_id = q.id
                    and t.status <> 'skipped') then
    raise exception 'CLOVEERP_MATCH_EXCEPTION_SELF_ACCEPTANCE: you raised the exception on line % of %, so somebody else accepts it',
      v_line, coalesce(v_order, 'its order')
      using errcode = '42501',
            hint = 'Ask somebody else who may match invoices to accept it. Nobody accepts their own exception once the organisation is live.';
  end if;

  update erp.match_exception x
     set resolved_at = v_at,
         resolved_by = v_me,
         resolution  = left(case when v_note is null then 'accepted after approval'
                                 else 'accepted after approval: ' || v_note end, 1000),
         updated_at  = v_at
   where x.tenant_id = v_tenant and x.id = e.id;

  -- The older exceptions on the same line whose requests this one's superseded:
  -- the line's difference was asked about again and approved, and nothing else
  -- could ever release them.
  update erp.match_exception x
     set resolved_at = v_at,
         resolved_by = v_me,
         resolution  = 'accepted with the later exception on the line',
         updated_at  = v_at
   where x.tenant_id = v_tenant
     and x.order_line_id = e.order_line_id
     and x.id <> e.id
     and x.resolved_at is null
     and x.created_at <= e.created_at
     and exists (select 1 from erp.approval_request ar
                  where ar.tenant_id = v_tenant and ar.id = x.approval_request_id
                    and ar.status::text in ('superseded', 'cancelled'));
  get diagnostics v_also = row_count;

  return jsonb_build_object(
    'exception_id', e.id,
    'order_document_number', v_order,
    'line_no', v_line,
    'resolved_at', v_at,
    'also_resolved', v_also);
end;
$$;

comment on function erp.accept_match_exception(uuid, text) is
  'Accepts a three-way match exception whose approval request is approved, under '
  'procurement.match: resolves it, with the note, and the older exceptions on the '
  'same order line whose requests it superseded, so the invoice leaves the payment '
  'hold. Refuses an unknown or resolved exception, one whose request is pending, '
  'superseded, absent or refused, and, once live, the person who raised a request '
  'somebody was asked to decide (20260914070000).';

revoke all on function erp.accept_match_exception(uuid, text) from public, anon, authenticated;

create or replace function public.erp_accept_match_exception(
  p_exception_id uuid,
  p_note         text default null
) returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select erp.accept_match_exception(p_exception_id, p_note)
$$;

comment on function public.erp_accept_match_exception(uuid, text) is
  'Accepts a three-way match exception once its approval is given, so the invoice '
  'can go into a payment run. Authorises procurement.match; refuses the person who '
  'raised the exception once the organisation is live. Runs as the caller.';

revoke all on function public.erp_accept_match_exception(uuid, text) from public, anon;
grant execute on function public.erp_accept_match_exception(uuid, text) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale)
values
  ('erp_accept_match_exception', 'erp.accept_match_exception',
   'Resolves a three-way match exception whose approval request is approved, and the older exceptions on its order line that request superseded. Gated on procurement.match inside erp.accept_match_exception(), which refuses a pending, superseded or refused approval, and the person who raised it once the organisation is live (20260914070000).')
on conflict (function_name) do update set
  gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/procurement', array['erp_accept_match_exception']);

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. A batch is released on what quality decided, by somebody else
-- ═════════════════════════════════════════════════════════════════════════════

do $patch$
declare
  v_sig text := 'erp.release_batch(uuid,uuid,text,text,uuid)';
  v_def text := pg_get_functiondef('erp.release_batch(uuid,uuid,text,text,uuid)'::regprocedure);
  v_n   text := $n$  -- §5.8: the inspection the receipt raised stands between quarantine and release.
$n$;
  v_r   text := $r$  -- What quality last decided about the batch stands between it and release,
  -- and so does who decided it (20260914070000).
  declare
    v_named_batch uuid;
    v_named_by    uuid;
    v_last_insp   uuid;
    v_last_disp   erp.disposition;
    v_last_by     uuid;
    v_failed      integer;
    v_failed_disp text;
  begin
    if p_inspection_id is not null then
      select ins.batch_id, ins.disposition_by
        into v_named_batch, v_named_by
        from erp.inspection ins
       where ins.tenant_id = v_tenant and ins.id = p_inspection_id;

      if v_named_batch is distinct from p_batch_id then
        raise exception 'CLOVEERP_INSPECTION_NOT_OF_THIS_BATCH: the inspection named is not an inspection of batch %',
          b.batch_number
          using errcode = '23514',
                hint = 'Choose one of this batch''s own inspections. A release rests on what was found in the batch released.';
      end if;
    end if;

    -- The latest decision, whichever inspection carried it.
    select ins.id, ins.disposition, ins.disposition_by
      into v_last_insp, v_last_disp, v_last_by
      from erp.inspection ins
     where ins.tenant_id = v_tenant
       and ins.batch_id = p_batch_id
       and ins.status <> 'cancelled'
       and ins.disposition <> 'pending'
     order by coalesce(ins.disposition_at, ins.completed_at, ins.created_at) desc,
              ins.created_at desc, ins.id
     limit 1;

    if v_last_disp in ('reject', 'destroy') then
      raise exception 'CLOVEERP_BATCH_REJECTED: batch % was last dispositioned %, and a rejected batch is not released',
        b.batch_number, v_last_disp
        using errcode = '23514',
              hint = 'Quarantine it until it is dealt with as rejected. Only a new inspection that accepts the batch can take it to release.';
    end if;

    -- A result out of specification is released only on a concession: an
    -- inspection accepted, with the reason erp.disposition_inspection demands.
    select count(*), min(ins.disposition::text)
      into v_failed, v_failed_disp
      from erp.inspection ins
      join erp.inspection_result ir
        on ir.tenant_id = ins.tenant_id and ir.inspection_id = ins.id
     where ins.tenant_id = v_tenant
       and ins.batch_id = p_batch_id
       and ins.id in (v_last_insp, p_inspection_id)
       and ins.disposition not in ('accept', 'accept_with_concession')
       and ir.is_within_spec is false;

    if v_failed > 0 then
      raise exception 'CLOVEERP_BATCH_INSPECTION_FAILED: batch % has % result(s) out of specification on an inspection dispositioned %, not accepted',
        b.batch_number, v_failed, v_failed_disp
        using errcode = '23514',
              hint = 'Inspect the batch again once it has been dealt with, or record a concession by accepting the inspection with its reason, then release it.';
    end if;

    if erp.tenant_is_live(v_tenant)
       and erp.current_principal_id() in (v_last_by, v_named_by) then
      raise exception 'CLOVEERP_BATCH_SELF_RELEASE: you dispositioned the inspection batch % is released on, so somebody else releases it',
        b.batch_number
        using errcode = '42501',
              hint = 'Ask somebody else who may release batches to review the inspection and sign the release. Nobody releases a batch they dispositioned once the organisation is live.';
    end if;
  end;

  -- §5.8: the inspection the receipt raised stands between quarantine and release.
$r$;
begin
  if position('CLOVEERP_BATCH_SELF_RELEASE' in v_def) > 0 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % already refuses a release by whoever dispositioned', v_sig;
  end if;
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_RELEASE_BATCH_UNRECOGNISED: % does not carry the outstanding-inspection check 20260906142000 added', v_sig
      using hint = 'A later migration changed how a batch is released. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_n, v_r);
end
$patch$;

-- The line door's counterpart for inspections: the release form offers the
-- chosen batch's own. Dropped rather than overloaded, for the reason
-- 20260914050000 gives: two functions under one public name resolve to neither.

drop function public.erp_inspections(integer);

create function public.erp_inspections(
  p_limit    integer default 100,
  p_batch_id uuid    default null
)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by x->>'started_at' desc nulls last), '[]'::jsonb) from (
    select jsonb_build_object(
             'inspection_id', ins.id, 'item', i.code, 'batch', b.batch_number,
             'batch_id', ins.batch_id,
             'status', ins.status, 'disposition', ins.disposition,
             'quantity_inspected', ins.quantity_inspected,
             'started_at', ins.started_at, 'completed_at', ins.completed_at) as x
      from erp.inspection ins
      left join erp.item i on i.tenant_id = ins.tenant_id and i.id = ins.item_id
      left join erp.batch b on b.tenant_id = ins.tenant_id and b.id = ins.batch_id
     where ins.tenant_id = erp.current_tenant_id()
       and (p_batch_id is null or ins.batch_id = p_batch_id)
     order by ins.started_at desc nulls last
     limit greatest(p_limit, 1)) t;
$$;

comment on function public.erp_inspections(integer, uuid) is
  'The organisation''s inspections, newest first; with p_batch_id, only that '
  'batch''s, which is what the release form offers. Reads under row security as '
  'the caller, and authorises nothing.';

revoke all on function public.erp_inspections(integer, uuid) from public, anon;
grant execute on function public.erp_inspections(integer, uuid) to authenticated, service_role;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. After a delivery
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.consume_allocations_for_delivery(p_delivery_id uuid)
returns numeric
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  r        record;
  a        record;
  al_line  record;
  v_left   numeric;
  v_held   numeric;
  v_take   numeric;
  v_part   numeric;
  v_total  numeric := 0;
  v_lines  uuid[] := '{}'::uuid[];
  v_line   uuid;
begin
  -- What the delivery took from each sales order line, and where it left from.
  for r in
    select rel.to_line_id as order_line_id,
           mv.from_location_id as location_id,
           mv.batch_id,
           sum(rel.quantity) as quantity
      from erp.document_relation rel
      join erp.document_line ol
        on ol.tenant_id = rel.tenant_id and ol.id = rel.to_line_id
      join erp.document od
        on od.tenant_id = ol.tenant_id and od.id = ol.document_id
      join erp.document_type odt
        on odt.tenant_id = od.tenant_id and odt.id = od.document_type_id
      left join lateral (
        select m.from_location_id, m.batch_id
          from erp.stock_movement m
         where m.tenant_id = rel.tenant_id
           and m.document_id = p_delivery_id
           and m.document_line_id = rel.from_line_id
           and not m.is_reversal
         order by m.id
         limit 1) mv on true
     where rel.tenant_id = v_tenant
       and rel.from_document_id = p_delivery_id
       and rel.relation_kind = 'fulfils'
       and rel.to_line_id is not null
       and odt.base_type_code = 'sales_order'
     group by rel.to_line_id, mv.from_location_id, mv.batch_id
     order by rel.to_line_id, mv.from_location_id, mv.batch_id
  loop
    if not (r.order_line_id = any (v_lines)) then
      v_lines := v_lines || r.order_line_id;
    end if;

    v_left := r.quantity;

    -- Picked before committed before reserved: the stock furthest along is the
    -- stock that left.
    for a in
      select al.id, al.status::text as status, al.quantity,
             coalesce(al.unmet_quantity, 0) as unmet
        from erp.allocation al
       where al.tenant_id = v_tenant
         and al.document_line_id = r.order_line_id
         and al.status in ('picked', 'committed', 'reserved')
       order by case al.status when 'picked' then 0 when 'committed' then 1 else 2 end,
                al.created_at, al.id
         for update
    loop
      exit when v_left <= 0;

      v_held := a.quantity - a.unmet;
      continue when v_held <= 0;

      v_take := least(v_left, v_held);

      if v_take >= v_held then
        update erp.allocation_line l
           set status = 'consumed', updated_at = now()
         where l.tenant_id = v_tenant and l.allocation_id = a.id
           and l.status in ('picked', 'committed');
        update erp.allocation al
           set status = 'consumed', updated_at = now()
         where al.tenant_id = v_tenant and al.id = a.id;
      else
        -- Part of it: the lines at the place and batch the goods left from
        -- give up their quantity first, and what is given up stays on file as
        -- a consumed line beside what is still held.
        v_part := v_take;
        for al_line in
          select l.id, l.quantity
            from erp.allocation_line l
           where l.tenant_id = v_tenant and l.allocation_id = a.id
             and l.status in ('picked', 'committed')
           order by (l.location_id is not distinct from r.location_id) desc,
                    (l.batch_id is not distinct from r.batch_id) desc,
                    l.created_at, l.id
             for update
        loop
          exit when v_part <= 0;
          if al_line.quantity <= v_part then
            update erp.allocation_line l
               set status = 'consumed', updated_at = now()
             where l.tenant_id = v_tenant and l.id = al_line.id;
            v_part := v_part - al_line.quantity;
          else
            insert into erp.allocation_line (
              tenant_id, allocation_id, location_id, batch_id, serial_id, container_id,
              stock_status, quantity, status, picked_at, picked_by)
            select l.tenant_id, l.allocation_id, l.location_id, l.batch_id, l.serial_id, l.container_id,
                   l.stock_status, v_part, 'consumed', l.picked_at, l.picked_by
              from erp.allocation_line l
             where l.tenant_id = v_tenant and l.id = al_line.id;
            update erp.allocation_line l
               set quantity = l.quantity - v_part, updated_at = now()
             where l.tenant_id = v_tenant and l.id = al_line.id;
            v_part := 0;
          end if;
        end loop;

        update erp.allocation al
           set quantity = al.quantity - v_take, updated_at = now()
         where al.tenant_id = v_tenant and al.id = a.id;
      end if;

      v_left := v_left - v_take;
      v_total := v_total + v_take;
    end loop;
  end loop;

  -- An order line delivered in full holds nothing back: whatever is still
  -- reserved or committed for it is released.
  foreach v_line in array v_lines loop
    perform erp.refresh_order_line_progress(v_line);

    if exists (select 1 from erp.document_line ol
                where ol.tenant_id = v_tenant and ol.id = v_line
                  and ol.quantity > 0 and ol.quantity_fulfilled >= ol.quantity) then
      update erp.allocation_line l
         set status = 'released', updated_at = now()
        from erp.allocation al
       where l.tenant_id = v_tenant
         and al.tenant_id = l.tenant_id and al.id = l.allocation_id
         and al.document_line_id = v_line
         and al.status in ('picked', 'committed', 'reserved')
         and l.status in ('picked', 'committed');
      update erp.allocation al
         set status = 'released', updated_at = now()
       where al.tenant_id = v_tenant
         and al.document_line_id = v_line
         and al.status in ('picked', 'committed', 'reserved');
    end if;
  end loop;

  return v_total;
end;
$$;

comment on function erp.consume_allocations_for_delivery(uuid) is
  'Called when a delivery raised from a sales order posts. Each order line''s '
  'allocations give up what the delivery took (picked, then committed, then '
  'reserved; committed lines at the location and batch the goods left from '
  'first), and a line delivered in full releases what is still held for it, so '
  'available-to-promise does not subtract a commitment for goods already gone. '
  'Returns the quantity consumed. Authorises nothing: the posting was '
  'authorised (20260914070000).';

revoke all on function erp.consume_allocations_for_delivery(uuid) from public, anon, authenticated;

do $patch$
declare
  v_sig text := 'erp.advance_orders_for_delivery(uuid)';
  v_def text := pg_get_functiondef('erp.advance_orders_for_delivery(uuid)'::regprocedure);
  v_n   text := $n$  select dn.document_number into v_number
    from erp.document dn
   where dn.tenant_id = v_tenant and dn.id = p_delivery_id;
$n$;
  v_r   text := $r$  select dn.document_number into v_number
    from erp.document dn
   where dn.tenant_id = v_tenant and dn.id = p_delivery_id;

  -- What the delivery took is no longer held for its order (20260914070000).
  perform erp.consume_allocations_for_delivery(p_delivery_id);
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % is not the body 20260914064000 wrote', v_sig
      using hint = 'A later migration changed how a delivery moves its order on. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_n, v_r);
end
$patch$;

do $patch$
declare
  v_sig text := 'erp.invoice_from_delivery(uuid,boolean)';
  v_def text := pg_get_functiondef('erp.invoice_from_delivery(uuid,boolean)'::regprocedure);
  v_n1  text := $n$    select m.item_id, sum(m.quantity) as qty,
           max(dl.unit_price_minor) as price,
$n$;
  v_r1  text := $r$    select m.item_id, sum(m.quantity) as qty,
           -- Each price and discount the delivery's lines carry is a line of
           -- its own (20260914070000): what the order agreed is what is billed,
           -- and two lines of one product at different terms are not one line
           -- at the higher price.
           coalesce(dl.unit_price_minor, 0) as price,
           coalesce(dl.discount_pct, 0) as discount_pct,
$r$;
  v_n2  text := $n$     group by m.item_id
  loop
$n$;
  v_r2  text := $r$     group by m.item_id, coalesce(dl.unit_price_minor, 0), coalesce(dl.discount_pct, 0)
     order by min(dl.line_no) nulls last, coalesce(dl.unit_price_minor, 0), coalesce(dl.discount_pct, 0)
  loop
$r$;
  v_n3  text := $n$      unit_price_minor, net_minor, currency)
    values (v_tenant, v_inv, v_no, r.item_id,
            coalesce(r.description, 'delivered'), r.qty, r.uom,
            coalesce(r.price, 0), round(r.qty * coalesce(r.price, 0))::bigint,
            dn.currency)
$n$;
  v_r3  text := $r$      unit_price_minor, discount_pct, net_minor, currency)
    values (v_tenant, v_inv, v_no, r.item_id,
            coalesce(r.description, 'delivered'), r.qty, r.uom,
            coalesce(r.price, 0), r.discount_pct,
            -- Net of the discount, as a sales line is priced everywhere else.
            round(r.qty * coalesce(r.price, 0) * (1 - r.discount_pct / 100.0))::bigint,
            dn.currency)
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n1, ''))) / length(v_n1) <> 1
     or (length(v_def) - length(replace(v_def, v_n2, ''))) / length(v_n2) <> 1
     or (length(v_def) - length(replace(v_def, v_n3, ''))) / length(v_n3) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % is not the body 20260829280000 wrote', v_sig
      using hint = 'A later migration changed how a delivery is invoiced. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(replace(replace(v_def, v_n1, v_r1), v_n2, v_r2), v_n3, v_r3);
end
$patch$;

-- The event a receipt records when the order it answers cannot move on.

insert into erp_ref.event_type
  (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
values
  ('document.progress_not_advanced', 1, 'document', 'procurement', 'event.document.progress_not_advanced',
   'A goods receipt posted and the purchase order it was received against could not be '
   'moved on by it: a guard, a permission or its lifecycle refused the move. The receipt '
   'stands, and the order waits where it is for somebody who may move it. transition is '
   'the move that was tried, reason why it was refused, receipt_id the receipt.',
   '{"type": "object", "required": ["transition", "reason"],
     "properties": {"transition": {"type": "string"},
                    "reason": {"type": "string"},
                    "receipt_id": {"type": "string"}}}'::jsonb,
   true)
on conflict (code, version) do update set
  aggregate_type = excluded.aggregate_type, module_code = excluded.module_code,
  name_key = excluded.name_key, description = excluded.description,
  payload_schema = excluded.payload_schema, is_current = excluded.is_current;

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('event.document.progress_not_advanced', 'en', 'Order not moved on by its receipt', 'procurement',
   'The event recorded when a goods receipt posts and the order it answers cannot move on.'),
  ('event.document.progress_not_advanced', 'de', 'Bestellung durch den Wareneingang nicht weitergeführt', 'procurement',
   'The event recorded when a goods receipt posts and the order it answers cannot move on.')
on conflict (key, locale) do update set
  value = excluded.value, module_code = excluded.module_code, description = excluded.description;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The suites these rules touch
-- ═════════════════════════════════════════════════════════════════════════════

do $patch$
declare
  v_sig text := 'erp_test.inventory_suite()';
  v_def text := pg_get_functiondef('erp_test.inventory_suite()'::regprocedure);
  v_n   text := $n$  v_var := erp.post_count(v_task);
  return query select 'and posting it writes an adjustment movement',
$n$;
  v_r   text := $r$  -- Posted by the second administrator: whoever counted does not post the
  -- variance once the organisation is live (20260914070000).
  perform set_config('request.jwt.claims', json_build_object('sub',a2)::text, true);
  v_var := erp.post_count(v_task);
  perform set_config('request.jwt.claims', json_build_object('sub',a1)::text, true);
  return query select 'and posting it writes an adjustment movement',
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % does not post its variance where this migration expects', v_sig
      using hint = 'A later migration changed who posts the suite''s count. Read the suite and patch that body.';
  end if;
  execute replace(v_def, v_n, v_r);
end
$patch$;

do $patch$
declare
  v_sig text := 'erp_test.quality_logistics_suite()';
  v_def text := pg_get_functiondef('erp_test.quality_logistics_suite()'::regprocedure);
  v_n   text := $n$  v_rel := erp.release_batch(v_batch, v_site, 'inspection accepted with concession',
                             'QP/2026/001', v_insp);
$n$;
  v_r   text := $r$  -- Released by the second administrator: whoever dispositioned the
  -- inspection does not release the batch once the organisation is live
  -- (20260914070000).
  perform set_config('request.jwt.claims', json_build_object('sub',a2)::text, true);
  v_rel := erp.release_batch(v_batch, v_site, 'inspection accepted with concession',
                             'QP/2026/001', v_insp);
  perform set_config('request.jwt.claims', json_build_object('sub',a1)::text, true);
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % does not release its batch where this migration expects', v_sig
      using hint = 'A later migration changed who releases the suite''s batch. Read the suite and patch that body.';
  end if;
  execute replace(v_def, v_n, v_r);
end
$patch$;

do $acceptance$
declare
  v_sig text := 'erp_test.starter_pack_acceptance_suite()';
  v_def text := pg_get_functiondef('erp_test.starter_pack_acceptance_suite()'::regprocedure);
  v_n   text := $n$    (res ->> 'items')::integer = 345
$n$;
  v_r   text := $r$    -- 346 since 20260914070000: the pack carries the count_variance chain
    -- its count programmes name, asked of warehouse_manager, and the inventory
    -- installer this organisation ran asked administrator, so the chain is
    -- planned as an update.
    (res ->> 'items')::integer = 346
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_ACCEPTANCE_SUITE_UNRECOGNISED: % does not count 345 planned items once', v_sig
      using hint = 'A later migration recounted the base pack. Read the suite and patch its count.';
  end if;
  execute replace(v_def, v_n, v_r);

  if position('integer = 346' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_ACCEPTANCE_SUITE_UNRECOGNISED: % did not take its new count', v_sig;
  end if;
end
$acceptance$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The refusals, and the words on the screens
-- ═════════════════════════════════════════════════════════════════════════════

select erp.register_refusal('CLOVEERP_COUNT_SELF_POSTING',
  'Posting the variance of a count you recorded yourself.',
  'A count is one person''s word about what is on the shelf. Once the organisation is live, correcting the stock by it takes a second person, so a shortage cannot be counted and written off by the same hand.',
  'Ask somebody else who may adjust stock to post the count.');

select erp.register_refusal('CLOVEERP_UNKNOWN_MATCH_EXCEPTION',
  'Accepting a match exception this organisation does not have.',
  'The exception named does not exist here: it may belong to another organisation, or the list it was chosen from is out of date.',
  'Refresh the match workbench and choose the exception again.');

select erp.register_refusal('CLOVEERP_MATCH_EXCEPTION_RESOLVED',
  'Accepting a match exception that is already resolved.',
  'It was accepted already, or a later match on the line agreed with the order and resolved it.',
  'Nothing is left to accept. The match workbench lists the exceptions still open.');

select erp.register_refusal('CLOVEERP_MATCH_EXCEPTION_NOT_APPROVED',
  'Accepting a match exception whose approval has not been given.',
  'An invoice that does not agree with its order and receipt is paid only once somebody asked has agreed the difference. The approval is still waiting, was asked again by a later match, or was never asked for.',
  'Wait for the approval under My approvals, then accept it. Where a later match asked again, accept the newest exception on the line.');

select erp.register_refusal('CLOVEERP_MATCH_EXCEPTION_REFUSED',
  'Accepting a match exception whose approval was refused.',
  'Somebody asked to agree the difference said no, and a single refusal decides an approval.',
  'Dispute the supplier''s invoice or ask for a credit note, then match the line again.');

select erp.register_refusal('CLOVEERP_MATCH_EXCEPTION_SELF_ACCEPTANCE',
  'Accepting a match exception you raised yourself.',
  'Accepting a difference on a supplier''s invoice lets it be paid. Once the organisation is live, the person who matched the invoice and raised the exception does not also accept it.',
  'Ask somebody else who may match invoices to accept it.');

select erp.register_refusal('CLOVEERP_INSPECTION_NOT_OF_THIS_BATCH',
  'Releasing a batch on an inspection of a different batch.',
  'A release rests on what was found in the batch being released. An inspection of another batch says nothing about this one.',
  'Choose one of this batch''s own inspections.');

select erp.register_refusal('CLOVEERP_BATCH_REJECTED',
  'Releasing a batch whose latest disposition is reject or destroy.',
  'Quality decided the batch is not to be used. Releasing it would put rejected goods into available stock.',
  'Keep it in quarantine and deal with it as rejected. Only a new inspection that accepts the batch can take it to release.');

select erp.register_refusal('CLOVEERP_BATCH_INSPECTION_FAILED',
  'Releasing a batch whose inspection found results out of specification and did not accept them.',
  'Goods outside their specification are released only on a concession: an inspection accepted with the reason for accepting it.',
  'Inspect the batch again once it has been dealt with, or accept the inspection with a concession and its reason, then release it.');

select erp.register_refusal('CLOVEERP_BATCH_SELF_RELEASE',
  'Releasing a batch on an inspection you dispositioned yourself.',
  'Deciding what a batch is and signing it out for use are two people''s decisions. Once the organisation is live, whoever dispositioned the inspection does not also release the batch.',
  'Ask somebody else who may release batches to review the inspection and sign the release.');

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string declared at its call site and rendered through ui(). ' || v.why
  from (values
    ('Inspection',
     'The inspection field on the form that releases a batch, chosen from that batch''s own inspections.'),
    ('The inspection of this batch the release relies on. A batch last rejected, or whose inspection failed, is not released, and once the organisation is live nobody releases a batch they dispositioned.',
     'The inspection field on the form that releases a batch (20260914070000).'),
    ('Accept a match exception',
     'The button on Purchasing that accepts a three-way match exception once its approval is given.'),
    ('Accept an invoice that did not match',
     'The title of the form that accepts a match exception.'),
    ('Once the approval the exception asked for has been given, the difference is accepted and the invoice can go into a payment run. Whoever raised the exception does not accept it once the organisation is live.',
     'What the form that accepts a match exception does.'),
    ('Match exception',
     'The field on the form that accepts a match exception, chosen from the match workbench.'),
    ('Optional. Kept with the exception.',
     'The note on the form that accepts a match exception, explained.'),
    ('Accept it',
     'The button that submits the form accepting a match exception.'),
    ('Decide a count variance',
     'The button on Stock audit that decides the approval a count outside tolerance waits on.'),
    ('A count outside its programme''s tolerance waits for the approving role to agree. Agreed, it can be posted; refused, it stays as it was found and is not posted.',
     'What the form that decides a count variance does.'),
    ('Correct the stock by an agreed difference. Once the organisation is live, somebody other than the person who counted it posts it.',
     'What the form that posts a count does, once a count could not be posted by its counter.')
) as v(text, why)
on conflict (key, locale) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- One live organisation with two administrators: the first buys, sells,
-- counts nothing, inspects and dispositions; the second approves, promotes,
-- invoices and releases. Finance, procurement, sales, inventory, quality and
-- procurement controls are installed through changes the second promotes.
-- Five people hold one narrow role each, made with the organisation's window
-- opened for the purpose and granted directly: two warehouse managers (the base
-- pack's own role, promoted from the pack's plan), a matcher, an onlooker, and
-- a receiver who may receive only at a second site. Each part of the suite
-- runs in a block of its own, so a part that fails reports its own step and the
-- others still run; the whole organisation is undone at the end.

create or replace function erp_test.accept_match_exception_as(
  p_subject      uuid,
  p_exception_id uuid,
  p_note         text default null
) returns table (outcome jsonb, ran_as text, err_state text, err_message text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_owner  text := current_user;
  v_claims text := coalesce(current_setting('request.jwt.claims', true), '');
begin
  perform set_config('request.jwt.claims',
                     json_build_object('sub', p_subject, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    ran_as := current_user;
    outcome := public.erp_accept_match_exception(p_exception_id, p_note);
  exception when others then
    get stacked diagnostics err_state = returned_sqlstate,
                            err_message = message_text;
  end;
  execute format('set local role %I', v_owner);
  perform set_config('request.jwt.claims', v_claims, true);
  return next;
end;
$$;

comment on function erp_test.accept_match_exception_as(uuid, uuid, text) is
  'Suite helper: calls public.erp_accept_match_exception for one exception as the '
  'given sign-in, in the authenticated role, and returns its answer and the role it '
  'ran as, or its refusal. Returns to the calling role and claims before it returns.';

revoke all on function erp_test.accept_match_exception_as(uuid, uuid, text) from public, anon, authenticated;

create or replace function erp_test.controls_finish_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_hex    text := substr(md5(gen_random_uuid()::text), 1, 8);
  v_owner  text := current_user;
  a1       uuid := gen_random_uuid();   -- the first administrator
  a2       uuid := gen_random_uuid();   -- the second, who approves and releases
  s_cole   uuid := gen_random_uuid();   -- a warehouse manager, who counts
  s_mia    uuid := gen_random_uuid();   -- a warehouse manager, who approves and posts
  s_mat    uuid := gen_random_uuid();   -- holds procurement.read and procurement.match
  s_lou    uuid := gen_random_uuid();   -- holds procurement.read, and nothing else
  s_rex    uuid := gen_random_uuid();   -- holds procurement.receive at the east site only
  r        record;
  it       record;
  g        record;
  res      jsonb;
  v_second uuid;
  v_tok    text;
  cs_fin   uuid;
  cs_proc  uuid;
  cs_sales uuid;
  cs_inv   uuid;
  cs_qual  uuid;
  cs_ctl   uuid;
  v_cs     uuid;
  v_task   uuid;
  v_line   uuid;
  v_step   text := 'reading the doors';
  v_state  text;
  -- The doors as the catalogue holds them.
  v_an     integer;
  v_aargs  text;
  v_adef   boolean;
  v_avol   boolean;
  v_agrant boolean;
  v_agate  text;
  v_in     integer;
  v_iargs  text;
  v_idef   boolean;
  v_istab  boolean;
  v_igrant boolean;
  -- The organisation.
  v_uom    uuid;
  v_site   uuid;
  v_east   uuid;
  v_quar   uuid;
  v_sup    uuid;
  v_cust   uuid;
  v_cnt    uuid;
  v_wid    uuid;
  v_mat    uuid;
  v_rcv    uuid;
  v_chill  uuid;
  u_cole   uuid;
  u_mia    uuid;
  u_mat    uuid;
  u_lou    uuid;
  u_rex    uuid;
  -- Counting.
  v_state_count   text;
  v_pack_breaks   text;
  v_pack_chain    jsonb;
  v_planned       integer := 0;
  v_prog_chain    text;
  v_chain_roles   text[];
  v_grn           uuid;
  v_t1            uuid;
  v_t1_status     text;
  v_t1_tasks      integer;
  v_t1_managers   integer;
  v_t1_decided    text;
  v_t1_after      text;
  v_self_post_err text;
  v_t1_still      text;
  v_moves_before  integer;
  v_t1_posted     numeric;
  v_t1_final      text;
  v_moves_after   integer;
  v_t2            uuid;
  v_t2_decided    text;
  v_t2_after      text;
  v_t2_locks      integer;
  v_t2_post_err   text;
  v_t3            uuid;
  v_t3_posted     numeric;
  v_t3_err        text;
  v_t3_final      text;
  -- Delivering.
  v_state_deliver text;
  v_so1           uuid;
  v_so1_l         uuid;
  v_a1_before     text;
  v_committed_before numeric;
  v_dn1           jsonb;
  v_dn1_id        uuid;
  v_a1_after      text;
  v_a1_lines      text;
  v_on_hand1      numeric;
  v_committed1    numeric;
  v_available1    numeric;
  v_so2           uuid;
  v_so2_l         uuid;
  v_dn2           jsonb;
  v_a2_status     text;
  v_a2_qty        numeric;
  v_a2_held_lines numeric;
  v_a2_used_lines numeric;
  v_on_hand2      numeric;
  v_committed2    numeric;
  v_available2    numeric;
  v_inv           uuid;
  v_inv_lines     integer;
  v_inv_qty       numeric;
  v_inv_price     bigint;
  v_inv_disc      numeric;
  v_inv_net       bigint;
  -- Receiving at another site.
  v_state_receive text;
  v_po3           uuid;
  v_pol3          uuid;
  v_grn3          uuid;
  v_grn3_state    text;
  v_grn3_err      text;
  v_po3_state     text;
  v_events        integer;
  v_event_move    text;
  v_event_receipt boolean;
  v_event_current boolean;
  -- Matching.
  v_state_match   text;
  v_po            uuid;
  v_pol           uuid;
  v_pol2          uuid;
  v_inv2          uuid;
  v_e0            uuid;
  v_r0            uuid;
  v_e1            uuid;
  v_r1            uuid;
  v_e2            uuid;
  v_r2            uuid;
  v_r0_status     text;
  v_pending_err   text;
  v_r1_decided    text;
  v_superseded_err text;
  v_self_err      text;
  v_accept        jsonb;
  v_accept_as     text;
  v_accept_err    text;
  v_e1_resolved   boolean;
  v_e0_resolved   boolean;
  v_workbench     uuid[];
  v_again_err     text;
  v_look_state    text;
  v_look_err      text;
  v_r2_decided    text;
  v_refused_err   text;
  -- Releasing.
  v_state_quality text;
  v_b1            uuid;
  v_b2            uuid;
  v_b3            uuid;
  v_b4            uuid;
  v_grn4          uuid;
  v_i1            uuid;
  v_i2            uuid;
  v_i3            uuid;
  v_i4            uuid;
  v_listed        jsonb;
  v_listed_all    integer;
  v_q_self_err    text;
  v_b1_held       numeric;
  v_rel1          uuid;
  v_b1_available  numeric;
  v_q_reject_err  text;
  v_q_failed_err  text;
  v_q_other_err   text;
  v_rel4          uuid;
  v_q_prelive_err text;
  v_b4_available  numeric;
begin
  select count(*), min(pg_catalog.pg_get_function_identity_arguments(p.oid)),
         coalesce(bool_or(p.prosecdef), true),
         coalesce(bool_and(p.provolatile = 'v'), false),
         coalesce(bool_and(pg_catalog.has_function_privilege('authenticated', p.oid, 'execute')
                           and not pg_catalog.has_function_privilege('anon', p.oid, 'execute')), false)
    into v_an, v_aargs, v_adef, v_avol, v_agrant
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'erp_accept_match_exception';

  select w.gate into v_agate
    from erp_meta.public_write_allowance w
   where w.function_name = 'erp_accept_match_exception';

  select count(*), min(pg_catalog.pg_get_function_identity_arguments(p.oid)),
         coalesce(bool_or(p.prosecdef), true),
         coalesce(bool_and(p.provolatile = 's'), false),
         coalesce(bool_and(pg_catalog.has_function_privilege('authenticated', p.oid, 'execute')
                           and not pg_catalog.has_function_privilege('anon', p.oid, 'execute')), false)
    into v_in, v_iargs, v_idef, v_istab, v_igrant
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'erp_inspections';

  -- The base pack, as it ships.
  select string_agg(pi.object_key, ', ' order by pi.object_key) into v_pack_breaks
    from erp_ref.pack_item pi
   where pi.pack_code = 'base' and pi.object_kind = 'count_programme'
     and pi.payload ->> 'approval_chain' is distinct from 'count_variance';
  select pi.payload into v_pack_chain
    from erp_ref.pack_item pi
   where pi.pack_code = 'base' and pi.object_kind = 'approval_chain' and pi.object_key = 'count_variance';

  begin
    -- ── A live organisation, its two administrators and its modules ───────
    v_step := 'the organisation is provisioned and its two administrators join';
    select * into r from erp.provision_tenant(
      'zz-ctl-' || v_hex, 'Controls finish suite',
      'admin@zz-ctl-' || v_hex || '.test', 'Controls Admin');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    res := public.erp_invite_principal('second@zz-ctl-' || v_hex || '.test', 'Second Admin');
    v_second := (res ->> 'app_user_id')::uuid;
    v_tok := res ->> 'token';
    perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');

    v_step := 'the modules are installed, and the second administrator promotes them';
    cs_fin := erp.configure_finance();
    cs_proc := erp.configure_procurement(1000000);
    cs_sales := erp.configure_sales(15);
    cs_inv := erp.configure_inventory('average');
    cs_qual := erp.configure_quality();
    cs_ctl := erp.configure_procurement_controls();
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok);
    perform erp.approve_change_set(cs_fin);
    perform erp.promote_change_set(cs_fin);
    perform erp.approve_change_set(cs_proc);
    perform erp.promote_change_set(cs_proc);
    perform erp.approve_change_set(cs_sales);
    perform erp.promote_change_set(cs_sales);
    perform erp.approve_change_set(cs_inv);
    perform erp.promote_change_set(cs_inv);
    perform erp.approve_change_set(cs_qual);
    perform erp.promote_change_set(cs_qual);
    perform erp.approve_change_set(cs_ctl);
    perform erp.promote_change_set(cs_ctl);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_step := 'two sites, a supplier, a customer with credit and five products';
    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'EAST', 'East', 'warehouse', 'active') returning id into v_east;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (r.tenant_id, v_site, 'RECV', 'Goods in', 'receiving', 'active');
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (r.tenant_id, v_site, 'QUAR', 'Quarantine', 'quarantine', 'active') returning id into v_quar;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (r.tenant_id, v_east, 'ERECV', 'East goods in', 'receiving', 'active');
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'SUP', 'Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'CUST', 'Customer', 'active') returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, attributes, status)
    values (r.tenant_id, v_cust, 'customer', jsonb_build_object('credit_limit_minor', 100000000), 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'CNT', 'Counted widget', v_uom, 'active') returning id into v_cnt;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'WID', 'Widget', v_uom, 'active') returning id into v_wid;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'MAT', 'Matched widget', v_uom, 'active') returning id into v_mat;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'RCV', 'Received widget', v_uom, 'active') returning id into v_rcv;
    insert into erp.item (tenant_id, code, name, stock_uom_id, is_batch_controlled, quarantine_on_receipt, status)
    values (r.tenant_id, 'CHILL', 'Chilled thing', v_uom, true, true, 'active') returning id into v_chill;

    v_step := 'the base pack plans its warehouse manager, count variance chain and stocktake, and they are promoted';
    v_cs := erp.create_change_set('zzctl-count-' || v_hex, 'Counting from the base pack',
                                  'The base pack''s warehouse manager, count variance chain and stocktake, as the pack plans them.');
    for it in
      select p.object_kind, p.object_key, p.payload, p.operation
        from erp.plan_content_pack('base') p
       where (p.object_kind = 'role' and p.object_key = 'warehouse_manager')
          or (p.object_kind = 'approval_chain' and p.object_key = 'count_variance')
          or (p.object_kind = 'count_programme' and p.object_key = 'STOCKTAKE')
       order by p.seq, p.object_kind
    loop
      perform erp.add_change_set_item(v_cs, it.object_kind, it.object_key, it.payload,
                                      it.operation, null, 'the controls suite');
      v_planned := v_planned + 1;
    end loop;
    perform erp.submit_change_set(v_cs);
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.approve_change_set(v_cs);
    perform erp.promote_change_set(v_cs);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    select cp.approval_chain_code into v_prog_chain
      from erp.count_programme cp
     where cp.tenant_id = r.tenant_id and cp.code = 'STOCKTAKE' and cp.status = 'active';
    select array_agg(distinct ro.code order by ro.code) into v_chain_roles
      from erp.approval_chain ch
      join erp.approval_chain_version v
        on v.tenant_id = ch.tenant_id and v.approval_chain_id = ch.id and v.status = 'active'
      join erp.approval_step s on s.tenant_id = v.tenant_id and s.approval_chain_version_id = v.id
      join erp.role ro on ro.tenant_id = s.tenant_id and ro.id = s.role_id
     where ch.tenant_id = r.tenant_id and ch.code = 'count_variance';

    v_step := 'five people each hold one narrow role';
    perform erp_test.reopen_bootstrap_window(r.tenant_id);
    insert into erp.role (tenant_id, code, name, status) values
      (r.tenant_id, 'zz_matcher', 'Suite matcher', 'active'),
      (r.tenant_id, 'zz_onlooker', 'Suite onlooker', 'active'),
      (r.tenant_id, 'zz_east_receiver', 'Suite east receiver', 'active');
    insert into erp.role_permission (tenant_id, role_id, permission_code)
    select r.tenant_id, ro.id, x.perm
      from (values ('zz_matcher', 'procurement.read'), ('zz_matcher', 'procurement.match'),
                   ('zz_onlooker', 'procurement.read'),
                   ('zz_east_receiver', 'procurement.read'), ('zz_east_receiver', 'procurement.receive')) as x(role_code, perm)
      join erp.role ro on ro.tenant_id = r.tenant_id and ro.code = x.role_code;
    perform erp_test.close_bootstrap_window(r.tenant_id);

    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email, user_locale)
    values (r.tenant_id, s_cole, 'person', 'active', 'Cole Counter', 'cole@zz-ctl-' || v_hex || '.test', 'en')
    returning id into u_cole;
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email, user_locale)
    values (r.tenant_id, s_mia, 'person', 'active', 'Mia Manager', 'mia@zz-ctl-' || v_hex || '.test', 'en')
    returning id into u_mia;
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email, user_locale)
    values (r.tenant_id, s_mat, 'person', 'active', 'Mat Matcher', 'mat@zz-ctl-' || v_hex || '.test', 'en')
    returning id into u_mat;
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email, user_locale)
    values (r.tenant_id, s_lou, 'person', 'active', 'Lou Onlooker', 'lou@zz-ctl-' || v_hex || '.test', 'en')
    returning id into u_lou;
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email, user_locale)
    values (r.tenant_id, s_rex, 'person', 'active', 'Rex Receiver', 'rex@zz-ctl-' || v_hex || '.test', 'en')
    returning id into u_rex;
    -- The receiver's grant names the east site, and so the company that site
    -- sits under (user_role_site_needs_entity).
    insert into erp.user_role (tenant_id, app_user_id, role_id, entity_id, site_id, grant_reason)
    select r.tenant_id, x.person, ro.id, x.entity, x.site, 'The suite''s narrow role.'
      from (values (u_cole, 'warehouse_manager', null::uuid, null::uuid),
                   (u_mia, 'warehouse_manager', null::uuid, null::uuid),
                   (u_mat, 'zz_matcher', null::uuid, null::uuid),
                   (u_lou, 'zz_onlooker', null::uuid, null::uuid),
                   (u_rex, 'zz_east_receiver', r.entity_id, v_east)) as x(person, role_code, entity, site)
      join erp.role ro on ro.tenant_id = r.tenant_id and ro.code = x.role_code;

    -- ── Counting ───────────────────────────────────────────────────────────
    begin
      v_step := 'counting: fifty counted widgets are received';
      perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
      v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
      perform erp.add_document_line(v_grn, v_cnt, 50, 1000, 'stock to count');
      perform erp.transition_document(v_grn, 'post', 'controls suite');

      v_step := 'counting: a warehouse manager counts five short';
      perform set_config('request.jwt.claims', json_build_object('sub', s_cole)::text, true);
      perform erp.raise_count_tasks('STOCKTAKE');
      select t.id into v_t1
        from erp.count_task t
       where t.tenant_id = r.tenant_id and t.item_id = v_cnt and t.status = 'open';
      v_t1_status := erp.record_count(v_t1, 45)::text;
      select count(*), count(*) filter (where t.assignee_user_id in (u_cole, u_mia))
        into v_t1_tasks, v_t1_managers
        from erp.approval_task t
        join erp.approval_request q on q.tenant_id = t.tenant_id and q.id = t.approval_request_id
       where q.tenant_id = r.tenant_id and q.object_type = 'count_task' and q.object_id = v_t1
         and t.status = 'pending';

      v_step := 'counting: the other warehouse manager approves the variance';
      perform set_config('request.jwt.claims', json_build_object('sub', s_mia)::text, true);
      select t.id into v_task
        from erp.approval_task t
        join erp.approval_request q on q.tenant_id = t.tenant_id and q.id = t.approval_request_id
       where q.tenant_id = r.tenant_id and q.object_type = 'count_task' and q.object_id = v_t1
         and t.status = 'pending' and t.assignee_user_id = u_mia
       limit 1;
      v_t1_decided := erp.decide_approval_task(v_task, true, 'recounted, five are gone')::text;
      select t.status::text into v_t1_after from erp.count_task t where t.tenant_id = r.tenant_id and t.id = v_t1;

      v_step := 'counting: the counter posts his own count';
      perform set_config('request.jwt.claims', json_build_object('sub', s_cole)::text, true);
      begin
        perform erp.post_count(v_t1);
      exception when others then
        v_self_post_err := left(sqlerrm, 200);
      end;
      select t.status::text into v_t1_still from erp.count_task t where t.tenant_id = r.tenant_id and t.id = v_t1;
      select count(*) into v_moves_before
        from erp.stock_movement m
       where m.tenant_id = r.tenant_id and m.item_id = v_cnt and m.reason_code = 'count_variance';

      v_step := 'counting: the manager who approved posts it';
      perform set_config('request.jwt.claims', json_build_object('sub', s_mia)::text, true);
      v_t1_posted := erp.post_count(v_t1);
      select t.status::text into v_t1_final from erp.count_task t where t.tenant_id = r.tenant_id and t.id = v_t1;
      select count(*) into v_moves_after
        from erp.stock_movement m
       where m.tenant_id = r.tenant_id and m.item_id = v_cnt and m.reason_code = 'count_variance';

      v_step := 'counting: a second count, refused';
      perform set_config('request.jwt.claims', json_build_object('sub', s_cole)::text, true);
      perform erp.raise_count_tasks('STOCKTAKE');
      select t.id into v_t2
        from erp.count_task t
       where t.tenant_id = r.tenant_id and t.item_id = v_cnt and t.status = 'open';
      perform erp.record_count(v_t2, 40);
      perform set_config('request.jwt.claims', json_build_object('sub', s_mia)::text, true);
      select t.id into v_task
        from erp.approval_task t
        join erp.approval_request q on q.tenant_id = t.tenant_id and q.id = t.approval_request_id
       where q.tenant_id = r.tenant_id and q.object_type = 'count_task' and q.object_id = v_t2
         and t.status = 'pending' and t.assignee_user_id = u_mia
       limit 1;
      v_t2_decided := erp.decide_approval_task(v_task, false, 'count the bay again')::text;
      select t.status::text into v_t2_after from erp.count_task t where t.tenant_id = r.tenant_id and t.id = v_t2;
      select count(*) into v_t2_locks
        from erp.count_lock l
       where l.tenant_id = r.tenant_id and l.count_task_id = v_t2 and l.released_at is null;
      begin
        perform erp.post_count(v_t2);
      exception when others then
        v_t2_post_err := left(sqlerrm, 200);
      end;

      v_step := 'counting: before go-live the counter posts his own count';
      perform set_config('request.jwt.claims', json_build_object('sub', s_cole)::text, true);
      perform erp.raise_count_tasks('STOCKTAKE');
      select t.id into v_t3
        from erp.count_task t
       where t.tenant_id = r.tenant_id and t.item_id = v_cnt and t.status = 'open';
      perform erp.record_count(v_t3, 44);
      perform set_config('request.jwt.claims', json_build_object('sub', s_mia)::text, true);
      select t.id into v_task
        from erp.approval_task t
        join erp.approval_request q on q.tenant_id = t.tenant_id and q.id = t.approval_request_id
       where q.tenant_id = r.tenant_id and q.object_type = 'count_task' and q.object_id = v_t3
         and t.status = 'pending' and t.assignee_user_id = u_mia
       limit 1;
      perform erp.decide_approval_task(v_task, true, 'one missing');
      perform erp_test.reopen_bootstrap_window(r.tenant_id);
      perform set_config('request.jwt.claims', json_build_object('sub', s_cole)::text, true);
      begin
        v_t3_posted := erp.post_count(v_t3);
      exception when others then
        v_t3_err := left(sqlerrm, 200);
      end;
      perform erp_test.close_bootstrap_window(r.tenant_id);
      select t.status::text into v_t3_final from erp.count_task t where t.tenant_id = r.tenant_id and t.id = v_t3;
    exception when others then
      v_state_count := format('at "%s": %s', v_step, left(sqlerrm, 300));
      execute format('set local role %I', v_owner);
    end;

    -- ── Delivering ─────────────────────────────────────────────────────────
    begin
      v_step := 'delivering: a hundred widgets are received';
      perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
      v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
      perform erp.add_document_line(v_grn, v_wid, 100, 1000, 'stock to sell');
      perform erp.transition_document(v_grn, 'post', 'controls suite');

      v_step := 'delivering: an order of ten at a ten per cent discount is approved and picked';
      v_so1 := erp.open_document('sales_order', v_cust, null, v_site);
      v_so1_l := erp.add_document_line(v_so1, v_wid, 10, 2500, 'Ten widgets at a discount');
      update erp.document_line
         set discount_pct = 10, net_minor = 22500, updated_at = now()
       where tenant_id = r.tenant_id and id = v_so1_l;
      perform erp.transition_document(v_so1, 'submit', 'controls suite');
      perform erp_test.approve_document(v_so1, 'controls suite');
      perform erp.pick_document(v_so1);
      select a.status::text into v_a1_before
        from erp.allocation a
       where a.tenant_id = r.tenant_id and a.document_line_id = v_so1_l
       order by a.created_at desc limit 1;
      select x.committed into v_committed_before
        from erp.available_to_promise(v_wid, v_site, current_date) x;

      v_step := 'delivering: the whole order is delivered and posted in one call';
      v_dn1 := erp.create_delivery_from_order(v_so1, null, 'auto');
      v_dn1_id := (v_dn1 ->> 'document_id')::uuid;
      select string_agg(distinct a.status::text, ',') into v_a1_after
        from erp.allocation a
       where a.tenant_id = r.tenant_id and a.document_line_id = v_so1_l;
      select string_agg(distinct l.status::text, ',') into v_a1_lines
        from erp.allocation_line l
        join erp.allocation a on a.tenant_id = l.tenant_id and a.id = l.allocation_id
       where a.tenant_id = r.tenant_id and a.document_line_id = v_so1_l;
      select x.on_hand, x.committed, x.available into v_on_hand1, v_committed1, v_available1
        from erp.available_to_promise(v_wid, v_site, current_date) x;

      v_step := 'delivering: an order of twenty is approved and picked, and eight of it delivered';
      v_so2 := erp.open_document('sales_order', v_cust, null, v_site);
      v_so2_l := erp.add_document_line(v_so2, v_wid, 20, 2500, 'Twenty widgets');
      perform erp.transition_document(v_so2, 'submit', 'controls suite');
      perform erp_test.approve_document(v_so2, 'controls suite');
      perform erp.pick_document(v_so2);
      v_dn2 := erp.create_delivery_from_order(
        v_so2, jsonb_build_array(jsonb_build_object('line_id', v_so2_l, 'quantity', 8)), 'auto');
      select a.status::text, a.quantity into v_a2_status, v_a2_qty
        from erp.allocation a
       where a.tenant_id = r.tenant_id and a.document_line_id = v_so2_l
       order by a.created_at desc limit 1;
      select coalesce(sum(l.quantity) filter (where l.status = 'committed'), 0),
             coalesce(sum(l.quantity) filter (where l.status = 'consumed'), 0)
        into v_a2_held_lines, v_a2_used_lines
        from erp.allocation_line l
        join erp.allocation a on a.tenant_id = l.tenant_id and a.id = l.allocation_id
       where a.tenant_id = r.tenant_id and a.document_line_id = v_so2_l;
      select x.on_hand, x.committed, x.available into v_on_hand2, v_committed2, v_available2
        from erp.available_to_promise(v_wid, v_site, current_date) x;

      v_step := 'delivering: the second administrator invoices the discounted delivery';
      perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
      v_inv := erp.invoice_from_delivery(v_dn1_id);
      perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
      select count(*), max(l.quantity), max(l.unit_price_minor), max(l.discount_pct), sum(l.net_minor)
        into v_inv_lines, v_inv_qty, v_inv_price, v_inv_disc, v_inv_net
        from erp.document_line l
       where l.tenant_id = r.tenant_id and l.document_id = v_inv and not l.is_cancelled;
    exception when others then
      v_state_deliver := format('at "%s": %s', v_step, left(sqlerrm, 300));
      execute format('set local role %I', v_owner);
    end;

    -- ── Receiving at a site that cannot move the order ─────────────────────
    begin
      v_step := 'receiving: an order for the main site is approved and sent';
      perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
      v_po3 := erp.open_document('purchase_order', v_sup, null, v_site);
      v_pol3 := erp.add_document_line(v_po3, v_rcv, 5, 1000, 'Five for the main site');
      perform erp.transition_document(v_po3, 'submit', 'controls suite');
      perform erp_test.approve_document(v_po3, 'controls suite');
      perform erp.transition_document(v_po3, 'send', 'controls suite');

      v_step := 'receiving: the goods arrive at the east site against it';
      v_grn3 := erp.open_document('goods_receipt', v_sup, null, v_east);
      perform erp.receive_against(v_grn3, v_pol3, 5);

      v_step := 'receiving: the receiver who may receive only at the east site posts the receipt';
      perform set_config('request.jwt.claims', json_build_object('sub', s_rex)::text, true);
      begin
        v_grn3_state := erp.transition_document(v_grn3, 'post', 'controls suite');
      exception when others then
        v_grn3_err := left(sqlerrm, 200);
      end;
      perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
      v_po3_state := erp.object_current_state('document', v_po3);
      select count(*), min(e.payload ->> 'transition'),
             coalesce(bool_and(e.payload ->> 'receipt_id' = v_grn3::text), false)
        into v_events, v_event_move, v_event_receipt
        from erp.event e
       where e.tenant_id = r.tenant_id
         and e.event_type = 'document.progress_not_advanced'
         and e.aggregate_type = 'document'
         and e.aggregate_id = v_po3;
      select coalesce(bool_or(et.is_current), false) into v_event_current
        from erp_ref.event_type et
       where et.code = 'document.progress_not_advanced';
    exception when others then
      v_state_receive := format('at "%s": %s', v_step, left(sqlerrm, 300));
      execute format('set local role %I', v_owner);
    end;

    -- ── Matching ───────────────────────────────────────────────────────────
    begin
      v_step := 'matching: an order of two lines is approved and sent, and the goods arrive';
      perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
      v_po := erp.open_document('purchase_order', v_sup, null, v_site);
      v_pol := erp.add_document_line(v_po, v_mat, 10, 1000, 'Ten to match');
      v_pol2 := erp.add_document_line(v_po, v_mat, 5, 1000, 'Five to match');
      perform erp.transition_document(v_po, 'submit', 'controls suite');
      perform erp_test.approve_document(v_po, 'controls suite');
      perform erp.transition_document(v_po, 'send', 'controls suite');
      v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
      perform erp.receive_against(v_grn, v_pol, 10);
      perform erp.receive_against(v_grn, v_pol2, 5);

      v_step := 'matching: the supplier bills both lines above the agreed price';
      v_inv2 := erp.open_document('purchase_invoice', v_sup, null, v_site);
      perform erp.invoice_against(v_inv2, v_pol, 5, 1200);
      select e.id, e.approval_request_id into v_e0, v_r0
        from erp.match_exception e
       where e.tenant_id = r.tenant_id and e.order_line_id = v_pol
       limit 1;
      perform erp.invoice_against(v_inv2, v_pol, 5, 1200);
      select e.id, e.approval_request_id into v_e1, v_r1
        from erp.match_exception e
       where e.tenant_id = r.tenant_id and e.order_line_id = v_pol and e.id <> v_e0
       limit 1;
      perform erp.invoice_against(v_inv2, v_pol2, 5, 1500);
      select e.id, e.approval_request_id into v_e2, v_r2
        from erp.match_exception e
       where e.tenant_id = r.tenant_id and e.order_line_id = v_pol2
       limit 1;
      select ar.status::text into v_r0_status
        from erp.approval_request ar where ar.tenant_id = r.tenant_id and ar.id = v_r0;

      v_step := 'matching: the matcher accepts while the approval is pending';
      perform set_config('request.jwt.claims', json_build_object('sub', s_mat)::text, true);
      begin
        perform erp.accept_match_exception(v_e1, 'too soon');
      exception when others then
        v_pending_err := left(sqlerrm, 200);
      end;

      v_step := 'matching: the second administrator approves the difference';
      perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
      select t.id into v_task
        from erp.approval_task t
       where t.tenant_id = r.tenant_id and t.approval_request_id = v_r1
         and t.status = 'pending' and t.assignee_user_id = v_second
       limit 1;
      v_r1_decided := erp.decide_approval_task(v_task, true, 'the price rise was agreed')::text;

      v_step := 'matching: the older exception the approval superseded is accepted';
      perform set_config('request.jwt.claims', json_build_object('sub', s_mat)::text, true);
      begin
        perform erp.accept_match_exception(v_e0, null);
      exception when others then
        v_superseded_err := left(sqlerrm, 200);
      end;

      v_step := 'matching: the first administrator, who raised it, accepts it';
      perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
      begin
        perform erp.accept_match_exception(v_e1, 'my own');
      exception when others then
        v_self_err := left(sqlerrm, 200);
      end;

      v_step := 'matching: the matcher, signed in, accepts it through the door';
      select * into g from erp_test.accept_match_exception_as(s_mat, v_e1, 'Price rise agreed with the supplier');
      v_accept := g.outcome;
      v_accept_as := g.ran_as;
      v_accept_err := g.err_message;
      perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
      select e.resolved_at is not null and e.resolved_by = u_mat
             and e.resolution like '%Price rise agreed with the supplier%'
        into v_e1_resolved
        from erp.match_exception e where e.tenant_id = r.tenant_id and e.id = v_e1;
      select e.resolved_at is not null and e.resolved_by = u_mat
        into v_e0_resolved
        from erp.match_exception e where e.tenant_id = r.tenant_id and e.id = v_e0;
      v_workbench := array(select w.exception_id from erp.match_exception_workbench() w);

      v_step := 'matching: the accepted exception is accepted again';
      perform set_config('request.jwt.claims', json_build_object('sub', s_mat)::text, true);
      begin
        perform erp.accept_match_exception(v_e1, null);
      exception when others then
        v_again_err := left(sqlerrm, 200);
      end;

      v_step := 'matching: the onlooker, signed in, asks the door';
      select * into g from erp_test.accept_match_exception_as(s_lou, v_e2, null);
      v_look_state := g.err_state;
      v_look_err := coalesce(g.err_message, g.outcome::text);

      v_step := 'matching: the second administrator refuses the other difference';
      perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
      select t.id into v_task
        from erp.approval_task t
       where t.tenant_id = r.tenant_id and t.approval_request_id = v_r2
         and t.status = 'pending' and t.assignee_user_id = v_second
       limit 1;
      v_r2_decided := erp.decide_approval_task(v_task, false, 'not at that price')::text;
      perform set_config('request.jwt.claims', json_build_object('sub', s_mat)::text, true);
      begin
        perform erp.accept_match_exception(v_e2, null);
      exception when others then
        v_refused_err := left(sqlerrm, 200);
      end;
      perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    exception when others then
      v_state_match := format('at "%s": %s', v_step, left(sqlerrm, 300));
      execute format('set local role %I', v_owner);
    end;

    -- ── Releasing ──────────────────────────────────────────────────────────
    begin
      v_step := 'releasing: four batches of a chilled product arrive in quarantine';
      perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
      insert into erp.batch (tenant_id, item_id, batch_number, status, manufactured_on, expires_on)
      values (r.tenant_id, v_chill, 'ZZ-B1', 'quarantine', current_date, current_date + 60) returning id into v_b1;
      insert into erp.batch (tenant_id, item_id, batch_number, status, manufactured_on, expires_on)
      values (r.tenant_id, v_chill, 'ZZ-B2', 'quarantine', current_date, current_date + 60) returning id into v_b2;
      insert into erp.batch (tenant_id, item_id, batch_number, status, manufactured_on, expires_on)
      values (r.tenant_id, v_chill, 'ZZ-B3', 'quarantine', current_date, current_date + 60) returning id into v_b3;
      insert into erp.batch (tenant_id, item_id, batch_number, status, manufactured_on, expires_on)
      values (r.tenant_id, v_chill, 'ZZ-B4', 'quarantine', current_date, current_date + 60) returning id into v_b4;
      v_grn4 := erp.open_document('goods_receipt', v_sup, null, v_site);
      v_line := erp.add_document_line(v_grn4, v_chill, 10, 1000, 'first batch');
      update erp.document_line set batch_id = v_b1, location_id = v_quar where tenant_id = r.tenant_id and id = v_line;
      v_line := erp.add_document_line(v_grn4, v_chill, 10, 1000, 'second batch');
      update erp.document_line set batch_id = v_b2, location_id = v_quar where tenant_id = r.tenant_id and id = v_line;
      v_line := erp.add_document_line(v_grn4, v_chill, 10, 1000, 'third batch');
      update erp.document_line set batch_id = v_b3, location_id = v_quar where tenant_id = r.tenant_id and id = v_line;
      v_line := erp.add_document_line(v_grn4, v_chill, 10, 1000, 'fourth batch');
      update erp.document_line set batch_id = v_b4, location_id = v_quar where tenant_id = r.tenant_id and id = v_line;
      perform erp.transition_document(v_grn4, 'post', 'controls suite');
      select ins.id into v_i1 from erp.inspection ins where ins.tenant_id = r.tenant_id and ins.batch_id = v_b1 limit 1;
      select ins.id into v_i2 from erp.inspection ins where ins.tenant_id = r.tenant_id and ins.batch_id = v_b2 limit 1;
      select ins.id into v_i3 from erp.inspection ins where ins.tenant_id = r.tenant_id and ins.batch_id = v_b3 limit 1;
      select ins.id into v_i4 from erp.inspection ins where ins.tenant_id = r.tenant_id and ins.batch_id = v_b4 limit 1;

      v_step := 'releasing: the first administrator records and dispositions the four inspections';
      perform erp.record_inspection_result(v_i1, 'temperature', 3);
      perform erp.record_inspection_result(v_i1, 'packaging', null, 'intact');
      perform erp.disposition_inspection(v_i1, 'accept', 'within specification');
      perform erp.record_inspection_result(v_i2, 'temperature', 9);
      perform erp.record_inspection_result(v_i2, 'packaging', null, 'intact');
      perform erp.disposition_inspection(v_i2, 'reject', 'arrived warm');
      perform erp.record_inspection_result(v_i3, 'temperature', 9);
      perform erp.record_inspection_result(v_i3, 'packaging', null, 'intact');
      perform erp.disposition_inspection(v_i3, 'rework', 'chill again and test');
      perform erp.record_inspection_result(v_i4, 'temperature', 2);
      perform erp.record_inspection_result(v_i4, 'packaging', null, 'intact');
      perform erp.disposition_inspection(v_i4, 'accept', 'within specification');

      v_listed := public.erp_inspections(100, v_b1);
      v_listed_all := jsonb_array_length(public.erp_inspections(100));

      v_step := 'releasing: the first administrator releases the batch they accepted';
      begin
        perform erp.release_batch(v_b1, v_site, 'Inspection accepted', 'Controls Admin', v_i1);
      exception when others then
        v_q_self_err := left(sqlerrm, 200);
      end;
      select coalesce(sum(sb.quantity), 0) into v_b1_held
        from erp.stock_balance sb
       where sb.tenant_id = r.tenant_id and sb.batch_id = v_b1 and sb.stock_status = 'quarantine';

      v_step := 'releasing: the second administrator releases the accepted batch, and tries the others';
      perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
      v_rel1 := erp.release_batch(v_b1, v_site, 'Inspection accepted', 'Second Admin', v_i1);
      select coalesce(sum(sb.quantity), 0) into v_b1_available
        from erp.stock_balance sb
       where sb.tenant_id = r.tenant_id and sb.batch_id = v_b1 and sb.stock_status = 'available';
      begin
        perform erp.release_batch(v_b2, v_site, 'Looked fine to me', 'Second Admin', null);
      exception when others then
        v_q_reject_err := left(sqlerrm, 200);
      end;
      begin
        perform erp.release_batch(v_b3, v_site, 'Chilled again', 'Second Admin', v_i3);
      exception when others then
        v_q_failed_err := left(sqlerrm, 200);
      end;
      begin
        perform erp.release_batch(v_b3, v_site, 'Inspection accepted', 'Second Admin', v_i1);
      exception when others then
        v_q_other_err := left(sqlerrm, 200);
      end;
      perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

      v_step := 'releasing: before go-live the person who dispositioned releases';
      perform erp_test.reopen_bootstrap_window(r.tenant_id);
      begin
        v_rel4 := erp.release_batch(v_b4, v_site, 'Inspection accepted', 'Controls Admin', v_i4);
      exception when others then
        v_q_prelive_err := left(sqlerrm, 200);
      end;
      perform erp_test.close_bootstrap_window(r.tenant_id);
      select coalesce(sum(sb.quantity), 0) into v_b4_available
        from erp.stock_balance sb
       where sb.tenant_id = r.tenant_id and sb.batch_id = v_b4 and sb.stock_status = 'available';
    exception when others then
      v_state_quality := format('at "%s": %s', v_step, left(sqlerrm, 300));
      execute format('set local role %I', v_owner);
    end;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_CONTROLS_FINISH_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_CONTROLS_FINISH_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 300));
    end if;
    -- Whatever failed, and wherever, the rest of the suite runs as its owner.
    execute format('set local role %I', v_owner);
  end;

  perform set_config('request.jwt.claims', '', true);

  -- ───────────────────────────────────────────────────────────────────────────
  -- The doors
  -- ───────────────────────────────────────────────────────────────────────────

  case_name := 'the acceptance door is one function that runs as the caller, may write, takes the exception and a note, is on the write register, and a signed-in caller may execute it; the inspections door reads, and takes a batch';
  passed := coalesce(v_an = 1 and not v_adef and v_avol and v_agrant
                     and v_aargs = 'p_exception_id uuid, p_note text'
                     and v_agate = 'erp.accept_match_exception'
                     and v_in = 1 and not v_idef and v_istab and v_igrant
                     and v_iargs = 'p_limit integer, p_batch_id uuid', false);
  detail := format('acceptance door: %s function(s) (%s), definer %s, volatile %s, granted %s, gate %s; inspections door: %s function(s) (%s), definer %s, stable %s, granted %s',
                   v_an, coalesce(v_aargs, 'none'), v_adef, v_avol, v_agrant, coalesce(v_agate, 'none'),
                   v_in, coalesce(v_iargs, 'none'), v_idef, v_istab, v_igrant);
  return next;

  -- ───────────────────────────────────────────────────────────────────────────
  -- Counting
  -- ───────────────────────────────────────────────────────────────────────────

  case_name := 'the base pack''s count programmes name the count_variance chain, and the pack carries that chain for count tasks, asked of warehouse_manager';
  passed := coalesce(v_pack_breaks is null
                     and v_pack_chain ->> 'object_type' = 'count_task'
                     and jsonb_array_length(v_pack_chain -> 'steps') = 1
                     and v_pack_chain -> 'steps' -> 0 ->> 'role' = 'warehouse_manager'
                     and v_pack_chain -> 'steps' -> 0 ->> 'approver_kind' = 'role'
                     and (select count(*) from erp_ref.pack_item pi
                           where pi.pack_code = 'base' and pi.object_kind = 'count_programme'
                             and pi.object_key in ('CYCLE_A', 'CYCLE_C', 'STOCKTAKE')) = 3, false);
  detail := format('programmes not naming the chain: %s; chain: %s',
                   coalesce(v_pack_breaks, 'none'), coalesce(v_pack_chain::text, 'none'));
  return next;

  case_name := 'the pack plans the role, the chain and the stocktake for an organisation, and promoted, the stocktake names the chain and every step asks warehouse_manager';
  passed := coalesce(v_state is null and v_planned = 3 and v_prog_chain = 'count_variance'
                     and v_chain_roles = array['warehouse_manager'], false);
  detail := coalesce(v_state, format('%s item(s) planned; the stocktake names %s; the chain asks %s',
                                     v_planned, coalesce(v_prog_chain, 'nothing'), coalesce(v_chain_roles::text, 'nobody')));
  return next;

  case_name := 'a count outside tolerance waits on its approval, asked of every warehouse manager';
  passed := coalesce(v_state is null and v_state_count is null and v_t1_status = 'pending_approval'
                     and v_t1_tasks = 2 and v_t1_managers = 2, false);
  detail := coalesce(v_state, v_state_count, format('the count %s; %s pending task(s), %s to the warehouse managers',
                                                     v_t1_status, v_t1_tasks, v_t1_managers));
  return next;

  case_name := 'approving the variance approves the count';
  passed := coalesce(v_state is null and v_state_count is null and v_t1_decided = 'approved' and v_t1_after = 'approved', false);
  detail := coalesce(v_state, v_state_count, format('the request %s; the count %s', v_t1_decided, v_t1_after));
  return next;

  case_name := 'in a live organisation the person who counted cannot post the variance, and nothing moves';
  passed := coalesce(v_state is null and v_state_count is null
                     and v_self_post_err like 'CLOVEERP_COUNT_SELF_POSTING%'
                     and v_t1_still = 'approved' and v_moves_before = 0, false);
  detail := coalesce(v_state, v_state_count, format('%s; the count %s; %s adjustment(s)',
                                                     coalesce(v_self_post_err, 'the counter posted it'), v_t1_still, v_moves_before));
  return next;

  case_name := 'somebody else posts it, and the stock is corrected by the variance';
  passed := coalesce(v_state is null and v_state_count is null and v_t1_posted = -5
                     and v_t1_final = 'posted' and v_moves_after = 1, false);
  detail := coalesce(v_state, v_state_count, format('posted %s; the count %s; %s adjustment(s)',
                                                     trim_scale(v_t1_posted), v_t1_final, v_moves_after));
  return next;

  case_name := 'refusing the variance refuses the count, releases its lock, and it is not posted';
  passed := coalesce(v_state is null and v_state_count is null and v_t2_decided = 'rejected'
                     and v_t2_after = 'rejected' and v_t2_locks = 0
                     and v_t2_post_err like 'CLOVEERP_COUNT_NOT_APPROVED%', false);
  detail := coalesce(v_state, v_state_count, format('the request %s; the count %s; %s lock(s) held; posting: %s',
                                                     v_t2_decided, v_t2_after, v_t2_locks, coalesce(v_t2_post_err, 'posted')));
  return next;

  case_name := 'before go-live the person who counted posts their own approved count';
  passed := coalesce(v_state is null and v_state_count is null and v_t3_err is null
                     and v_t3_posted = -1 and v_t3_final = 'posted', false);
  detail := coalesce(v_state, v_state_count, v_t3_err, format('posted %s; the count %s', trim_scale(v_t3_posted), v_t3_final));
  return next;

  -- ───────────────────────────────────────────────────────────────────────────
  -- Delivering
  -- ───────────────────────────────────────────────────────────────────────────

  case_name := 'picking an order commits its stock, and available-to-promise counts the commitment';
  passed := coalesce(v_state is null and v_state_deliver is null and v_a1_before = 'committed'
                     and v_committed_before = 10, false);
  detail := coalesce(v_state, v_state_deliver, format('the allocation %s; %s committed', v_a1_before, trim_scale(v_committed_before)));
  return next;

  case_name := 'posting a delivery of the whole order consumes its allocation, so the goods that left are not also held';
  passed := coalesce(v_state is null and v_state_deliver is null
                     and v_a1_after = 'consumed' and v_a1_lines = 'consumed'
                     and v_on_hand1 = 90 and v_committed1 = 0 and v_available1 = 90, false);
  detail := coalesce(v_state, v_state_deliver, format('allocation %s, lines %s; on hand %s, committed %s, available %s',
                                                       v_a1_after, v_a1_lines, trim_scale(v_on_hand1),
                                                       trim_scale(v_committed1), trim_scale(v_available1)));
  return next;

  case_name := 'a part delivery consumes what it took and leaves the rest committed';
  passed := coalesce(v_state is null and v_state_deliver is null
                     and v_a2_status = 'committed' and v_a2_qty = 12
                     and v_a2_held_lines = 12 and v_a2_used_lines = 8
                     and v_on_hand2 = 82 and v_committed2 = 12 and v_available2 = 70, false);
  detail := coalesce(v_state, v_state_deliver, format('allocation %s for %s, lines holding %s and consumed %s; on hand %s, committed %s, available %s',
                                                       v_a2_status, trim_scale(v_a2_qty), trim_scale(v_a2_held_lines),
                                                       trim_scale(v_a2_used_lines), trim_scale(v_on_hand2),
                                                       trim_scale(v_committed2), trim_scale(v_available2)));
  return next;

  case_name := 'invoicing a delivery bills the line''s discount, net as a sales line is priced';
  passed := coalesce(v_state is null and v_state_deliver is null and v_inv_lines = 1
                     and v_inv_qty = 10 and v_inv_price = 2500 and v_inv_disc = 10 and v_inv_net = 22500, false);
  detail := coalesce(v_state, v_state_deliver, format('%s line(s): %s at %s less %s per cent, net %s',
                                                       v_inv_lines, trim_scale(v_inv_qty), v_inv_price,
                                                       trim_scale(v_inv_disc), v_inv_net));
  return next;

  case_name := 'a receipt whose order cannot move on posts, and records document.progress_not_advanced on the order';
  passed := coalesce(v_state is null and v_state_receive is null and v_grn3_err is null
                     and v_grn3_state = 'posted' and v_po3_state = 'sent'
                     and v_events = 1 and v_event_move = 'receive_all' and v_event_receipt
                     and v_event_current, false);
  detail := coalesce(v_state, v_state_receive, v_grn3_err,
                     format('the receipt %s; the order %s; %s event(s), the move %s, naming the receipt %s; registered %s',
                            v_grn3_state, v_po3_state, v_events, coalesce(v_event_move, 'none'),
                            v_event_receipt, v_event_current));
  return next;

  -- ───────────────────────────────────────────────────────────────────────────
  -- Matching
  -- ───────────────────────────────────────────────────────────────────────────

  case_name := 'a match exception is not accepted while its approval is pending';
  passed := coalesce(v_state is null and v_state_match is null
                     and v_pending_err like 'CLOVEERP_MATCH_EXCEPTION_NOT_APPROVED%'
                     and v_pending_err like '%waiting%', false);
  detail := coalesce(v_state, v_state_match, v_pending_err, 'the pending exception was accepted');
  return next;

  case_name := 'nor is an older exception whose approval a later match on the line asked again';
  passed := coalesce(v_state is null and v_state_match is null and v_r0_status = 'superseded'
                     and v_superseded_err like 'CLOVEERP_MATCH_EXCEPTION_NOT_APPROVED%'
                     and v_superseded_err like '%later match%', false);
  detail := coalesce(v_state, v_state_match, format('the older request %s; %s', v_r0_status,
                                                     coalesce(v_superseded_err, 'the superseded exception was accepted')));
  return next;

  case_name := 'in a live organisation the person who raised the exception cannot accept it once approved';
  passed := coalesce(v_state is null and v_state_match is null and v_r1_decided = 'approved'
                     and v_self_err like 'CLOVEERP_MATCH_EXCEPTION_SELF_ACCEPTANCE%', false);
  detail := coalesce(v_state, v_state_match, format('the request %s; %s', v_r1_decided,
                                                     coalesce(v_self_err, 'the raiser accepted it')));
  return next;

  case_name := 'signed in with procurement.match, somebody else accepts it through the door, the older exception goes with it, and neither holds the workbench';
  passed := coalesce(v_state is null and v_state_match is null and v_accept_err is null
                     and v_accept_as = 'authenticated'
                     and (v_accept ->> 'exception_id')::uuid = v_e1
                     and (v_accept ->> 'also_resolved')::integer = 1
                     and v_e1_resolved and v_e0_resolved
                     and not (v_e1 = any (v_workbench)) and not (v_e0 = any (v_workbench))
                     and v_e2 = any (v_workbench), false);
  detail := coalesce(v_state, v_state_match, v_accept_err,
                     format('ran as %s: %s; resolved %s and %s; on the workbench %s',
                            coalesce(v_accept_as, 'nobody'), coalesce(v_accept::text, 'nothing'),
                            v_e1_resolved, v_e0_resolved, coalesce(v_workbench::text, 'nothing')));
  return next;

  case_name := 'an accepted exception is not accepted again';
  passed := coalesce(v_state is null and v_state_match is null
                     and v_again_err like 'CLOVEERP_MATCH_EXCEPTION_RESOLVED%', false);
  detail := coalesce(v_state, v_state_match, v_again_err, 'it was accepted twice');
  return next;

  case_name := 'signed in without procurement.match, a person is refused, naming procurement.match';
  passed := coalesce(v_state is null and v_state_match is null and v_look_state = '42501'
                     and v_look_err like 'CLOVEERP_PERMISSION_DENIED: procurement.match%', false);
  detail := coalesce(v_state, v_state_match, format('%s: %s', coalesce(v_look_state, 'no refusal'), coalesce(v_look_err, 'no answer')));
  return next;

  case_name := 'an exception whose approval was refused is not accepted';
  passed := coalesce(v_state is null and v_state_match is null and v_r2_decided = 'rejected'
                     and v_refused_err like 'CLOVEERP_MATCH_EXCEPTION_REFUSED%', false);
  detail := coalesce(v_state, v_state_match, format('the request %s; %s', v_r2_decided,
                                                     coalesce(v_refused_err, 'the refused exception was accepted')));
  return next;

  -- ───────────────────────────────────────────────────────────────────────────
  -- Releasing
  -- ───────────────────────────────────────────────────────────────────────────

  case_name := 'the inspections door lists one batch''s inspections when asked for it';
  passed := coalesce(v_state is null and v_state_quality is null
                     and jsonb_array_length(v_listed) = 1
                     and (v_listed -> 0 ->> 'inspection_id')::uuid = v_i1
                     and (v_listed -> 0 ->> 'batch_id')::uuid = v_b1
                     and v_listed_all >= 4, false);
  detail := coalesce(v_state, v_state_quality, format('for the batch: %s; for the organisation: %s',
                                                       coalesce(v_listed::text, 'nothing'), v_listed_all));
  return next;

  case_name := 'in a live organisation the person who dispositioned an inspection cannot release the batch on it';
  passed := coalesce(v_state is null and v_state_quality is null
                     and v_q_self_err like 'CLOVEERP_BATCH_SELF_RELEASE%' and v_b1_held = 10, false);
  detail := coalesce(v_state, v_state_quality, format('%s; %s still in quarantine',
                                                       coalesce(v_q_self_err, 'the dispositioner released it'), trim_scale(v_b1_held)));
  return next;

  case_name := 'somebody else releases it, and the batch becomes available';
  passed := coalesce(v_state is null and v_state_quality is null and v_rel1 is not null and v_b1_available = 10, false);
  detail := coalesce(v_state, v_state_quality, format('release %s; %s available', v_rel1, trim_scale(v_b1_available)));
  return next;

  case_name := 'a batch last dispositioned reject is not released, even with no inspection named';
  passed := coalesce(v_state is null and v_state_quality is null
                     and v_q_reject_err like 'CLOVEERP_BATCH_REJECTED%', false);
  detail := coalesce(v_state, v_state_quality, v_q_reject_err, 'the rejected batch was released');
  return next;

  case_name := 'a batch whose inspection failed and was sent for rework is not released on it';
  passed := coalesce(v_state is null and v_state_quality is null
                     and v_q_failed_err like 'CLOVEERP_BATCH_INSPECTION_FAILED%', false);
  detail := coalesce(v_state, v_state_quality, v_q_failed_err, 'the failed batch was released');
  return next;

  case_name := 'a batch is not released on another batch''s inspection';
  passed := coalesce(v_state is null and v_state_quality is null
                     and v_q_other_err like 'CLOVEERP_INSPECTION_NOT_OF_THIS_BATCH%', false);
  detail := coalesce(v_state, v_state_quality, v_q_other_err, 'the batch was released on another batch''s inspection');
  return next;

  case_name := 'before go-live the person who dispositioned releases the batch';
  passed := coalesce(v_state is null and v_state_quality is null and v_q_prelive_err is null
                     and v_rel4 is not null and v_b4_available = 10, false);
  detail := coalesce(v_state, v_state_quality, v_q_prelive_err, format('release %s; %s available', v_rel4, trim_scale(v_b4_available)));
  return next;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant t where t.code = 'zz-ctl-' || v_hex);
  detail := 'the organisation, its people, counts, orders, deliveries, exceptions and batches rolled back';
  return next;
end;
$$;

comment on function erp_test.controls_finish_suite() is
  'A live organisation with two administrators and five narrow people: a count '
  'variance under the base pack''s stocktake asked of both warehouse managers, '
  'approved and refused with its request, refused to its counter and posted by '
  'the other, and posted by its counter before go-live; a delivery consuming its '
  'allocation whole and in part, and invoiced at its discount; a receipt at a '
  'site that cannot move its order recording why; a match exception refused '
  'while pending, superseded, to its raiser, twice and refused, and accepted '
  'through the door by somebody else; and batch release refused to the '
  'dispositioner, for a rejected, a failed and a wrongly named inspection, '
  'allowed to somebody else and before go-live. Rolls back everything it made.';

create or replace function erp_test.assert_controls_finish_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 29;
  v_total  integer;
  v_failed integer;
  v_detail text;
begin
  select count(*),
         count(*) filter (where not coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n') filter (where not coalesce(s.passed, false))
    into v_total, v_failed, v_detail
    from erp_test.controls_finish_suite() s;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_CONTROLS_FINISH_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_failed > 0 then
    raise exception E'CLOVEERP_CONTROLS_FINISH_SUITE_FAILED: %/% case(s) failed\n%', v_failed, v_total, v_detail
      using hint = 'Read the failed case before the rule: a count, a delivery, a match exception or a batch release was allowed that should be refused, or refused that should be allowed.';
  end if;
  return format('controls finish: %s/%s cases passed', v_total - v_failed, v_total);
end;
$$;

revoke all on function erp_test.controls_finish_suite() from public, anon, authenticated;
revoke all on function erp_test.assert_controls_finish_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. Generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_authorise_codes_exist();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_no_caller_reachable_internals();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_packs_installable();
select erp.assert_guidance_sound();
select erp.assert_session_context_hygiene();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage('de');
select erp.assert_vocabulary_aligned();
select erp.assert_isolation();

select erp_test.assert_controls_finish_suite();
select erp_test.assert_inventory_suite();
select erp_test.assert_quality_logistics_suite();
select erp_test.assert_starter_pack_acceptance();
select erp_test.assert_delivery_from_order_suite();
select erp_test.assert_sales_depth_suite();
select erp_test.assert_configuration_wiring_suite();
select erp_test.assert_approval_hold_suite();
