-- A sales order closes short, and an invoice says its legal number.
--
-- Found in the live walk of 12 October 2026.
--
--   1. A sales order despatched in part had no way to finish except shipping
--      the rest. "Despatch the rest" is made by a delivery, never by hand
--      (20260923800000), and a purchase order's "Close short" (receive_rest)
--      has no sales twin. A customer who will not take the rest left the order
--      open for good: the demonstration held about 59 of them, back to
--      September 2025, at the top of Sales' release sequence.
--   2. An issued invoice showed its document number (INV-000478) and nowhere
--      its legal number (INV-000001), which is the one on the PDF the customer
--      holds. The two come from separate sequences and may share a prefix, so
--      the screens say both (owner's decision, 12 October).
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.close_sales_order_short(order, reason) and its door
--      public.erp_close_sales_order_short: a sales order despatched in part is
--      closed for what went. A reason is required. What is still reserved for
--      it is released. The order moves to despatched by the move its lifecycle
--      declares, the reason on its history; and when every delivery of it is
--      already invoiced it moves on to invoiced, as an invoice would have moved
--      it (erp.advance_orders_for_invoice). Authorises sales.order. Refuses
--      any other order, or state, by name.
--   B. erp.finish_demonstration_sales_orders(day), in a demonstration that is
--      not live: every sales order despatched in part whose last delivery left
--      two weeks or more before the day is closed short, "The customer did not
--      need the rest". erp.tidy_demonstration_books() runs it where it bills,
--      after the goods are put away, and says how many it closed.
--   C. erp.document_legal_number(document): the number an issued invoice was
--      issued under (erp.document_issue, issued or sent). public.erp_documents
--      and public.erp_open_invoices answer it as legal_number.
--   D. The words of the move and of the legal number.
--   E. erp_test.sales_order_closes_short_suite proves A to C.
--
-- On production: two routines answer one more key, three routines are added,
-- and the demonstration tidy is patched; no table is altered and no row of
-- any organisation is changed. Production makes no demonstrations.

-- ─────────────────────────────────────────────────────────────────────────────
-- A. A sales order closes short
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.close_sales_order_short(p_order uuid, p_reason text)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  d          erp.document%rowtype;
  v_base     text;
  v_step     text;
  v_released integer;
  v_open     boolean;
  v_invoiced boolean := false;
begin
  select x.* into d from erp.document x where x.tenant_id = v_tenant and x.id = p_order for update;
  perform erp.authorise('sales.order', d.entity_id, d.site_id, null, 'document', p_order);
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'CLOVEERP_REASON_REQUIRED: closing a sales order short needs a reason'
      using errcode = '23514', hint = 'Say why the rest will not be sent, so the customer and the auditor can read it.';
  end if;

  select dt.base_type_code into v_base
    from erp.document_type dt where dt.tenant_id = v_tenant and dt.id = d.document_type_id;
  v_step := erp.transition_code_to(p_order, 'despatched');
  if d.id is null or d.is_cancelled or v_base is distinct from 'sales_order'
     or erp.object_current_state('document', p_order) is distinct from 'partially_despatched'
     or v_step is null then
    raise exception 'CLOVEERP_SALES_ORDER_CANNOT_CLOSE_SHORT: % cannot be closed short', coalesce(d.document_number, 'the order')
      using errcode = '23514',
            hint = 'Only a sales order despatched in part closes short. One with nothing despatched is cancelled; one despatched in full is invoiced.';
  end if;

  -- What was held back for the rest is free again.
  update erp.allocation
     set status = 'cancelled', updated_at = now()
   where tenant_id = v_tenant and document_id = p_order
     and status in ('reserved', 'committed');
  get diagnostics v_released = row_count;

  perform erp.transition_document(p_order, v_step, 'Closed short: ' || btrim(p_reason));

  -- Every delivery already invoiced by an invoice that is issued: the order
  -- is invoiced, as issuing the last invoice would have made it
  -- (erp.transition_document runs erp.advance_orders_for_invoice when an
  -- invoice is committed).
  select exists (
    select 1
      from erp.related_documents(p_order, 'fulfils') as f(delivery_id)
      join erp.document dn on dn.tenant_id = v_tenant and dn.id = f.delivery_id
      join erp.document_type dnt on dnt.tenant_id = dn.tenant_id and dnt.id = dn.document_type_id
     where dnt.base_type_code = 'delivery'
       and not dn.is_cancelled
       and not exists (
         select 1
           from erp.related_documents(dn.id, 'invoices') as b(invoice_id)
           join erp.document iv on iv.tenant_id = v_tenant and iv.id = b.invoice_id
           join erp.document_type it on it.tenant_id = iv.tenant_id and it.id = iv.document_type_id
           join erp.object_state ios
             on ios.tenant_id = iv.tenant_id and ios.object_type = 'document' and ios.object_id = iv.id
           join erp.state ist on ist.id = ios.current_state_id
          where it.base_type_code = 'invoice_reference'
            and not iv.is_cancelled
            and ist.is_committed))
    into v_open;
  if not coalesce(v_open, true) then
    v_step := erp.transition_code_to(p_order, 'invoiced');
    if v_step is not null then
      begin
        perform erp.transition_document(p_order, v_step, 'Invoiced in full for what was despatched');
        v_invoiced := true;
      exception when others then
        perform erp.append_event(
          'document.progress_not_advanced', 'document', p_order,
          jsonb_build_object('transition', 'invoice', 'reason', sqlerrm, 'closed_short', true));
      end;
    end if;
  end if;

  return jsonb_build_object('order_id', p_order, 'order', d.document_number,
                            'state', erp.object_current_state('document', p_order),
                            'reservations_released', v_released, 'invoiced', v_invoiced);
end;
$$;
revoke all on function erp.close_sales_order_short(uuid, text) from public, anon;
comment on function erp.close_sales_order_short(uuid, text) is
  'Closes a sales order despatched in part for what went (20261012120000): reason required, what is still reserved '
  'for it released, moved to despatched with the reason on its history, and on to invoiced when every delivery of it '
  'is already invoiced. Authorises sales.order. Refuses any other order or state with CLOVEERP_SALES_ORDER_CANNOT_CLOSE_SHORT.';

create or replace function public.erp_close_sales_order_short(p_order uuid, p_reason text)
returns jsonb
language sql
set search_path = ''
as $$ select erp.close_sales_order_short(p_order, p_reason) $$;
revoke all on function public.erp_close_sales_order_short(uuid, text) from public, anon;
grant execute on function public.erp_close_sales_order_short(uuid, text) to authenticated, service_role;
comment on function public.erp_close_sales_order_short(uuid, text) is
  'Closes a sales order despatched in part for what went, with a reason (20261012120000). Authorises sales.order.';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_close_sales_order_short', 'erp.close_sales_order_short',
   'Closes a sales order despatched in part for what went, releases what was reserved for the rest, and moves it to '
   'despatched (and invoiced when every delivery is invoiced); authorises sales.order.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp.register_refusal('CLOVEERP_SALES_ORDER_CANNOT_CLOSE_SHORT',
  'Closing short a sales order that is not despatched in part.',
  'Closing short finishes an order for what went. An order with nothing despatched has nothing to finish for, and one despatched in full is already finished.',
  'Cancel an order nothing has gone against, or invoice one despatched in full. Close short only an order despatched in part.');

