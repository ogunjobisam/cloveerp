set lock_timeout = '30s';

-- =============================================================================
-- 20261006080000  A credit position can be worked out for many customers at once
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-24). The Finance
-- "Needs chasing" tile, the dunning worklist and the Sales "Customers overdue"
-- tile all read public.erp_dunning_worklist(), and it was cancelled at the
-- signed-in limit on every load.
--
-- The worklist asks erp.credit_position() for every overdue customer, and a
-- credit position adds up erp.sales_order_uninvoiced_minor() for every open
-- sales order the customer has. That is one statement per order: the order's
-- value (erp.document_value_minor, with its own organisation lookup), the
-- invoices raised for its deliveries (erp.sales_order_invoices, two
-- erp.related_documents calls, each with its own lookup) and the value of each
-- of those invoices. Measured on live: about 70 ms an order, 1.6 s a customer.
-- The same loop over orders sits inside the approval of every sales document
-- (erp.document_transition_context).
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
-- Nothing is switched over here. This migration only adds the new reads and
-- the proof that they give the same figures.
--
--   A. erp.sales_orders_uninvoiced(order ids): what many orders have on order
--      and not yet invoiced, in one statement. The rule is today's, word for
--      word: the order's value less the value of the issued (committed, not
--      cancelled) invoices raised for its deliveries that are not cancelled,
--      never below nought.
--   B. erp.credit_positions(party ids): the credit position of many customers
--      in one statement (no ids: every customer). The terms in force, the
--      credit policy of the terms' company, the exposure and the verdict and
--      its reason are today's, word for word. One thing is decided where
--      today's body left it to chance: a customer with terms at two companies
--      starting the same day had one of them picked at random ("limit 1");
--      now the one created first by id wins.
--   C. erp_test.sales_order_uninvoiced_reference and
--      erp_test.credit_position_reference: today's bodies, word for word,
--      kept as the answer the new reads must give. They read only
--      erp.document_value_minor and erp.sales_order_invoices, which nothing
--      here changes, so they stay a true answer after the switch.
--   D. erp_test.credit_positions_fixture: a demonstration with a month of
--      trading and, on top of it, orders part delivered and part invoiced, a
--      draft and a cancelled invoice, an order invoiced beyond its value, a
--      credit note, cash received, terms at two companies with different
--      credit policies, a limit exceeded, debt overdue, two customers blocked,
--      terms that have ended and a second organisation.
--   E. erp_test.credit_positions_suite: on that fixture the new reads give the
--      same figures as today's for every customer and every document, and
--      each rule is shown on a stated figure.
--
-- On production: functions are added. No table is altered and no row is
-- changed; nothing that runs today calls the new reads yet.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. What many orders have not yet invoiced, in one statement
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.sales_orders_uninvoiced(p_order_ids uuid[])
returns table(order_id uuid, uninvoiced_minor bigint)
language sql
stable
set search_path = ''
as $function$
  -- The organisation is read once (20261006080000). An empty list asks for
  -- nothing, so it needs no organisation; any order asked about does, as
  -- erp.sales_order_uninvoiced_minor() always did.
  with t as materialized (
    select case when coalesce(cardinality(p_order_ids), 0) > 0 then erp.require_tenant_id() end as id
  ),
  o as materialized (
    select d.id
      from erp.document d
     where d.tenant_id = (select t.id from t)
       and d.id = any(p_order_ids)
  ),
  -- The order's value: its lines not cancelled (erp.document_value_minor).
  ov as (
    select l.document_id, sum(l.net_minor) as v
      from erp.document_line l
     where l.tenant_id = (select t.id from t)
       and l.document_id in (select o.id from o)
       and not l.is_cancelled
     group by l.document_id
  ),
  -- The deliveries that fulfil it, the relation read from either end as
  -- erp.related_documents() reads it, each end by its own index.
  rel_dn as (
    select o.id as order_id, r.to_document_id as delivery_id
      from o
      join erp.document_relation r on r.tenant_id = (select t.id from t) and r.from_document_id = o.id
     where r.relation_kind = 'fulfils' and r.to_document_id is not null
    union
    select o.id, r.from_document_id
      from o
      join erp.document_relation r on r.tenant_id = (select t.id from t) and r.to_document_id = o.id
     where r.relation_kind = 'fulfils' and r.from_document_id is not null
  ),
  dn as materialized (
    select rd.order_id, rd.delivery_id
      from rel_dn rd
      join erp.document x on x.tenant_id = (select t.id from t) and x.id = rd.delivery_id
      join erp.document_type xt on xt.tenant_id = x.tenant_id and xt.id = x.document_type_id
     where xt.base_type_code = 'delivery' and not x.is_cancelled
  ),
  -- The invoices raised for those deliveries (erp.sales_order_invoices):
  -- issued or on, not cancelled, each counted once for the order.
  rel_iv as (
    select dn.order_id, r.to_document_id as invoice_id
      from dn
      join erp.document_relation r on r.tenant_id = (select t.id from t) and r.from_document_id = dn.delivery_id
     where r.relation_kind = 'invoices' and r.to_document_id is not null
    union
    select dn.order_id, r.from_document_id
      from dn
      join erp.document_relation r on r.tenant_id = (select t.id from t) and r.to_document_id = dn.delivery_id
     where r.relation_kind = 'invoices' and r.from_document_id is not null
  ),
  iv as materialized (
    select distinct ri.order_id, ri.invoice_id
      from rel_iv ri
      join erp.document x on x.tenant_id = (select t.id from t) and x.id = ri.invoice_id
      join erp.document_type xt on xt.tenant_id = x.tenant_id and xt.id = x.document_type_id
      join erp.object_state os on os.tenant_id = x.tenant_id and os.object_type = 'document' and os.object_id = x.id
      join erp.state s on s.id = os.current_state_id
     where xt.base_type_code = 'invoice_reference' and not x.is_cancelled and s.is_committed
  ),
  ivv as (
    select l.document_id, sum(l.net_minor) as v
      from erp.document_line l
     where l.tenant_id = (select t.id from t)
       and l.document_id in (select iv.invoice_id from iv)
       and not l.is_cancelled
     group by l.document_id
  ),
  billed as (
    select iv.order_id, sum(coalesce(ivv.v, 0)) as v
      from iv
      left join ivv on ivv.document_id = iv.invoice_id
     group by iv.order_id
  )
  -- The order's value less the value of the invoices it has raised, never
  -- below nought: what the customer has on order and does not yet owe.
  select o.id, greatest(0, coalesce(ov.v, 0) - coalesce(b.v, 0))::bigint
    from o
    left join ov on ov.document_id = o.id
    left join billed b on b.order_id = o.id
