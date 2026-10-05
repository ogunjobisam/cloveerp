set lock_timeout = '30s';

-- =============================================================================
-- 20261007140000  A transfer says what it moves
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-84). On Site
-- transfers, "Despatch a transfer" and "Receive a transfer" each offered all
-- 23 of the demonstration's received transfers, labelled with the state's
-- code ('in_transit', 'received'). The list of transfer orders had no date,
-- reference or product, its numbers opened nothing, and finished transfers
-- read two ways, 'received' and 'closed'.
--
-- ── WHAT IT IS ───────────────────────────────────────────────────────────────
--
-- The pickers asked public.erp_documents for every transfer that can still
-- move, and a transfer standing at received can still move: its lifecycle
-- closes it from there. They now ask for what each action applies to
-- (src/routes/inventory/transfers.tsx); erp_documents already answers that.
--
-- erp.transfer_orders() answered neither the reference a transfer was raised
-- with (erp.raise_transfer_order() keeps p_reference as the document's
-- their_reference) nor what it moves, nor its state's name.
--
-- Since 20260928200000 a transfer closes as its goods arrive
-- (erp.close_transfer_when_received()). A transfer received before then, on
-- version 1 of the lifecycle, stood at received, with its close a move
-- somebody had to make by hand, and nobody did. The demonstration has 23 of
-- these on live, and 3 closed. That gap is in every organisation that moved
-- stock between sites before 28 September; the repair below touches
-- demonstrations only. Anywhere else such a transfer is closed by hand from
-- its page, by its own close, as it always could be.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.transfer_orders() also answers state_name, their_reference and
--      products (the products' codes in line order). Its result gains three
--      columns, so it is dropped and created again; nothing else calls it
--      but public.erp_transfer_orders.
--   B. public.erp_transfer_orders answers newest first, as the report reads.
--   C. erp.close_transfers_left_received(): in a demonstration only, every
--      transfer order standing at received whose goods have all arrived is
--      closed by its own close, through erp.close_transfer_when_received()
--      where its version declares 'close' and by the version's 'closed' move
--      otherwise. Nothing moves and nothing posts: a close is a state.
--   D. Each demonstration's received transfers closed that way, as its
--      administrator who may move stock.
--   E. erp_test.transfer_says_what_it_moves_suite.
--
-- The screen's half is in src/routes/inventory/transfers.tsx and
-- src/components/erp/actions-bar.tsx (a document picker labels each document
-- with its state's name and can be narrowed to states).
--
-- On production: one report function is dropped and created again with three
-- more columns, and one door is edited where it aggregates. No table is
-- altered. In each demonstration (code 'demo-%'), transfer orders at received
-- with nothing on the road move to closed (23 in demo-cbb10384 on 4 October).
-- No other organisation's rows are changed. No email is sent.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The report says what each transfer moves
-- ─────────────────────────────────────────────────────────────────────────────

do $report$
declare
  v_sig constant text := 'erp.transfer_orders(integer)';
  v_src text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
begin
  if strpos(v_src, '20261007140000') > 0 then
    raise notice '% already says what each transfer moves; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'faf0d79a0fad7a86d636446c37aaf1d3' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261007140000 expects (md5 %)', v_sig, md5(v_src);
  end if;

  execute 'drop function erp.transfer_orders(integer)';
  execute $def$
create function erp.transfer_orders(p_limit integer default 100)
returns table(document_id uuid, document_number text, state text, from_site text, to_site text,
              document_date date, required_date date, lines integer, quantity numeric,
              in_transit numeric, value_moved_minor bigint, currency text,
              state_name text, their_reference text, products text)
language sql
stable
set search_path = ''
as $fn$
  -- Every transfer order with both its sites, what it moves, how much is on
  -- the road and what the receiving site was given for it. With its state's
  -- name, the reference it was raised with and its products' codes in line
  -- order, so one transfer can be told from another (20261007140000, J-84).
  with t as (select erp.require_tenant_id() as tenant_id)
  select d.id, d.document_number,
         s.code,
         fs.code, ts.code, d.document_date, d.required_date,
         (select count(*)::integer from erp.document_line l
           where l.tenant_id = d.tenant_id and l.document_id = d.id
             and not l.is_cancelled),
         (select coalesce(sum(l.quantity), 0) from erp.document_line l
           where l.tenant_id = d.tenant_id and l.document_id = d.id
             and not l.is_cancelled),
         (select coalesce(sum(case when m.to_status = 'in_transit' then m.quantity
                                   when m.from_status = 'in_transit' then -m.quantity
                                   else 0 end), 0)
            from erp.stock_movement m
           where m.tenant_id = d.tenant_id and m.document_id = d.id
             and not m.is_reversal),
         (select coalesce(sum(m.cost_minor), 0)::bigint
            from erp.stock_movement m
           where m.tenant_id = d.tenant_id and m.document_id = d.id
             and m.movement_type = 'transfer_in' and not m.is_reversal),
         coalesce(d.currency, en.base_currency)::text,
         s.name,
         nullif(btrim(d.their_reference), ''),
         (select string_agg(i.code, ', ' order by l.line_no, l.id)
            from erp.document_line l
            join erp.item i on i.tenant_id = l.tenant_id and i.id = l.item_id
           where l.tenant_id = d.tenant_id and l.document_id = d.id
             and not l.is_cancelled)
    from t
    join erp.document d on d.tenant_id = t.tenant_id
    join erp.entity en on en.tenant_id = d.tenant_id and en.id = d.entity_id
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
    left join erp.site fs on fs.tenant_id = d.tenant_id and fs.id = d.site_id
    left join erp.site ts on ts.tenant_id = d.tenant_id and ts.id = d.destination_site_id
    left join erp.object_state os
      on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
    left join erp.state s on s.id = os.current_state_id
   where dt.base_type_code = 'transfer_order'
   order by d.document_date desc, d.document_number desc
   limit greatest(coalesce(p_limit, 100), 1)
$fn$
$def$;
end
$report$;

revoke all on function erp.transfer_orders(integer) from public, anon;

comment on function erp.transfer_orders(integer) is
  'Every transfer order with both its sites, what it moves (its products'' codes in line order), how much is on the '
  'road, what the receiving site was given for it, its state by code and name, and the reference it was raised '
  'with (20261007140000). Runs as the caller, so row security decides what is visible.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The door answers newest first
-- ─────────────────────────────────────────────────────────────────────────────

do $door$
declare
  v_sig  constant text := 'public.erp_transfer_orders(integer)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb)$o$;
  v_new  constant text := $n$  -- Newest first, as the report reads (20261007140000).
  select coalesce(jsonb_agg(to_jsonb(x) order by x.document_date desc, x.document_number desc), '[]'::jsonb)$n$;
begin
  if strpos(v_src, '20261007140000') > 0 then
    raise notice '% already answers newest first; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'f74ca6ce9b3175a194ce9a2d6da39e0c' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261007140000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$door$;

comment on function public.erp_transfer_orders(integer) is
  'Every transfer order with both its sites, what it is moving, how much of that is on the road right now, and what '
  'the receiving site was given for it, with its state''s name, its reference and its products, newest first '
  '(20261007140000). Requires an organisation.';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. A demonstration's transfers left at received are closed
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.close_transfers_left_received()
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  c_reason constant text :=
    'Received before a transfer closed itself as its goods arrived, so it is closed now.';
  r        record;
  v_to     text;
  v_n      integer := 0;
begin
  -- A transfer order received before 20260928200000 stood at received, its
  -- close a move nobody made (20261007140000, J-84). In a demonstration only:
  -- each one whose goods have all arrived is closed by its own close, the
  -- derived one where its version declares 'close' and the version's
  -- 'closed' otherwise, both through erp.transition_document(), so whoever
  -- this runs as must be allowed the move. Returns how many were closed.
  if not erp.tenant_is_demonstration(v_tenant) then
    return 0;
  end if;

  for r in
    select d.id
      from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
      join erp.object_state os
        on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
      join erp.state s on s.id = os.current_state_id
     where d.tenant_id = v_tenant
       and dt.base_type_code = 'transfer_order'
       and s.code = 'received'
       and not d.is_cancelled
     order by d.document_date, d.document_number, d.id
  loop
    continue when not coalesce(erp.transfer_is_received_in_full(r.id), false);
    if erp.document_declares_move(r.id, 'close') then
      v_to := erp.close_transfer_when_received(r.id, c_reason);
    elsif erp.document_declares_move(r.id, 'closed') then
      v_to := erp.transition_document(r.id, 'closed', c_reason);
    else
      v_to := null;
    end if;
    if v_to = 'closed' then
      v_n := v_n + 1;
    end if;
  end loop;

  return v_n;
end;
$$;

revoke all on function erp.close_transfers_left_received() from public, anon;

comment on function erp.close_transfers_left_received() is
  'In a demonstration, closes every transfer order standing at received whose goods have all arrived, by its own '
  'close, as the person it runs as; a transfer received before transfers closed on arrival (20261007140000, J-84). '
  'Anywhere else it does nothing. Returns how many were closed.';

-- ─────────────────────────────────────────────────────────────────────────────
-- E. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.transfer_says_what_it_moves_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 5;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_code   text;
  v_ccy    char(3);
  v_uom    uuid; v_a uuid; v_b uuid;
  s_a      uuid; s_b uuid; l_a uuid; l_b uuid;
  t1       uuid; t2 uuid; u_left uuid; u_road uuid;
  x        jsonb;
  v_name   text;
  v_got    text; v_want text;
  v_recv   jsonb; v_desp jsonb;
  v_n      integer; v_n2 integer;
  v_moves  integer; v_moves2 integer;
begin
  begin
    -- ── The fixture: a demonstration with two sites and stock at the first ──
    v_step := 'a demonstration';
    perform set_config('request.jwt.claims', '', true);
    v_code := 'demo-zztw' || v_tag;
    select * into rb from erp.provision_tenant(
      v_code, 'Transfer Says Suite', 'admin@' || v_code || '.test', 'Transfer Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@' || v_code || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    select e.base_currency into v_ccy from erp.entity e where e.id = rb.entity_id;

    v_step := 'two sites and stock at the first';
    insert into erp.site (tenant_id, entity_id, code, name, site_type, country_code, status)
    values (rb.tenant_id, rb.entity_id, 'ZZTW-A', 'Despatching', 'warehouse', 'GB', 'active') returning id into s_a;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, country_code, status)
    values (rb.tenant_id, rb.entity_id, 'ZZTW-B', 'Receiving', 'warehouse', 'GB', 'active') returning id into s_b;
    insert into erp.location (tenant_id, site_id, code, name, location_type, is_pickable, status)
    values (rb.tenant_id, s_a, 'ZZTW-A-BULK', 'A bulk', 'bulk', true, 'active') returning id into l_a;
    insert into erp.location (tenant_id, site_id, code, name, location_type, is_pickable, status)
    values (rb.tenant_id, s_b, 'ZZTW-B-IN', 'B in', 'receiving', false, 'active') returning id into l_b;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZZTW-B', 'Second widget', v_uom, 'active') returning id into v_b;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZZTW-A', 'First widget', v_uom, 'active') returning id into v_a;
    perform erp.receive_cost(v_a, s_a, 200, 500, v_ccy);
    perform erp.receive_cost(v_b, s_a, 200, 300, v_ccy);
    insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id, to_location_id,
      to_status, quantity, uom_id, unit_cost_minor, currency, reason_code)
    values (rb.tenant_id, rb.entity_id, s_a, 'receipt_no_order', v_a, l_a, 'available', 200, v_uom, 500, v_ccy, 'OPENING'),
           (rb.tenant_id, rb.entity_id, s_a, 'receipt_no_order', v_b, l_a, 'available', 200, v_uom, 300, v_ccy, 'OPENING');

    -- ── 1. The list says what each transfer moves ───────────────────────────
    v_step := 'a transfer of two products with a reference';
    t1 := (erp.raise_transfer_order(s_a, s_b, jsonb_build_array(
             jsonb_build_object('item_id', v_b, 'quantity', 2),
             jsonb_build_object('item_id', v_a, 'quantity', 3)), null, 'ZZ-REF-1') ->> 'document_id')::uuid;
    select e into x from jsonb_array_elements(public.erp_transfer_orders(200)) e
     where e ->> 'document_id' = t1::text;
    select s.name into v_name
      from erp.object_state os join erp.state s on s.id = os.current_state_id
     where os.tenant_id = rb.tenant_id and os.object_type = 'document' and os.object_id = t1;
    v_cases := v_cases + 1;
    case_name := 'the list says what a transfer moves: the reference it was raised with, its products in line order, and its state by name';
    passed := v_state is null
          and x ->> 'their_reference' = 'ZZ-REF-1'
          and x ->> 'products' = 'ZZTW-B, ZZTW-A'
          and x ->> 'state' = 'approved'
          and x ->> 'state_name' = v_name and v_name is not null
          and x ->> 'document_date' is not null;
    detail := coalesce(v_state, coalesce(x::text, 'not in the list'));
    return next;

    -- ── 2. Newest first ─────────────────────────────────────────────────────
    v_step := 'a second transfer';
    t2 := (erp.raise_transfer_order(s_a, s_b, jsonb_build_array(
             jsonb_build_object('item_id', v_a, 'quantity', 1))) ->> 'document_id')::uuid;
    select string_agg(e ->> 'document_id', ',' order by n) into v_got
      from jsonb_array_elements(public.erp_transfer_orders(200)) with ordinality as a(e, n);
    select string_agg(d.id::text, ',' order by d.document_date desc, d.document_number desc) into v_want
      from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
     where d.tenant_id = rb.tenant_id and dt.base_type_code = 'transfer_order';
    v_cases := v_cases + 1;
    case_name := 'the list reads newest first, a transfer with no reference says none, and one product reads as itself';
    passed := v_state is null and v_got = v_want and split_part(v_got, ',', 1) = t2::text
          and (select e ->> 'their_reference' from jsonb_array_elements(public.erp_transfer_orders(200)) e
                where e ->> 'document_id' = t2::text) is null
          and (select e ->> 'products' from jsonb_array_elements(public.erp_transfer_orders(200)) e
                where e ->> 'document_id' = t2::text) = 'ZZTW-A';
    detail := coalesce(v_state, format('read %s; expected %s', v_got, v_want));
    return next;

    -- ── 3. Each picker is offered what its action applies to ────────────────
    v_step := 'the first transfer despatched';
    perform erp.despatch_transfer(t1);
    v_recv := public.erp_documents('transfer_order', 200, false, true, 'received', null);
    v_desp := public.erp_documents('transfer_order', 200, false, true, null, array['approved', 'issued']);
    v_cases := v_cases + 1;
    case_name := 'Receive is offered what is on the road and Despatch what is approved, each with its state by name';
    passed := v_state is null
          and exists (select 1 from jsonb_array_elements(v_recv) e where e ->> 'document_id' = t1::text)
          and not exists (select 1 from jsonb_array_elements(v_recv) e where e ->> 'document_id' = t2::text)
          and exists (select 1 from jsonb_array_elements(v_desp) e
                       where e ->> 'document_id' = t2::text and e ->> 'state_name' is not null)
          and not exists (select 1 from jsonb_array_elements(v_desp) e where e ->> 'document_id' = t1::text);
    detail := coalesce(v_state, format('receive offers %s; despatch offers %s',
                (select string_agg(e ->> 'document_number', ',') from jsonb_array_elements(v_recv) e),
                (select string_agg(e ->> 'document_number', ',') from jsonb_array_elements(v_desp) e)));
    return next;

    -- ── 4. A transfer left at received is closed, and one on the road is not ─
    v_step := 'received, on version 1, before transfers closed on arrival';
    perform erp.receive_transfer(t1);
    perform erp_test.transfer_order_on_version_1();
    u_left := (erp.raise_transfer_order(s_a, s_b, jsonb_build_array(
                 jsonb_build_object('item_id', v_a, 'quantity', 4))) ->> 'document_id')::uuid;
    perform erp.transition_document(u_left, 'approved', 'approved the way version 1 is');
    perform erp.despatch_transfer(u_left);
    perform erp.receive_transfer(u_left);
    u_road := (erp.raise_transfer_order(s_a, s_b, jsonb_build_array(
                 jsonb_build_object('item_id', v_a, 'quantity', 5))) ->> 'document_id')::uuid;
    perform erp.transition_document(u_road, 'approved', 'approved the way version 1 is');
    perform erp.despatch_transfer(u_road);
    v_got := erp.document_state_code(u_left);
    select count(*) into v_moves from erp.stock_movement m
     where m.tenant_id = rb.tenant_id and m.document_id in (u_left, u_road);
    v_step := 'closing what was left received';
    v_n := erp.close_transfers_left_received();
    select count(*) into v_moves2 from erp.stock_movement m
     where m.tenant_id = rb.tenant_id and m.document_id in (u_left, u_road);
    v_cases := v_cases + 1;
    case_name := 'a transfer left at received is closed by its own close, nothing moves, and one still on the road is left';
    passed := v_state is null and v_got = 'received' and v_n = 1
          and erp.document_state_code(u_left) = 'closed'
          and erp.document_state_code(u_road) = 'in_transit'
          and erp.document_state_code(t1) = 'closed'
          and v_moves2 = v_moves
          and exists (select 1 from erp.state_transition_log l
                       where l.tenant_id = rb.tenant_id and l.object_id = u_left
                         and l.transition_code = 'closed' and l.to_state_code = 'closed')
          and not exists (select 1 from jsonb_array_elements(
                            public.erp_documents('transfer_order', 200, false, true, 'received', null)) e
                           where e ->> 'document_id' in (u_left::text, t1::text));
    detail := coalesce(v_state, format('stood %s; closed %s; then %s, on the road %s; movements %s then %s',
                v_got, v_n, erp.document_state_code(u_left), erp.document_state_code(u_road), v_moves, v_moves2));
    return next;

    -- ── 5. Asked again nothing more, and never outside a demonstration ──────
    v_step := 'a second transfer left at received, in an organisation that is not a demonstration';
    perform erp.receive_transfer(u_road);
    update erp.tenant set code = 'zztw-' || v_tag where id = rb.tenant_id;
    v_n := erp.close_transfers_left_received();
    v_got := erp.document_state_code(u_road);
    update erp.tenant set code = v_code where id = rb.tenant_id;
    v_n2 := erp.close_transfers_left_received();
    v_cases := v_cases + 1;
    case_name := 'outside a demonstration nothing is closed; back in one, only what is left at received is';
    passed := v_state is null and v_n = 0 and v_got = 'received' and v_n2 = 1
          and erp.document_state_code(u_road) = 'closed'
          and erp.close_transfers_left_received() = 0;
    detail := coalesce(v_state, format('not a demonstration: %s closed, it stood %s; a demonstration again: %s closed, it is %s',
                v_n, v_got, v_n2, erp.document_state_code(u_road)));
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
    raise exception 'CLOVEERP_TRANSFER_SAYS_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the fixture stopped; a case that cannot run is a case that fails.';
  end if;
  if exists (select 1 from erp.tenant t where t.code in (v_code, 'zztw-' || v_tag))
     or exists (select 1 from auth.users u where u.id = a1) then
    raise exception 'CLOVEERP_TRANSFER_SAYS_SUITE_LEAKED: the fixture was not undone'
      using hint = 'The suite must raise CLOVEERP_SUITE_UNDO inside its block so everything it made rolls back.';
  end if;