-- ─────────────────────────────────────────────────────────────────────────────
-- B. A demonstration's sales orders finish
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.finish_demonstration_sales_orders(p_day date)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  o         record;
  v_short   integer := 0;
  v_refused integer := 0;
  v_note    text;
begin
  if not erp.tenant_is_demonstration(v_tenant)
     or exists (select 1 from erp.environment e
                 where e.tenant_id = v_tenant and e.is_self and e.is_live) then
    return jsonb_build_object('closed_short', 0);
  end if;

  for o in
    select x.* from (
      select d.id, d.document_number,
             (select max(g.document_date)
                from erp.document_relation r
                join erp.document g on g.tenant_id = r.tenant_id and g.id = r.from_document_id
                join erp.document_type gt on gt.tenant_id = g.tenant_id and gt.id = g.document_type_id
               where r.tenant_id = d.tenant_id and r.to_document_id = d.id
                 and r.relation_kind = 'fulfils' and gt.base_type_code = 'delivery'
                 and not g.is_cancelled) as last_left
        from erp.document d
        join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
       where d.tenant_id = v_tenant
         and dt.base_type_code = 'sales_order'
         and not d.is_cancelled
         and erp.object_current_state('document', d.id) = 'partially_despatched') x
     where x.last_left <= p_day - 14
     order by x.last_left, x.document_number
  loop
    begin
      perform erp.close_sales_order_short(o.id, 'The customer did not need the rest');
      v_short := v_short + 1;
    exception when others then
      v_refused := v_refused + 1;
      v_note := coalesce(v_note, format('%s was not closed short: %s', o.document_number, left(sqlerrm, 160)));
    end;
  end loop;

  return jsonb_build_object('closed_short', v_short, 'refused', v_refused, 'note', v_note);