$function$;

revoke all on function erp.sales_orders_uninvoiced(uuid[]) from public, anon;

comment on function erp.sales_orders_uninvoiced(uuid[]) is
  'What each of many orders has on order and not yet invoiced, in one statement (20261006080000, J-24): the '
  'order''s value less the value of the issued invoices raised for its deliveries, never below nought. One row per '
  'id that is a document of the organisation. The rule of erp.sales_order_uninvoiced_minor(), read for many orders '
  'at once.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The credit position of many customers, in one statement
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.credit_positions(p_party_ids uuid[])
returns table(party_id uuid, credit_limit_minor bigint, exposure_minor bigint, headroom_minor bigint,
              credit_status text, is_blocked boolean, on_hold boolean, reason text)
language sql
stable
set search_path = ''
as $function$
  with t as materialized (select erp.current_tenant_id() as id),
  -- The customer's terms in force today, the latest to start. Two starting
  -- the same day at two companies are told apart by id (20261006080000);
  -- today's single read took whichever it met first.
  terms as materialized (
    select distinct on (pr.party_id)
           pr.party_id, tt.credit_limit_minor, tt.credit_status, tt.is_blocked, tt.block_reason, tt.entity_id
      from erp.party_role_terms tt
      join erp.party_role pr on pr.tenant_id = tt.tenant_id and pr.id = tt.party_role_id
     where tt.tenant_id = (select t.id from t)
       and pr.role_kind = 'customer'
       and (p_party_ids is null or pr.party_id = any(p_party_ids))
       and tt.valid_from <= current_date
       and (tt.valid_to is null or tt.valid_to > current_date)
     order by pr.party_id, tt.valid_from desc, tt.id
  ),
  -- sales.credit_control, at the terms' company, read once per company.
  pol as materialized (
    select e.entity_id,
           coalesce(erp.config_value('sales.credit_control', null, null, e.entity_id, null), '{}'::jsonb) as v
      from (select distinct tm.entity_id from terms tm) e
  ),
  -- The customers' sales orders committed, not finished and not cancelled.
  orders as materialized (
    select d.id, d.party_id
      from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
      join erp.object_state os on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
      join erp.state s on s.id = os.current_state_id
     where d.tenant_id = (select t.id from t)
       and d.party_id in (select tm.party_id from terms tm)
       and dt.base_type_code = 'sales_order'
       and s.is_committed and not s.is_terminal
       and not d.is_cancelled
  ),
  -- Committed and not yet settled: orders in flight plus receivables
  -- outstanding. An order counts what it has not yet invoiced
  -- (20260923900000), all the orders read in one statement.
  on_order as (
    select od.party_id, sum(u.uninvoiced_minor) as amt
      from erp.sales_orders_uninvoiced(array(select od2.id from orders od2)) u
      join orders od on od.id = u.order_id
     group by od.party_id
  ),
  -- What is owed, and whether any item still owing is due further back than
  -- the policy's overdue window.
  owed as (
    select tm.party_id,
           sum(si.debit_minor - si.credit_minor) as amt,
           coalesce(bool_or(si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0) > 0
                            and si.due_date is not null
                            and si.due_date < current_date - coalesce((p.v ->> 'overdue_days_block')::integer, 30)),
                    false) as any_overdue
      from terms tm
      join pol p on p.entity_id is not distinct from tm.entity_id
      left join erp.subledger_item si
        on si.tenant_id = (select t.id from t) and si.party_id = tm.party_id and si.control_kind = 'receivable'
     group by tm.party_id
  ),
  verdict as (
    select tm.party_id, tm.credit_limit_minor, tm.credit_status, tm.is_blocked, tm.block_reason,
           coalesce(oo.amt, 0) + coalesce(ow.amt, 0) as amt,
           coalesce(tm.is_blocked, false) as blocked,
           -- The limit, widened by the tolerance the policy allows.
           (tm.credit_limit_minor is not null
              and coalesce((p.v ->> 'block_at_limit')::boolean, true)
              and coalesce(oo.amt, 0) + coalesce(ow.amt, 0)
                  > round(tm.credit_limit_minor * (1 + coalesce((p.v ->> 'tolerance_pct')::numeric, 0) / 100))) as over_limit,
           ow.any_overdue as overdue
      from terms tm
      join pol p on p.entity_id is not distinct from tm.entity_id
      join owed ow on ow.party_id = tm.party_id
      left join on_order oo on oo.party_id = tm.party_id
  )
  select v.party_id, v.credit_limit_minor, v.amt::bigint, (v.credit_limit_minor - v.amt)::bigint,
         v.credit_status, v.is_blocked,
         v.blocked or v.over_limit or v.overdue,
         -- Overdue debt is named ahead of the limit (20260923900000).
         case when v.blocked then coalesce(v.block_reason, 'blocked')
              when v.overdue then 'debt is overdue beyond the policy''s window'
              when v.over_limit then 'exposure exceeds the credit limit'
              else 'within terms' end
    from verdict v
$function$;

revoke all on function erp.credit_positions(uuid[]) from public, anon;