end;
$$;

revoke all on function erp_test.transfer_says_what_it_moves_suite() from public, anon;

comment on function erp_test.transfer_says_what_it_moves_suite() is
  'A transfer says what it moves (20261007140000, J-84): the list answers each transfer''s reference, products and '
  'state by name, newest first; Receive is offered what is on the road and Despatch what is approved; a transfer '
  'left at received is closed by its own close with nothing moved, only in a demonstration.';

create or replace function erp_test.assert_transfer_says_what_it_moves_suite()
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
    from erp_test.transfer_says_what_it_moves_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_TRANSFER_SAYS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'Site transfers would not say what each transfer moves, or would offer the wrong ones. Read the case that failed.';
  end if;
  if v_total <> 5 then
    raise exception 'CLOVEERP_TRANSFER_SAYS_SUITE_SHRANK: % case(s), expected 5', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('transfer says what it moves: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_transfer_says_what_it_moves_suite() from public, anon;

comment on function erp_test.assert_transfer_says_what_it_moves_suite() is
  'Site transfers say what each transfer moves and offer each action only what it applies to, and a demonstration''s '
  'transfers left at received are closed (20261007140000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- D. Each demonstration's transfers left at received, closed as its
--    administrator who may move stock
-- ─────────────────────────────────────────────────────────────────────────────

do $repair$
declare
  r          record;
  v_admin    uuid;
  v_pref     uuid;
  v_pref_at  timestamptz;
  v_had_pref boolean;
  v_n        integer;
  v_left     integer;
begin
  for r in select tn.id, tn.code from erp.tenant tn
            where tn.deleted_at is null and tn.code like 'demo-%' order by tn.code loop
    perform erp_meta.act_in_tenant(r.id);
    continue when not exists (
      select 1
        from erp.document d
        join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
        join erp.object_state os
          on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
        join erp.state s on s.id = os.current_state_id
       where d.tenant_id = r.id and dt.base_type_code = 'transfer_order' and s.code = 'received');

    -- Closing is authorised to somebody: the demonstration's longest-
    -- standing administrator who may move stock everywhere, as
    -- 20261006011000 picks the person who cancels its counts.
    v_admin := null;
    select u.auth_user_id into v_admin
      from erp.app_user u
     where u.tenant_id = r.id
       and u.kind = 'person'::erp.principal_kind
       and u.status = 'active'::erp.principal_status
       and u.auth_user_id is not null
       and erp.has_permission('inventory.move', null, null, null, u.id)
     order by u.created_at, u.id
     limit 1;
    if v_admin is null then
      raise warning 'received transfers: nobody in % may move stock, so its transfers are left as they are', r.code;
      continue;
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
    perform set_config('erp.job_tenant_id', r.id::text, true);
    -- The administrator resolves to the organisation they last chose; it is
    -- made the demonstration for this transaction and put back after.
    select p.active_tenant_id, p.chosen_at into v_pref, v_pref_at
      from erp_meta.principal_preference p
     where p.auth_user_id = v_admin;
    v_had_pref := found;
    insert into erp_meta.principal_preference (auth_user_id, active_tenant_id, chosen_at)
    values (v_admin, r.id, now())
    on conflict (auth_user_id) do update
      set active_tenant_id = excluded.active_tenant_id, chosen_at = excluded.chosen_at;

    v_n := 0;
    if erp.current_tenant_id() is distinct from r.id or erp.current_principal_id() is null then
      raise warning 'received transfers: % does not resolve to its administrator, so its transfers are left as they are', r.code;
    else
      v_n := erp.close_transfers_left_received();
      -- The checks the writes left waiting, fired while still in the
      -- organisation they read, so the generators below can alter the tables.
      set constraints all immediate;
    end if;

    if v_had_pref then
      update erp_meta.principal_preference
         set active_tenant_id = v_pref, chosen_at = v_pref_at
       where auth_user_id = v_admin;
    else
      delete from erp_meta.principal_preference where auth_user_id = v_admin;
    end if;
    perform set_config('request.jwt.claims', '', true);

    select count(*) into v_left
      from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
      join erp.object_state os
        on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
      join erp.state s on s.id = os.current_state_id
     where d.tenant_id = r.id and dt.base_type_code = 'transfer_order' and s.code = 'received';
    raise warning 'received transfers: % of % closed; % left at received', v_n, r.code, v_left;
  end loop;
  perform erp_meta.stop_acting_in_tenant();
end
$repair$;

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