end;
$$;
revoke all on function erp.finish_demonstration_sales_orders(date) from public, anon, authenticated;
comment on function erp.finish_demonstration_sales_orders(date) is
  'In a demonstration that is not live (20261012120000): every sales order despatched in part whose last delivery '
  'left two weeks or more before the day is closed short, "The customer did not need the rest". Run by '
  'erp.tidy_demonstration_books() where it bills.';

do $tidy_demonstration_books$
declare
  v_sig  constant text := 'erp.tidy_demonstration_books(date, boolean)';
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o$  v_put       jsonb;
$o$;
  v_new1 constant text := $n$  v_put       jsonb;
  v_sold      jsonb;
$n$;
  v_old2 constant text := $o$  -- ── The customers who pay ─────────────────────────────────────────────────
$o$;
  v_new2 constant text := $n$  -- ── The sales orders that finish (20261012120000) ────────────────────────
  -- A part despatched long ago whose customer never took the rest is closed
  -- short, where this tidy bills.
  if p_bill then
    v_sold := erp.finish_demonstration_sales_orders(p_day);
    v_note := coalesce(v_note, v_sold ->> 'note');
  end if;

  -- ── The customers who pay ─────────────────────────────────────────────────
$n$;
  v_old3 constant text := $o$    'pallets_put_away', coalesce((v_put ->> 'put_away')::integer, 0),
$o$;
  v_new3 constant text := $n$    'pallets_put_away', coalesce((v_put ->> 'put_away')::integer, 0),
    'sales_orders_closed_short', coalesce((v_sold ->> 'closed_short')::integer, 0),
$n$;
  v_olds text[] := array[v_old1, v_old2, v_old3];
  v_news text[] := array[v_new1, v_new2, v_new3];
  i integer;
  n integer;
begin
  if position('erp.finish_demonstration_sales_orders(' in v_def) > 0 then
    raise notice '% already finishes the sales orders; left as it is', v_sig;
    return;
  end if;
  for i in 1 .. 3 loop
    n := (length(v_def) - length(replace(v_def, v_olds[i], ''))) / length(v_olds[i]);
    if n <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, i, n;
    end if;
  end loop;
  for i in 1 .. 3 loop
    v_def := replace(v_def, v_olds[i], v_news[i]);
  end loop;
  execute v_def;