comment on function erp.credit_positions(uuid[]) is
  'The credit position of many customers in one statement (20261006080000, J-24); no ids means every customer. '
  'One row per customer with terms in force: the limit, what is on order and not invoiced plus what is owed, the '
  'headroom, and whether supply stops and why, as erp.credit_position() reads one customer. Terms at two companies '
  'starting the same day are told apart by id.';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. Today's bodies, kept as the answer
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.sales_order_uninvoiced_reference(p_order_id uuid)
returns bigint
language sql
stable
set search_path = ''
as $reference$
  -- The order's value less the value of the invoices it has raised, never
  -- below nought: what the customer has on order and does not yet owe.
  select greatest(0, erp.document_value_minor(p_order_id)
                     - coalesce((select sum(erp.document_value_minor(i.invoice_id))
                                   from erp.sales_order_invoices(p_order_id) i), 0))::bigint
$reference$;

revoke all on function erp_test.sales_order_uninvoiced_reference(uuid) from public, anon;

comment on function erp_test.sales_order_uninvoiced_reference(uuid) is
  'erp.sales_order_uninvoiced_minor() as it was before 20261006080000, word for word: the figure the set-based read '
  'must still give (J-24). Read only by erp_test.credit_positions_suite.';

create or replace function erp_test.credit_position_reference(p_party_id uuid)
returns table(credit_limit_minor bigint, exposure_minor bigint, headroom_minor bigint, credit_status text,
              is_blocked boolean, on_hold boolean, reason text)
language sql
stable
set search_path = ''
as $reference$
  with terms as (
    select t.credit_limit_minor, t.credit_status, t.is_blocked, t.block_reason, t.entity_id
      from erp.party_role_terms t
      join erp.party_role pr on pr.id = t.party_role_id
     where t.tenant_id = erp.current_tenant_id()
       and pr.party_id = p_party_id and pr.role_kind = 'customer'
       and t.valid_from <= current_date
       and (t.valid_to is null or t.valid_to > current_date)
     order by t.valid_from desc limit 1
  ),
  -- sales.credit_control, at the terms' company.
  pol as (
    select coalesce(erp.config_value('sales.credit_control', null, null, (select t.entity_id from terms t), null), '{}'::jsonb) as v
  ),
  exposure as (
    -- Committed and not yet settled: orders in flight plus receivables
    -- outstanding. Counting only one of them understates by whichever half is
    -- currently larger; counting an invoiced order in both overstated it by
    -- what it had invoiced, so an order counts what it has not yet invoiced
    -- (20260923900000).
    select coalesce((select sum(erp_test.sales_order_uninvoiced_reference(d.id))
                       from erp.document d
                       join erp.document_type dt on dt.id = d.document_type_id
                       join erp.object_state os on os.object_type = 'document'
                                               and os.object_id = d.id
                       join erp.state s on s.id = os.current_state_id
                      where d.tenant_id = erp.current_tenant_id()
                        and d.party_id = p_party_id
                        and dt.base_type_code = 'sales_order'
                        and s.is_committed and not s.is_terminal
                        and not d.is_cancelled), 0)
         + coalesce((select sum(si.debit_minor - si.credit_minor)
                       from erp.subledger_item si
                      where si.tenant_id = erp.current_tenant_id()
                        and si.party_id = p_party_id
                        and si.control_kind = 'receivable'), 0) as amt
  ),
  -- Debt past the policy's overdue window: an item still owing whose due date
  -- is further back than overdue_days_block.
  overdue as (
    select exists (
      select 1 from erp.subledger_item si, pol
       where si.tenant_id = erp.current_tenant_id()
         and si.party_id = p_party_id
         and si.control_kind = 'receivable'
         and si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0) > 0
         and si.due_date is not null
         and si.due_date < current_date - coalesce((pol.v ->> 'overdue_days_block')::integer, 30)) as any_overdue
  ),
  verdict as (
    select terms.credit_limit_minor,
           exposure.amt,
           coalesce(terms.is_blocked, false) as blocked,
           -- The limit, widened by the tolerance the policy allows.
           (terms.credit_limit_minor is not null
              and coalesce((pol.v ->> 'block_at_limit')::boolean, true)
              and exposure.amt > round(terms.credit_limit_minor * (1 + coalesce((pol.v ->> 'tolerance_pct')::numeric, 0) / 100))) as over_limit,
           overdue.any_overdue as overdue,
           terms.credit_status, terms.is_blocked, terms.block_reason
      from terms, exposure, pol, overdue
  )
  select v.credit_limit_minor, v.amt,
         v.credit_limit_minor - v.amt,
         v.credit_status, v.is_blocked,
         v.blocked or v.over_limit or v.overdue,
         -- Overdue debt is named ahead of the limit (20260923900000): a
         -- standing approval carries an order past the limit, never past debt
         -- the policy says stops supply, and the reason is what says which.
         case when v.blocked then coalesce(v.block_reason, 'blocked')
              when v.overdue then 'debt is overdue beyond the policy''s window'
              when v.over_limit then 'exposure exceeds the credit limit'
              else 'within terms' end
    from verdict v
$reference$;

revoke all on function erp_test.credit_position_reference(uuid) from public, anon;

comment on function erp_test.credit_position_reference(uuid) is
  'erp.credit_position() as it was before 20261006080000, word for word, counting each order through '
  'erp_test.sales_order_uninvoiced_reference(): the position the set-based read must still give (J-24). Read only '
  'by erp_test.credit_positions_suite.';

-- ─────────────────────────────────────────────────────────────────────────────
-- D. A demonstration that has traded, and every case the rules know
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.credit_positions_fixture()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  a2       uuid := gen_random_uuid();
  a3       uuid := gen_random_uuid();
  v_res    jsonb;
  -- A month of trading fourteen months back, as erp_test.demo_history_suite
  -- slices it: everything it leaves owing is long overdue.
  v_slice  date := (date_trunc('month', current_date) - interval '14 months')::date;
  rb       record;
  r2       record;
  v_step   text := 'a demonstration with a month of trading';
  v_site   uuid;
  v_entity uuid;
  v_ccy    char(3);
  v_co2    uuid;
  v_item   uuid;
  v_free   uuid[];
  v_held   uuid[];
  v_all    uuid[];
  c_a uuid; c_b uuid; c_c uuid; c_f uuid; c_h uuid; c_d uuid; c_e uuid; c_g uuid;
  v_supplier uuid;
  v_other  uuid;
  v_o1 uuid; v_o1l uuid; v_o2 uuid; v_o2l uuid; v_o3 uuid; v_o4 uuid;
  v_dn uuid; v_inv1 uuid; v_draft uuid; v_cancelled uuid; v_over uuid; v_inv3 uuid; v_cn uuid;
  v_item_si uuid;
  v_dns    uuid[] := '{}';
  v_o5     uuid;
  v_party  uuid;
  v_n      integer;
  v_exp    bigint;
  v_from   date;