end
$tidy_demonstration_books$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. An invoice says its legal number
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.document_legal_number(p_document_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  -- The number a document was issued under, as its PDF carries it: the
  -- latest issue of it that was issued or sent. Nothing for a draft, or a
  -- document never issued.
  select di.issued_number
    from erp.document_issue di
   where di.tenant_id = erp.current_tenant_id()
     and di.source_document_id = p_document_id
     and di.status in ('issued', 'sent')
   order by di.issued_at desc nulls last, di.sequence_number desc
   limit 1
$$;
revoke all on function erp.document_legal_number(uuid) from public, anon;
comment on function erp.document_legal_number(uuid) is
  'The legal number a document was issued under (erp.document_issue, issued or sent), or nothing (20261012120000).';

create or replace function public.erp_documents(
  p_type_code         text    default null,
  p_limit             integer default 100,
  p_exclude_cancelled boolean default false,
  p_actionable        boolean default false,
  p_transition_code   text    default null,
  p_states            text[]  default null,
  p_awaiting          text    default null
)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by x->>'document_number' desc), '[]'::jsonb) from (
    select jsonb_build_object(
      'document_id', d.id, 'document_number', d.document_number,
      'document_type', dt.code, 'document_date', d.document_date,
      'required_date', d.required_date, 'currency', d.currency,
      'party', p.name, 'total_minor', erp.document_value_minor(d.id),
      'state', s.code, 'state_name', s.name, 'is_committed', s.is_committed,
      'is_cancelled', d.is_cancelled,
      -- What a finished delivery or receipt still waits for from another
      -- document (erp.document_awaiting); nothing for anything else.
      'awaiting', case when coalesce(s.is_terminal, false)
                         and dt.base_type_code in ('delivery', 'receipt')
                       then erp.document_awaiting(d.id) end,
      -- The number an issued invoice carries on its PDF (20261012120000).
      'legal_number', case when dt.base_type_code = 'invoice_reference'
                           then erp.document_legal_number(d.id) end) as x
      from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
      left join erp.party p on p.tenant_id = d.tenant_id and p.id = d.party_id
      left join erp.object_state os
        on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
      left join erp.state s on s.id = os.current_state_id
     where d.tenant_id = erp.current_tenant_id()
       and (p_type_code is null or dt.code = p_type_code)
       -- Narrowed in any way at all: never a cancelled document, whether the
       -- document says so or its lifecycle does.
       and (not (coalesce(p_exclude_cancelled, false) or coalesce(p_actionable, false)
                 or p_transition_code is not null or p_states is not null or p_awaiting is not null)
            or not (d.is_cancelled or coalesce(s.code = 'cancelled', false)))
       -- Offered for acting, or asked for a move: not finished either.
       and (not (coalesce(p_actionable, false) or p_transition_code is not null)
            or not coalesce(s.is_terminal, false))
       -- Asked for a move: the pinned version declares it out of this state.
       and (p_transition_code is null
            or exists (
              select 1
                from erp.transition tr
               where tr.tenant_id = os.tenant_id
                 and tr.state_machine_version_id = os.state_machine_version_id
                 and tr.code = p_transition_code
                 and tr.from_state_id = os.current_state_id))
       -- Asked for states: the current state is one of them. A document with
       -- no lifecycle is in none.
       and (p_states is null or coalesce(s.code = any (p_states), false))
       -- Asked what it awaits: a finished document only while it still waits
       -- for that from another document.
       and (p_awaiting is null
            or not coalesce(s.is_terminal, false)
            or erp.document_awaiting(d.id) is not distinct from p_awaiting)
     order by d.document_number desc
     limit greatest(p_limit, 1)) t
$$;