begin
  select * into rb from erp.provision_tenant(
    'demo-zzcp' || v_tag, 'Credit Positions Suite', 'admin@demo-zzcp' || v_tag || '.test', 'Credit Admin');
  update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
  insert into auth.users (id, email) values (a1, 'admin@demo-zzcp' || v_tag || '.test');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(rb.admin_token);
  perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
  perform erp_test.build_demo_days(v_slice, (v_slice + interval '1 month')::date - 1);
  -- A second administrator invoices what the first despatched: the same
  -- person may not do both.
  v_step := 'a second administrator';
  insert into auth.users (id, email) values (a2, 'second@demo-zzcp' || v_tag || '.test');
  v_res := public.erp_invite_principal('second@demo-zzcp' || v_tag || '.test', 'Second Admin');
  perform erp.grant_role((v_res ->> 'app_user_id')::uuid, 'administrator', null, null, 'the credit positions suite');
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(v_res ->> 'token');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  v_step := 'choosing the customers';
  select s.id, s.entity_id into v_site, v_entity
    from erp.site s where s.tenant_id = rb.tenant_id and s.entity_id = rb.entity_id and s.status = 'active'
   order by s.code limit 1;
  select e.base_currency into v_ccy from erp.entity e where e.tenant_id = rb.tenant_id and e.id = v_entity;
  select b.item_id into v_item
    from erp.stock_balance b where b.tenant_id = rb.tenant_id and b.site_id = v_site
   group by b.item_id having sum(b.quantity) >= 25
   order by b.item_id limit 1;
  -- Customers the month left within terms take the new orders; customers it
  -- left holding overdue debt show that debt ahead of a limit.
  select array_agg(p.id order by p.code) filter (where not coalesce(o.on_hold, false)),
         array_agg(p.id order by p.code) filter (where coalesce(o.on_hold, false)),
         array_agg(p.id order by p.code)
    into v_free, v_held, v_all
    from erp.party_role pr
    join erp.party p on p.id = pr.party_id
    left join lateral erp_test.credit_position_reference(p.id) o on true
   where pr.tenant_id = rb.tenant_id and pr.role_kind = 'customer';
  c_a := v_free[1]; c_b := v_free[2]; c_c := v_free[3]; c_f := v_free[4];
  c_h := v_held[1]; c_d := v_held[2]; c_e := v_held[3]; c_g := v_held[4];
  select pr.party_id into v_supplier
    from erp.party_role pr where pr.tenant_id = rb.tenant_id and pr.role_kind = 'supplier'
     and not exists (select 1 from erp.party_role x where x.tenant_id = pr.tenant_id and x.party_id = pr.party_id
                       and x.role_kind = 'customer')
   order by pr.party_id limit 1;

  -- ── Orders part delivered, part invoiced, invoiced beyond, credited ───────
  -- The first order: twelve ordered; four delivered and invoiced, three
  -- delivered and not invoiced, two delivered with a draft invoice, one
  -- delivered with an invoice cancelled, two still to go. The second: three
  -- ordered at 10.00, two delivered and invoiced at 20.00 each. The third:
  -- invoiced in full, then credited. Two more confirmed, nothing delivered.
  v_step := 'orders delivered in part';
  v_o1 := erp.open_document('sales_order', c_a, null, v_site);
  v_o1l := erp.add_document_line(v_o1, v_item, 12, 1000, 'the credit positions suite');
  perform erp.transition_document(v_o1, 'submit', 'the credit positions suite');
  perform erp_test.approve_document(v_o1, 'the credit positions suite');
  v_o2 := erp.open_document('sales_order', c_a, null, v_site);
  v_o2l := erp.add_document_line(v_o2, v_item, 3, 1000, 'the credit positions suite');
  perform erp.transition_document(v_o2, 'submit', 'the credit positions suite');
  perform erp_test.approve_document(v_o2, 'the credit positions suite');
  v_o3 := erp.open_document('sales_order', c_b, null, v_site);
  perform erp.add_document_line(v_o3, v_item, 2, 1000, 'the credit positions suite');
  perform erp.transition_document(v_o3, 'submit', 'the credit positions suite');
  perform erp_test.approve_document(v_o3, 'the credit positions suite');
  -- And an order confirmed and not yet delivered for each of the customers
  -- whose limits are tried below, so each has something on order.
  foreach v_party in array array[c_b, c_f] loop
    v_o5 := erp.open_document('sales_order', v_party, null, v_site);
    perform erp.add_document_line(v_o5, v_item, 5, 1000, 'the credit positions suite');
    perform erp.transition_document(v_o5, 'submit', 'the credit positions suite');
    perform erp_test.approve_document(v_o5, 'the credit positions suite');
  end loop;
  for v_n in 1 .. 4 loop
    v_dn := (erp.create_delivery_from_order(v_o1, jsonb_build_array(jsonb_build_object(
              'line_id', v_o1l, 'quantity', (array[4, 3, 2, 1])[v_n]))) ->> 'document_id')::uuid;
    perform erp.transition_document(v_dn, 'post', 'the credit positions suite');
    v_dns := v_dns || v_dn;
  end loop;
  v_dn := (erp.create_delivery_from_order(v_o2, jsonb_build_array(jsonb_build_object('line_id', v_o2l, 'quantity', 2))) ->> 'document_id')::uuid;
  perform erp.transition_document(v_dn, 'post', 'the credit positions suite');
  v_dns := v_dns || v_dn;
  v_dn := (erp.create_delivery_from_order(v_o3) ->> 'document_id')::uuid;
  perform erp.transition_document(v_dn, 'post', 'the credit positions suite');
  v_dns := v_dns || v_dn;

  v_step := 'invoices issued, left in draft, cancelled and credited';
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  v_inv1 := erp.invoice_from_delivery(v_dns[1]);
  perform erp.transition_document(v_inv1, 'issue', 'the credit positions suite');
  v_draft := erp.invoice_from_delivery(v_dns[3]);
  v_cancelled := erp.invoice_from_delivery(v_dns[4]);
  perform erp.transition_document(v_cancelled, 'cancel', 'the credit positions suite');
  v_over := erp.invoice_from_delivery(v_dns[5]);
  update erp.document_line set unit_price_minor = unit_price_minor * 2, net_minor = net_minor * 2
   where tenant_id = rb.tenant_id and document_id = v_over;
  perform erp.transition_document(v_over, 'issue', 'the credit positions suite');
  v_inv3 := erp.invoice_from_delivery(v_dns[6]);
  perform erp.transition_document(v_inv3, 'issue', 'the credit positions suite');
  v_cn := erp.raise_customer_credit_note(v_inv3, 'damaged', 'the credit positions suite');
  perform erp.transition_document(v_cn, 'issue', 'the credit positions suite');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  -- ── Cash received against part of the first invoice ────────────────────────
  v_step := 'cash received against part of the invoice';
  select si.id into v_item_si
    from erp.subledger_item si
   where si.tenant_id = rb.tenant_id and si.document_id = v_inv1 and si.control_kind = 'receivable'
   order by si.id limit 1;
  perform erp.apply_cash_to_item(v_item_si, 1500, 'the credit positions suite', current_date);

  -- ── An order not yet committed ─────────────────────────────────────────────
  v_step := 'an order not yet committed';
  v_o4 := erp.open_document('sales_order', c_a, null, v_site);
  perform erp.add_document_line(v_o4, v_item, 1, 2500, 'the credit positions suite');

  -- ── Terms at two companies, each with its own credit policy ────────────────
  v_step := 'a second company with a credit policy of its own';
  insert into erp.entity (tenant_id, code, name, base_currency, status)
  values (rb.tenant_id, 'CO2', 'Second company', v_ccy, 'active') returning id into v_co2;
  perform erp.ensure_entity_party(v_co2);
  perform erp.set_config_value('sales.credit_control',
    jsonb_build_object('tolerance_pct', 10, 'block_at_limit', true, 'check_at_capture', false, 'overdue_days_block', 180),
    null, null, v_co2, null, 'the credit positions suite');
  -- The second customer's newer terms are at the second company, with a limit
  -- its exposure passes by less than that company's ten per cent tolerance and
  -- by more than the first company's five.
  v_step := 'terms at the second company';
  select o.exposure_minor into v_exp from erp_test.credit_position_reference(c_b) o;
  insert into erp.party_role_terms (
    tenant_id, party_role_id, entity_id, currency, credit_limit_minor, credit_status, is_blocked, valid_from)
  select rb.tenant_id, pr.id, v_co2, v_ccy, floor(v_exp / 1.08)::bigint, 'watch', false, current_date - 1
    from erp.party_role pr where pr.tenant_id = rb.tenant_id and pr.party_id = c_b and pr.role_kind = 'customer';
  -- The third customer's terms at the second company started before its first
  -- company's, so the first company's are the ones in force.
  select min(t.valid_from) into v_from
    from erp.party_role_terms t join erp.party_role pr on pr.id = t.party_role_id
   where t.tenant_id = rb.tenant_id and pr.party_id = c_c and pr.role_kind = 'customer';
  insert into erp.party_role_terms (
    tenant_id, party_role_id, entity_id, currency, credit_limit_minor, credit_status, is_blocked, valid_from)
  select rb.tenant_id, pr.id, v_co2, v_ccy, 1, 'stop', false, v_from - 30
    from erp.party_role pr where pr.tenant_id = rb.tenant_id and pr.party_id = c_c and pr.role_kind = 'customer';

  -- ── A limit passed, overdue debt, blocks, terms ended ──────────────────────
  v_step := 'a limit passed beyond the tolerance';
  select o.exposure_minor into v_exp from erp_test.credit_position_reference(c_f) o;
  update erp.party_role_terms t set credit_limit_minor = floor(v_exp / 1.08)::bigint
    from erp.party_role pr
   where pr.id = t.party_role_id and t.tenant_id = rb.tenant_id and pr.party_id = c_f and pr.role_kind = 'customer';
  v_step := 'overdue debt and a limit passed';
  update erp.party_role_terms t set credit_limit_minor = 1
    from erp.party_role pr
   where pr.id = t.party_role_id and t.tenant_id = rb.tenant_id and pr.party_id = c_h and pr.role_kind = 'customer';
  v_step := 'two customers blocked';
  update erp.party_role_terms t set is_blocked = true, block_reason = 'Disputed invoices'
    from erp.party_role pr
   where pr.id = t.party_role_id and t.tenant_id = rb.tenant_id and pr.party_id = c_d and pr.role_kind = 'customer';
  update erp.party_role_terms t set is_blocked = true, block_reason = null
    from erp.party_role pr
   where pr.id = t.party_role_id and t.tenant_id = rb.tenant_id and pr.party_id = c_e and pr.role_kind = 'customer';
  v_step := 'terms that have ended';
  update erp.party_role_terms t set valid_to = current_date
    from erp.party_role pr
   where pr.id = t.party_role_id and t.tenant_id = rb.tenant_id and pr.party_id = c_g and pr.role_kind = 'customer';

  -- ── A second organisation with a customer of its own ───────────────────────
  v_step := 'a second organisation';
  select * into r2 from erp.provision_tenant(
    'zz-cps2-' || v_tag, 'Credit Positions Other', 'admin@zz-cps2-' || v_tag || '.test', 'Other Admin');
  insert into auth.users (id, email) values (a3, 'admin@zz-cps2-' || v_tag || '.test');
  perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
  perform erp.claim_invitation(r2.admin_token);
  insert into erp.party (tenant_id, code, name, status)
  values (r2.tenant_id, 'ZCPSOTHER', 'Another organisation''s customer', 'active') returning id into v_other;
  insert into erp.party_role (tenant_id, party_id, role_kind, status)
  values (r2.tenant_id, v_other, 'customer', 'active');
  insert into erp.party_role_terms (
    tenant_id, party_role_id, entity_id, currency, credit_limit_minor, credit_status, is_blocked, valid_from)
  select r2.tenant_id, pr.id, r2.entity_id, e.base_currency, 100000, 'ok', false, current_date - 1
    from erp.party_role pr
    join erp.entity e on e.tenant_id = r2.tenant_id and e.id = r2.entity_id
   where pr.tenant_id = r2.tenant_id and pr.party_id = v_other and pr.role_kind = 'customer';
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  return jsonb_build_object(
    'tenant_id', rb.tenant_id, 'admin', a1, 'other_tenant_id', r2.tenant_id, 'other_admin', a3,
    'entity_id', v_entity, 'second_company_id', v_co2,
    'customers', to_jsonb(v_all), 'part_invoiced', c_a, 'two_companies', c_b, 'earlier_second_terms', c_c,
    'over_limit', c_f, 'overdue', c_h, 'blocked', c_d, 'blocked_no_reason', c_e, 'terms_ended', c_g,
    'supplier', v_supplier, 'other_customer', v_other,
    'part_order', v_o1, 'over_order', v_o2, 'credited_order', v_o3, 'draft_order', v_o4,
    'invoice', v_inv1, 'draft_invoice', v_draft, 'cancelled_invoice', v_cancelled,
    'over_invoice', v_over, 'credit_note', v_cn);