create or replace function public.erp_open_invoices(p_party_id uuid, p_currency character default 'GBP')
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- Each invoice the customer still owes in the currency, once, oldest first:
  -- the order Apply cash pays in when nothing is chosen (20261010021000). An
  -- invoice with no due date fell due when it was posted, as the ageing says.
  -- With the legal number it was issued under (20261012120000).
  select coalesce(jsonb_agg(jsonb_build_object(
           'document_id', o.document_id, 'document_number', o.document_number,
           'legal_number', erp.document_legal_number(o.document_id),
           'owing_minor', o.owing_minor, 'due_date', o.due_date, 'currency', o.currency)
           order by o.due_date, o.first_item), '[]'::jsonb)
    from (select si.document_id, d.document_number, si.currency,
                 sum(si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0))::bigint as owing_minor,
                 min(coalesce(si.due_date, si.posting_date)) as due_date,
                 min(si.id::text) as first_item
            from erp.subledger_item si
            join erp.document d on d.tenant_id = si.tenant_id and d.id = si.document_id
           where si.tenant_id = erp.current_tenant_id()
             and si.party_id = p_party_id and si.control_kind = 'receivable'
             and si.currency = p_currency
             and si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0) > 0
           group by si.document_id, d.document_number, si.currency) o
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The words
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Closing a sales order short, and an invoice''s legal number (20261012120000).'
  from (values
    ('Close the rest short'),
    ('Close the rest of this order short'),
    ('The customer will not take the rest. The order is finished for what went, and anything held back for the rest is released.'),
    ('Why the rest will not be sent'),
    ('The customer no longer needs the rest'),
    ('Kept on the order''s history with the move.'),
    ('Close it short'),
    ('{number} (legal no. {legal})'),
    ('Legal no. {legal}')) v(text)
on conflict do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- E. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.sales_order_closes_short_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 7;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_tenant uuid;
  v_ent    uuid; v_site uuid; i_fg uuid; p_cus uuid; p_sup uuid; v_uom uuid; v_po uuid;
  v_so     uuid; v_so2 uuid; v_so3 uuid; v_line uuid; v_line3 uuid;
  v_dn     uuid; v_dn3 uuid; v_alloc uuid; v_inv uuid; v_inv3 uuid;
  x        jsonb;
  v_msg    text;
  v_ok     boolean;
  v_res    jsonb;
  v_list   jsonb;
  v_fin    jsonb;