exception when others then
  raise exception 'CLOVEERP_CREDIT_POSITIONS_FIXTURE: at "%": %', v_step, sqlerrm
    using hint = 'The fixture could not build the case it names. Read the step and the error.';
end;
$$;

revoke all on function erp_test.credit_positions_fixture() from public, anon;

comment on function erp_test.credit_positions_fixture() is
  'A demonstration with a month of trading plus every case the credit position rules know (20261006080000, J-24): '
  'an order part delivered and part invoiced, a draft and a cancelled invoice, an order invoiced beyond its value, a '
  'credit note, cash received, terms at two companies, a limit passed, overdue debt, blocks, terms ended and a second '
  'organisation. Built inside erp_test.credit_positions_suite and rolled back with it.';

-- ─────────────────────────────────────────────────────────────────────────────
-- E. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.credit_positions_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 9;
  v_cases  integer := 0;
  v_step   text := 'building the fixture';
  v_state  text;
  v_fx     jsonb;
  v_tenant uuid;
  v_party  uuid;
  v_n      integer;
  v_m      integer;
  v_k      integer;
  v_differ text;
  v_reasons text[];
  v_on_order integer;
  v_new    jsonb;
  v_ref    jsonb;
  v_one    jsonb;
  v_a      bigint;
  v_b      bigint;
  v_c      bigint;
  v_d      bigint;
  v_e      bigint;
  v_ok     boolean;
begin
  begin
    v_fx := erp_test.credit_positions_fixture();
    v_tenant := (v_fx ->> 'tenant_id')::uuid;

    -- ── 1. Every customer and every document, both ways ─────────────────────
    v_step := 'every customer of the demonstration, both ways';
    select count(*),
           count(*) filter (where n.p is distinct from r.p or c.p is distinct from r.p),
           string_agg(pa.code, ', ' order by pa.code) filter (where n.p is distinct from r.p or c.p is distinct from r.p),
           array_agg(distinct r.p ->> 'reason') filter (where r.p is not null),
           count(*) filter (where (select sum(erp_test.sales_order_uninvoiced_reference(d.id))
                                     from erp.document d
                                     join erp.document_type dt on dt.id = d.document_type_id
                                    where d.tenant_id = v_tenant and d.party_id = pr.party_id
                                      and dt.base_type_code = 'sales_order'
                                      and erp.object_current_state('document', d.id) in ('confirmed', 'partially_despatched')) > 0)
      into v_n, v_m, v_differ, v_reasons, v_on_order
      from erp.party_role pr
      join erp.party pa on pa.id = pr.party_id
      cross join lateral (select to_jsonb(x) - 'party_id' as p from erp.credit_positions(array[pr.party_id]) x) n
      cross join lateral (select (select to_jsonb(x) from erp.credit_position(pr.party_id) x) as p) c
      cross join lateral (select (select to_jsonb(x) from erp_test.credit_position_reference(pr.party_id) x) as p) r
     where pr.tenant_id = v_tenant and pr.role_kind = 'customer';
    -- The lateral above drops a customer the new read does not answer, so
    -- count those separately: a customer answered by one read and not the
    -- other differs.
    select count(*) into v_k
      from erp.party_role pr
     where pr.tenant_id = v_tenant and pr.role_kind = 'customer'
       and (exists (select 1 from erp.credit_positions(array[pr.party_id]))
            <> exists (select 1 from erp_test.credit_position_reference(pr.party_id)));
    v_step := 'every document of the demonstration, both ways';
    select count(*),
           count(*) filter (where coalesce(u.uninvoiced_minor, 0) <> erp_test.sales_order_uninvoiced_reference(d.id)
                               or erp.sales_order_uninvoiced_minor(d.id) <> erp_test.sales_order_uninvoiced_reference(d.id))
      into v_a, v_b
      from erp.document d
      left join erp.sales_orders_uninvoiced(array(select d2.id from erp.document d2 where d2.tenant_id = v_tenant)) u
        on u.order_id = d.id
     where d.tenant_id = v_tenant;
    v_cases := v_cases + 1;
    case_name := 'every customer and every document of a demonstration that has traded has the same figures as before';
    passed := v_m = 0 and v_k = 0 and v_b = 0 and v_n >= 8 and v_a >= 100
          and v_on_order >= 2
          and v_reasons @> array['within terms', 'debt is overdue beyond the policy''s window',
                                 'exposure exceeds the credit limit', 'Disputed invoices', 'blocked'];
    detail := format('%s customer(s) with terms, %s differing (%s), %s answered by one read only; %s document(s), %s '
                     'differing; %s customer(s) with open orders not yet invoiced; reasons: %s',
                     v_n, v_m, coalesce(v_differ, 'none'), v_k, v_a, v_b, v_on_order, array_to_string(v_reasons, ' / '));
    return next;

    -- ── 2. Every customer at once is each customer one at a time ────────────
    v_step := 'every customer at once';
    select count(*) into v_n
      from ((select to_jsonb(x) from erp.credit_positions(null) x
             except all
             select to_jsonb(x) from erp.party_role pr, erp.credit_positions(array[pr.party_id]) x
              where pr.tenant_id = v_tenant and pr.role_kind = 'customer')
            union all
            (select to_jsonb(x) from erp.party_role pr, erp.credit_positions(array[pr.party_id]) x
              where pr.tenant_id = v_tenant and pr.role_kind = 'customer'
             except all
             select to_jsonb(x) from erp.credit_positions(null) x)) z;
    select count(*) into v_m from erp.credit_positions(null);
    select count(*) into v_k from erp.credit_positions(array(select (jsonb_array_elements_text(v_fx -> 'customers'))::uuid));
    v_cases := v_cases + 1;
    case_name := 'every customer read at once is every customer read one at a time';
    passed := v_n = 0 and v_m >= 8 and v_k = v_m;
    detail := format('%s position(s) at once, %s for the list of customers, %s differing', v_m, v_k, v_n);
    return next;

    -- ── 3. An order part delivered and part invoiced ────────────────────────
    v_step := 'an order part delivered and part invoiced';
    v_a := erp.document_value_minor((v_fx ->> 'part_order')::uuid);
    v_b := erp.document_value_minor((v_fx ->> 'invoice')::uuid);
    select u.uninvoiced_minor into v_c
      from erp.sales_orders_uninvoiced(array[(v_fx ->> 'part_order')::uuid]) u;
    v_d := erp_test.sales_order_uninvoiced_reference((v_fx ->> 'part_order')::uuid);
    v_cases := v_cases + 1;
    case_name := 'an order part delivered and part invoiced counts its value less what it has invoiced';
    passed := v_a = 12000 and v_b = 4000 and v_c = 8000 and v_d = 8000
          and erp.object_current_state('document', (v_fx ->> 'part_order')::uuid) = 'partially_despatched';
    detail := format('ordered %s, invoiced %s, counted %s (before: %s), the order %s', v_a, v_b, v_c, v_d,
                     erp.object_current_state('document', (v_fx ->> 'part_order')::uuid));
    return next;

    -- ── 4. A draft and a cancelled invoice ──────────────────────────────────
    v_step := 'a draft and a cancelled invoice';
    v_cases := v_cases + 1;
    case_name := 'a draft invoice and a cancelled invoice are not taken off the order';
    passed := erp.object_current_state('document', (v_fx ->> 'draft_invoice')::uuid) = 'draft'
          and erp.object_current_state('document', (v_fx ->> 'cancelled_invoice')::uuid) = 'cancelled'
          and erp.document_value_minor((v_fx ->> 'draft_invoice')::uuid) = 2000
          and erp.document_value_minor((v_fx ->> 'cancelled_invoice')::uuid) = 1000
          and v_c = 8000;
    detail := format('draft invoice %s (%s), cancelled invoice %s (%s); the order still counts %s',
                     erp.object_current_state('document', (v_fx ->> 'draft_invoice')::uuid),
                     erp.document_value_minor((v_fx ->> 'draft_invoice')::uuid),
                     erp.object_current_state('document', (v_fx ->> 'cancelled_invoice')::uuid),
                     erp.document_value_minor((v_fx ->> 'cancelled_invoice')::uuid), v_c);
    return next;

    -- ── 5. An order invoiced beyond its value ───────────────────────────────
    v_step := 'an order invoiced beyond its value';
    v_a := erp.document_value_minor((v_fx ->> 'over_order')::uuid);
    v_b := erp.document_value_minor((v_fx ->> 'over_invoice')::uuid);
    select u.uninvoiced_minor into v_c
      from erp.sales_orders_uninvoiced(array[(v_fx ->> 'over_order')::uuid]) u;
    v_d := erp_test.sales_order_uninvoiced_reference((v_fx ->> 'over_order')::uuid);
    v_cases := v_cases + 1;
    case_name := 'an order invoiced beyond its value counts nothing, never less';
    passed := v_a = 3000 and v_b = 4000 and v_c = 0 and v_d = 0;
    detail := format('ordered %s, invoiced %s, counted %s (before: %s)', v_a, v_b, v_c, v_d);
    return next;

    -- ── 6. No terms in force, a supplier ────────────────────────────────────
    v_step := 'no terms in force, and a supplier';
    v_n := (select count(*) from erp.credit_positions(array[(v_fx ->> 'terms_ended')::uuid, (v_fx ->> 'supplier')::uuid]));
    v_m := (select count(*) from erp_test.credit_position_reference((v_fx ->> 'terms_ended')::uuid))
         + (select count(*) from erp_test.credit_position_reference((v_fx ->> 'supplier')::uuid));
    v_k := (select count(*) from erp.credit_positions(null) x
             where x.party_id in ((v_fx ->> 'terms_ended')::uuid, (v_fx ->> 'supplier')::uuid));
    v_cases := v_cases + 1;
    case_name := 'a customer whose terms have ended, and a supplier, have no credit position either way';
    passed := v_n = 0 and v_m = 0 and v_k = 0 and (v_fx ->> 'supplier') is not null and (v_fx ->> 'terms_ended') is not null;
    detail := format('%s row(s) now, %s before, %s among every customer', v_n, v_m, v_k);
    return next;

    -- ── 7. Overdue debt, the limit and its tolerance ────────────────────────
    v_step := 'overdue debt, the limit and its tolerance';
    select to_jsonb(x) - 'party_id' into v_new from erp.credit_positions(array[(v_fx ->> 'overdue')::uuid]) x;
    select to_jsonb(x) - 'party_id' into v_one from erp.credit_positions(array[(v_fx ->> 'over_limit')::uuid]) x;
    select to_jsonb(x) - 'party_id' into v_ref from erp.credit_positions(array[(v_fx ->> 'two_companies')::uuid]) x;
    v_ok := (select x.credit_limit_minor from erp.credit_positions(array[(v_fx ->> 'earlier_second_terms')::uuid]) x) > 1;
    v_cases := v_cases + 1;
    case_name := 'overdue debt holds and is named ahead of the limit; a limit passed holds; the tolerance of the terms'' company widens it';
    passed := (v_new ->> 'on_hold')::boolean and v_new ->> 'reason' = 'debt is overdue beyond the policy''s window'
          and (v_new ->> 'exposure_minor')::bigint > (v_new ->> 'credit_limit_minor')::bigint
          and (v_one ->> 'on_hold')::boolean and v_one ->> 'reason' = 'exposure exceeds the credit limit'
          and not (v_ref ->> 'on_hold')::boolean and v_ref ->> 'reason' = 'within terms'
          and (v_ref ->> 'exposure_minor')::bigint > (v_ref ->> 'credit_limit_minor')::bigint
          and v_ref ->> 'credit_status' = 'watch'
          and v_ok;
    detail := format('overdue: %s; over the limit at five per cent: %s; over the limit within the second company''s ten: %s; '
                     'older terms at the second company left aside: %s',
                     v_new ->> 'reason', v_one ->> 'reason', v_ref ->> 'reason', v_ok);
    return next;

    -- ── 8. Blocked terms ────────────────────────────────────────────────────
    v_step := 'blocked terms';
    select to_jsonb(x) - 'party_id' into v_new from erp.credit_positions(array[(v_fx ->> 'blocked')::uuid]) x;
    select to_jsonb(x) - 'party_id' into v_one from erp.credit_positions(array[(v_fx ->> 'blocked_no_reason')::uuid]) x;
    v_cases := v_cases + 1;
    case_name := 'blocked terms hold, with the reason they give or simply blocked';
    passed := (v_new ->> 'on_hold')::boolean and (v_new ->> 'is_blocked')::boolean and v_new ->> 'reason' = 'Disputed invoices'
          and (v_one ->> 'on_hold')::boolean and (v_one ->> 'is_blocked')::boolean and v_one ->> 'reason' = 'blocked';
    detail := format('%s; %s', v_new ->> 'reason', v_one ->> 'reason');
    return next;

    -- ── 9. Another organisation is not answered ─────────────────────────────
    v_step := 'another organisation';
    v_n := (select count(*) from erp.credit_positions(array[(v_fx ->> 'other_customer')::uuid]));
    v_m := (select count(*) from erp.sales_orders_uninvoiced(array[(v_fx ->> 'part_order')::uuid]));
    perform set_config('request.jwt.claims', json_build_object('sub', v_fx ->> 'other_admin')::text, true);
    v_k := (select count(*) from erp.credit_positions(array[(v_fx ->> 'part_invoiced')::uuid]));
    v_a := (select count(*) from erp.sales_orders_uninvoiced(array[(v_fx ->> 'part_order')::uuid]));
    v_b := (select count(*) from erp.credit_positions(null));
    v_c := (select count(*) from erp.credit_positions(null) x where x.party_id = (v_fx ->> 'other_customer')::uuid);
    perform set_config('request.jwt.claims', json_build_object('sub', v_fx ->> 'admin')::text, true);
    v_cases := v_cases + 1;
    case_name := 'a customer or an order of another organisation is not answered';
    passed := v_n = 0 and v_m = 1 and v_k = 0 and v_a = 0 and v_b = 1 and v_c = 1;
    detail := format('their customer read from here: %s; our order from here: %s; from there: our customer %s, our order %s, '
                     'every customer %s (theirs %s)', v_n, v_m, v_k, v_a, v_b, v_c);
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 300));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('erp.job_tenant_id', '', true);

  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_CREDIT_POSITIONS_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the fixture stopped; a case that cannot run is a case that fails.';
  end if;
end;
$$;

revoke all on function erp_test.credit_positions_suite() from public, anon;

comment on function erp_test.credit_positions_suite() is
  'A credit position can be worked out for many customers at once (20261006080000, J-24): on a demonstration that '
  'has traded, the set-based reads give the figures today''s bodies gave for every customer and every document, and '
  'each rule of the position holds on a stated figure.';

create or replace function erp_test.assert_credit_positions_suite()
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
    from erp_test.credit_positions_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_CREDIT_POSITIONS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A credit position would say otherwise than before, and an order could ship or stop that should not. Read the case that failed.';
  end if;
  if v_total <> 9 then
    raise exception 'CLOVEERP_CREDIT_POSITIONS_SUITE_SHRANK: % case(s), expected 9', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('credit positions: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_credit_positions_suite() from public, anon;

comment on function erp_test.assert_credit_positions_suite() is
  'The credit position read for many customers at once gives today''s figures (20261006080000).';

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
select erp.assert_personal_data_register_sound();