begin
  begin
    -- ── The fixture: a demonstration that sells ─────────────────────────────
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzcss' || v_tag, 'Close Short Suite',
      'admin@demo-zzcss' || v_tag || '.test', 'Close Short Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzcss' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    v_tenant := rb.tenant_id;
    select e.id into v_ent from erp.entity e
     where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = v_tenant and s.entity_id = v_ent and s.status = 'active'
     order by (s.site_type = 'warehouse') desc, s.code limit 1;
    select i.id, i.stock_uom_id into i_fg, v_uom from erp.item i where i.tenant_id = v_tenant and i.code = 'FG-1000';
    select pt.id into p_cus from erp.party pt where pt.tenant_id = v_tenant and pt.code = 'C-HARBOUR';
    select pt.id into p_sup from erp.party pt where pt.tenant_id = v_tenant and pt.code = 'S-FAST';

    v_step := 'stock to sell, received on an order';
    v_po := erp.open_document('purchase_order', p_sup, v_ent, v_site);
    perform erp.add_document_line(v_po, i_fg, 20, 4000, 'stock to sell');
    perform erp.transition_document(v_po, 'submit', null);
    perform erp_test.approve_document(v_po, 'fixture');
    perform erp.transition_document(v_po, 'send', null);
    perform erp.create_receipt_from_order(v_po, null, 'post');

    v_step := 'an order of four, two of them delivered';
    v_so := erp.open_document('sales_order', p_cus, v_ent, v_site, 'CUST-PO-91');
    perform erp.add_document_line(v_so, i_fg, 4, 4950, 'sensor');
    perform erp.transition_document(v_so, 'submit', null);
    if erp.document_state_code(v_so) = 'pending_approval' then
      perform erp_test.approve_document(v_so, 'fixture');
    end if;
    begin
      perform erp.release_credit_hold(v_so, 'released for the fixture');
    exception when others then
      null;
    end;
    select l.id into v_line from erp.document_line l where l.tenant_id = v_tenant and l.document_id = v_so;
    x := erp.create_delivery_from_order(v_so, jsonb_build_array(jsonb_build_object('line_id', v_line, 'quantity', 2)), 'post');
    v_dn := (x ->> 'document_id')::uuid;
    insert into erp.allocation (tenant_id, entity_id, site_id, item_id, document_id, document_line_id,
                                demand_kind, quantity, uom_id, status)
    values (v_tenant, v_ent, v_site, i_fg, v_so, v_line, 'sales_order', 2, v_uom, 'reserved')
    returning id into v_alloc;

    v_step := 'an order confirmed with nothing delivered';
    v_so2 := erp.open_document('sales_order', p_cus, v_ent, v_site, 'CUST-PO-92');
    perform erp.add_document_line(v_so2, i_fg, 1, 4950, 'sensor');
    perform erp.transition_document(v_so2, 'submit', null);
    if erp.document_state_code(v_so2) = 'pending_approval' then
      perform erp_test.approve_document(v_so2, 'fixture');
    end if;

    -- ── 1. A reason is required ─────────────────────────────────────────────
    v_step := 'closing short without a reason';
    begin
      perform public.erp_close_sales_order_short(v_so, '  ');
      v_ok := false; v_msg := 'closed with no reason';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_REASON_REQUIRED%'; v_msg := left(sqlerrm, 120);
    end;
    v_cases := v_cases + 1;
    case_name := 'closing a sales order short needs a reason';
    passed := v_state is null and v_ok and erp.object_current_state('document', v_so) = 'partially_despatched';
    detail := coalesce(v_state, v_msg);
    return next;

    -- ── 2. Only an order despatched in part ─────────────────────────────────
    v_step := 'closing short an order with nothing despatched';
    begin
      perform public.erp_close_sales_order_short(v_so2, 'nothing went');
      v_ok := false; v_msg := 'an order with nothing despatched was closed short';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_SALES_ORDER_CANNOT_CLOSE_SHORT%'; v_msg := left(sqlerrm, 120);
    end;
    v_cases := v_cases + 1;
    case_name := 'an order with nothing despatched is not closed short, it is cancelled';
    passed := v_state is null and v_ok;
    detail := coalesce(v_state, v_msg);
    return next;

    -- ── 3. Closed short: despatched, the reservation released ───────────────
    v_step := 'closing short the order despatched in part';
    v_res := public.erp_close_sales_order_short(v_so, 'The customer no longer needs the rest');
    v_cases := v_cases + 1;
    case_name := 'closed short, the order is despatched for what went and what was reserved for the rest is released';
    passed := v_state is null
          and erp.object_current_state('document', v_so) = 'despatched'
          and (select a.status from erp.allocation a where a.tenant_id = v_tenant and a.id = v_alloc) = 'cancelled'
          and (v_res ->> 'reservations_released')::integer >= 1
          and not (v_res ->> 'invoiced')::boolean;
    detail := coalesce(v_state, v_res::text);
    return next;

    -- ── 4. Nothing more to send ─────────────────────────────────────────────
    v_step := 'reading what is left to release and deliver';
    v_list := public.erp_release_sequence(p_site_id => null, p_limit => 1000);
    begin
      perform erp.create_delivery_from_order(v_so, null, null);
      v_ok := false; v_msg := 'a delivery was made from an order closed short';
    exception when others then
      v_ok := true; v_msg := left(sqlerrm, 100);
    end;
    v_cases := v_cases + 1;
    case_name := 'an order closed short has nothing left to release or deliver';
    passed := v_state is null and v_ok
          and not exists (select 1 from jsonb_array_elements(v_list) r where r ->> 'order_id' = v_so::text);
    detail := coalesce(v_state, v_msg);
    return next;

    -- ── 5. Its delivery invoiced, it is invoiced ────────────────────────────
    v_step := 'invoicing the delivery of the order closed short';
    v_inv := erp.invoice_from_delivery(v_dn, true, 'one person despatches and invoices in the suite');
    v_msg := erp.object_current_state('document', v_so);
    perform erp.transition_document(v_inv, erp.transition_code_to(v_inv, 'issued'), 'fixture');
    v_cases := v_cases + 1;
    case_name := 'once what went is invoiced and issued, the order closed short is invoiced, and not before';
    passed := v_state is null and v_msg = 'despatched' and erp.object_current_state('document', v_so) = 'invoiced';
    detail := coalesce(v_state, format('drafted: %s; issued: %s', v_msg, erp.object_current_state('document', v_so)));
    return next;

    -- ── 6. Already invoiced when closed, it goes straight to invoiced ───────
    v_step := 'an order part delivered and invoiced, then closed short';
    v_so3 := erp.open_document('sales_order', p_cus, v_ent, v_site, 'CUST-PO-93');
    perform erp.add_document_line(v_so3, i_fg, 3, 4950, 'sensor');
    perform erp.transition_document(v_so3, 'submit', null);
    if erp.document_state_code(v_so3) = 'pending_approval' then
      perform erp_test.approve_document(v_so3, 'fixture');
    end if;
    begin
      perform erp.release_credit_hold(v_so3, 'released for the fixture');
    exception when others then
      null;
    end;
    select l.id into v_line3 from erp.document_line l where l.tenant_id = v_tenant and l.document_id = v_so3;
    x := erp.create_delivery_from_order(v_so3, jsonb_build_array(jsonb_build_object('line_id', v_line3, 'quantity', 1)), 'post');
    v_dn3 := (x ->> 'document_id')::uuid;
    v_inv3 := erp.invoice_from_delivery(v_dn3, true, 'one person despatches and invoices in the suite');
    perform erp.transition_document(v_inv3, erp.transition_code_to(v_inv3, 'issued'), 'fixture');
    -- Its delivery left a month ago, so the demonstration's tidy finishes it.
    update erp.document set document_date = current_date - 30 where tenant_id = v_tenant and id = v_dn3;
    v_fin := erp.finish_demonstration_sales_orders(current_date);
    v_cases := v_cases + 1;
    case_name := 'the demonstration''s tidy closes short an order whose last delivery left weeks ago, and invoiced it goes on to invoiced';
    passed := v_state is null
          and (v_fin ->> 'closed_short')::integer = 1
          and erp.object_current_state('document', v_so3) = 'invoiced';
    detail := coalesce(v_state, format('%s; order %s', v_fin::text, erp.object_current_state('document', v_so3)));
    return next;

    -- ── 7. The legal number ─────────────────────────────────────────────────
    v_step := 'reading an invoice''s legal number';
    v_cases := v_cases + 1;
    case_name := 'an invoice never issued has no legal number, and the lists answer the key';
    v_list := public.erp_documents(p_type_code => 'sales_invoice', p_limit => 50);
    passed := v_state is null
          and jsonb_array_length(v_list) >= 2
          and not exists (select 1 from jsonb_array_elements(v_list) r where not (r ? 'legal_number'))
          and not exists (select 1 from jsonb_array_elements(v_list) r where r -> 'legal_number' <> 'null'::jsonb)
          and coalesce((select bool_and(r ? 'legal_number')
                          from jsonb_array_elements(public.erp_open_invoices(p_cus, 'GBP')) r), true);
    detail := coalesce(v_state, format('%s invoice(s) listed', jsonb_array_length(v_list)));
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
    raise exception 'CLOVEERP_SALES_ORDER_CLOSES_SHORT_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;
revoke all on function erp_test.sales_order_closes_short_suite() from public, anon, authenticated;

create or replace function erp_test.assert_sales_order_closes_short_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 7;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _sales_order_closes_short on commit drop as
    select * from erp_test.sales_order_closes_short_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _sales_order_closes_short;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_SALES_ORDER_CLOSES_SHORT_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_SALES_ORDER_CLOSES_SHORT_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('sales order closes short: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_sales_order_closes_short_suite() from public, anon, authenticated;

-- The generators, which are idempotent and run at the end of every migration.

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_public_api_safe();
select erp.assert_invoker_doors_executable();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_no_public_execute();
select erp.assert_isolation();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
