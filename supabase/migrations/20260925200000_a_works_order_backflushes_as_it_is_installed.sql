set lock_timeout = '30s';

-- =============================================================================
-- 20260925200000  A works order backflushes as it is installed
-- -----------------------------------------------------------------------------
-- PR8, M5 of docs/spec/simplification-review.md: backflush as the installed
-- default.
--
-- ── WHAT THE SPEC SAID, AND WHAT IS TRUE ─────────────────────────────────────
--
--   The spec says the installer promotes manual issue. Read against the built
--   database it does not, and never did: erp.configure_production() has
--   defaulted to backflush since 20260829270000, the Configuration screen's
--   install door calls it with nothing, the manufacturing pack ships
--   backflush, and so does the column. What promotes manual is the suites,
--   which ask for it to test issuing by hand; the spec read one of them.
--
--   So the default needs no change. What was missing is anything that would
--   say so if it did: every suite that installs production asks for manual,
--   so the installed default is exercised by none of them, and a change to
--   it would pass the build.
--
--   Backflush itself, exercised by no suite, turned out to have three defects
--   every organisation now meets (found on review): stock across two batches
--   or locations refused the receipt; what was issued by hand was consumed
--   again; and each receipt rounded on its own, so whole units left a
--   remainder nobody could issue.
--
-- ── WHAT CHANGES ─────────────────────────────────────────────────────────────
--
--   * erp.backflush_works_order() consumes what is due for everything taken
--     in, rounded to the component's unit, less what was issued by any means,
--     from the company's own available stock across batches and locations in
--     the item's order. A shortage names the item by its code.
--
--   * erp_test.backflush_default_suite: the installer's default, the setting's
--     and the pack's all say backflush; an organisation installed without a
--     choice promotes it; its works orders take it; finished goods taken in
--     consume their components on their own, through the ledger, with the
--     books still agreeing; and the three defects stay fixed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- B1. Backflush consumes what is due, from wherever the stock is
--
-- Found on review, and each a defect that every organisation now meets,
-- because backflush is what every one of them is installed with:
--   * it took the whole quantity from one batch in one location, so stock
--     held across two batches or two locations refused the receipt, though
--     the site held enough and release had said so;
--   * it issued each receipt's share on top of whatever had been issued by
--     hand, so an order issued by hand and then taken in consumed twice;
--   * it rounded each receipt's share on its own, so a component counted in
--     whole units was left with a remainder nobody could issue.
-- What is due is the component's requirement for everything taken in so far,
-- rounded to its unit, less what has been issued already, by any means; it is
-- taken from the company's own available stock at the site, batch by batch
-- in the item's own order (first to expire where it says so, oldest made,
-- then oldest received), until it is met.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.backflush_works_order(p_works_order_id uuid, p_completed numeric)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  wo        erp.works_order%rowtype;
  v_company uuid;
  v_custody uuid;
  r         record;
  b         record;
  v_left    numeric;
  v_take    numeric;
  v_n       integer := 0;
begin
  select * into wo from erp.works_order where tenant_id = v_tenant and id = p_works_order_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_WORKS_ORDER: %', p_works_order_id using errcode = '23503';
  end if;
  if coalesce(wo.quantity, 0) <= 0 then
    return 0;
  end if;

  -- The stock a movement of the order's company would move: its own, held by
  -- whoever keeps the site.
  select e.party_id into v_company from erp.entity e where e.id = wo.entity_id;
  v_custody := coalesce((select s.operator_party_id from erp.site s where s.id = wo.site_id), v_company);

  for r in
    select c.id, c.item_id, c.required_quantity, c.issued_quantity,
           least(coalesce(u.decimals, 6), 6) as decimals,
           i.code as item_code, i.is_batch_controlled, i.is_fefo
      from erp.works_order_component c
      join erp.item i on i.id = c.item_id
      left join erp.uom u on u.id = c.uom_id
     where c.tenant_id = v_tenant and c.works_order_id = p_works_order_id
     order by c.seq
  loop
    v_left := round(r.required_quantity * p_completed / wo.quantity, r.decimals) - r.issued_quantity;
    continue when v_left <= 0;

    for b in
      select bal.location_id, bal.batch_id, bal.quantity
        from erp.stock_balance bal
        left join erp.batch bt on bt.id = bal.batch_id
       where bal.tenant_id = v_tenant and bal.item_id = r.item_id and bal.site_id = wo.site_id
         and bal.stock_status = 'available' and bal.quantity > 0
         and bal.owner_party_id = v_company and bal.custody_party_id = v_custody
         and bal.serial_id is null and bal.container_id is null
         and (not r.is_batch_controlled or bal.batch_id is not null)
       order by case when r.is_fefo then bt.expires_on end nulls last,
                bt.manufactured_on nulls last,
                bal.first_received_at nulls last,
                bal.quantity desc
    loop
      exit when v_left <= 0;
      v_take := least(v_left, b.quantity);
      perform erp.issue_to_works_order(p_works_order_id, r.item_id, v_take, b.batch_id, b.location_id);
      v_left := v_left - v_take;
      v_n := v_n + 1;
    end loop;

    if v_left > 0 then
      raise exception 'CLOVEERP_NO_COMPONENT_STOCK: % needs % more of % than this site holds available to it',
        wo.order_number, v_left, r.item_code
        using errcode = '23514',
              hint = 'Receive or move the component to the site, or take in fewer finished goods.';
    end if;
  end loop;

  return v_n;
end;
$$;

revoke all on function erp.backflush_works_order(uuid, numeric) from public, anon;

comment on function erp.backflush_works_order(uuid, numeric) is
  'Consumes, for a backflush works order, what is due for everything taken in so far '
  '(rounded to each component''s unit) less what has been issued by any means, from the '
  'company''s own available stock at the site in the item''s batch order (20260925200000).';

do $receive$
declare
  v_sig constant text := 'erp.receive_works_order_output(uuid,numeric,text,uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  if wo.issue_method = 'backflush' then
    for r in select * from erp.works_order_component
              where tenant_id = v_tenant and works_order_id = p_works_order_id
    loop
      perform erp.issue_to_works_order(
        p_works_order_id, r.item_id,
        round(r.required_quantity * p_quantity / wo.quantity, 6),
        -- Policy-driven batch selection, which spec 5.5 asks for by name. The
        -- policy is the item's own: first-expiring-first-out where it says so,
        -- oldest received otherwise. A backflush that cannot name a batch on a
        -- batch-controlled component is a batch record with a hole in it.
        erp.select_batch_for_issue(r.item_id, wo.site_id));
    end loop;
  end if;$o$;
  v_new constant text := $n$  if wo.issue_method = 'backflush' then
    -- What is due for everything taken in, less what was issued, from
    -- wherever the stock is (20260925200000). The policy is the item's own:
    -- first-expiring-first-out where it says so, oldest otherwise.
    perform erp.backflush_works_order(p_works_order_id, wo.quantity_completed + p_quantity);
  end if;$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % backflush anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$receive$;

-- The refusal names the item by its code, not its identifier.
do $issue$
declare
  v_sig constant text := 'erp.issue_to_works_order(uuid,uuid,numeric,uuid,uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$      'CLOVEERP_NO_COMPONENT_STOCK: nothing of % is available at this site',
      p_component_item_id$o$;
  v_new constant text := $n$      'CLOVEERP_NO_COMPONENT_STOCK: nothing of % is available at this site',
      coalesce((select i.code from erp.item i where i.id = p_component_item_id), p_component_item_id::text)$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % stock anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$issue$;

create or replace function erp_test.backflush_default_suite()
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
  v_wo uuid; v_on0 numeric; v_on1 numeric;
  v_fg2 uuid; v_c2 uuid; v_c3 uuid; v_fg3 uuid; v_bom3 uuid; v_store uuid; v_wo2 uuid; v_wo3 uuid; v_wo4 uuid;
  v_err text;
begin
  -- 1. Every place the default is written says the same thing.
  return query select 'the installer, the setting and the manufacturing pack all install backflush',
    pg_get_function_arguments('erp.configure_production(erp.issue_method)'::regprocedure)
      like '%DEFAULT ''backflush''%'
    and (select ct.default_value #>> '{}' from erp_ref.config_type ct where ct.code = 'production.issue_method') = 'backflush'
    and (select pi.payload ->> 'value' from erp_ref.pack_item pi
          where pi.pack_code = 'manufacturing' and pi.object_kind = 'config'
            and pi.payload ->> 'config_type' = 'production.issue_method') = 'backflush'
    and pg_get_functiondef('public.erp_configure_production()'::regprocedure) like '%erp.configure_production()%',
    pg_get_function_arguments('erp.configure_production(erp.issue_method)'::regprocedure);

  begin
    select * into r from erp.provision_tenant(
      'zz-bfd-' || v_hex, 'Backflush default suite',
      'a@zz-bfd-' || v_hex || '.test', 'Suite Admin');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    res := public.erp_invite_principal('second@zz-bfd-' || v_hex || '.test', 'Second Admin');
    v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
    perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');
    csf := erp.configure_finance();
    csp := erp.configure_procurement(100000000);
    csi := erp.configure_inventory('average');
    -- Through the screen's own door, which asks nothing.
    csr := public.erp_configure_production();
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok);
    perform erp.approve_change_set(csf); perform erp.promote_change_set(csf);
    perform erp.approve_change_set(csp); perform erp.promote_change_set(csp);
    perform erp.approve_change_set(csi); perform erp.promote_change_set(csi);
    perform erp.approve_change_set(csr); perform erp.promote_change_set(csr);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    -- 2. Installed without a choice, it promotes backflush.
    -- Promoted, not merely fallen back to: the setting and the column both
    -- default to backflush, so an installer that wrote nothing would look
    -- the same without this (found on review).
    return query select 'production installed from the screen promotes backflush',
      erp.config_value('production.issue_method') #>> '{}' = 'backflush'
      and exists (select 1 from erp.config_object co
                   where co.tenant_id = r.tenant_id and co.config_type_code = 'production.issue_method'
                     and co.status = 'active'),
      coalesce(erp.config_value('production.issue_method') #>> '{}', 'nothing');

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
    perform erp.add_document_line(v_grn, v_comp, 100, 100, 'component');
    perform erp.transition_document(v_grn, 'post');

    -- 3. Its works orders take it.
    v_wo := erp.raise_works_order(v_fg, v_site, 10);
    perform erp.release_works_order(v_wo);
    return query select 'a works order raised there backflushes',
      (select wo.issue_method::text = 'backflush' from erp.works_order wo where wo.id = v_wo),
      (select wo.issue_method::text from erp.works_order wo where wo.id = v_wo);

    -- 4. Finished goods taken in consume their components, without anybody
    -- issuing them, and the books still agree.
    select c.quantity_on_hand into v_on0 from erp.item_cost c where c.item_id = v_comp and c.site_id = v_site;
    perform erp.receive_works_order_output(v_wo, 4, null, v_recv);
    select c.quantity_on_hand into v_on1 from erp.item_cost c where c.item_id = v_comp and c.site_id = v_site;
    begin
      perform erp.assert_inventory_reconciles();
      perform erp.assert_subledger_reconciles();
      perform erp.assert_work_in_progress_reconciles();
      v_err := 'agree';
    exception when others then v_err := left(sqlerrm, 200); end;
    return query select 'four taken in consume eight components on their own, through the ledger, and the books agree',
      v_on0 - v_on1 = 8
      and (select c.issued_quantity from erp.works_order_component c where c.works_order_id = v_wo) = 8
      and (select count(*) from erp.production_event pe
            where pe.works_order_id = v_wo and pe.event_kind = 'issued'
              and pe.detail ->> 'method' = 'backflush') = 1
      -- Eight components at a hundred in; four at the standard of 400 out.
      and erp.works_order_wip(v_wo) = 800 - 4 * 400
      and v_err = 'agree',
      format('%s consumed; the order holds %s; %s', v_on0 - v_on1, erp.works_order_wip(v_wo), v_err);

    -- 5. Stock held in two places is consumed from both (found on review:
    -- it was taken from one, and the receipt refused).
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (r.tenant_id, v_site, 'STORE', 'Store', 'bulk', 'active') returning id into v_store;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'C2', 'Second component', v_uom, 'active') returning id into v_c2;
    -- A second finished good, made of both.
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'FG2', 'Second finished good', v_uom, 'active') returning id into v_fg2;
    insert into erp.bom (tenant_id, code, item_id, site_id, version, name,
                         output_quantity, yield_factor, status, effective_from)
    values (r.tenant_id, 'FG2-1', v_fg2, v_site, 1, 'Second finished good', 1, 1, 'active', current_date - 1)
    returning id into v_bom;
    insert into erp.bom_line (tenant_id, bom_id, seq, component_item_id, quantity, uom_id, scrap_factor, is_phantom)
    values (r.tenant_id, v_bom, 10, v_comp, 2, v_uom, 0, false),
           (r.tenant_id, v_bom, 20, v_c2, 6, v_uom, 0, false);
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_c2, 100, 100, 'second component');
    perform erp.add_document_line(v_grn, v_comp, 100, 100, 'more component');
    perform erp.transition_document(v_grn, 'post');
    insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id,
                                    from_location_id, from_status, to_location_id, to_status, quantity, uom_id, reason_code)
    values (r.tenant_id, r.entity_id, v_site, 'internal_transfer', v_c2, v_recv, 'available', v_store, 'available', 55, v_uom, 'suite');
    v_wo2 := erp.raise_works_order(v_fg2, v_site, 10);
    perform erp.release_works_order(v_wo2);
    begin
      perform erp.receive_works_order_output(v_wo2, 10, null, v_recv);
      v_err := 'taken in';
    exception when others then v_err := left(sqlerrm, 200); end;
    return query select 'a component held in two locations is consumed from both, and the receipt goes through',
      v_err = 'taken in'
      and (select c.issued_quantity from erp.works_order_component c where c.works_order_id = v_wo2 and c.item_id = v_c2) = 60
      and (select count(distinct pe.id) from erp.production_event pe
            where pe.works_order_id = v_wo2 and pe.event_kind = 'issued' and pe.item_id = v_c2) = 2
      and (select sum(b.quantity) from erp.stock_balance b where b.item_id = v_c2 and b.site_id = v_site) = 40,
      v_err;

    -- 6. What was issued by hand is not consumed again (found on review: it
    -- was, and the order consumed twice).
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_c2, 100, 100, 'more second component');
    perform erp.transition_document(v_grn, 'post');
    v_wo3 := erp.raise_works_order(v_fg2, v_site, 10);
    perform erp.release_works_order(v_wo3);
    perform erp.issue_to_works_order(v_wo3, v_comp, 20);
    select sum(b.quantity) into v_on0 from erp.stock_balance b where b.item_id = v_comp and b.site_id = v_site;
    perform erp.receive_works_order_output(v_wo3, 10, null, v_recv);
    select sum(b.quantity) into v_on1 from erp.stock_balance b where b.item_id = v_comp and b.site_id = v_site;
    return query select 'a component issued by hand is not backflushed again',
      v_on0 = v_on1
      and (select c.issued_quantity from erp.works_order_component c where c.works_order_id = v_wo3 and c.item_id = v_comp) = 20
      and (select c.issued_quantity from erp.works_order_component c where c.works_order_id = v_wo3 and c.item_id = v_c2) = 60,
      format('%s more consumed', v_on0 - v_on1);

    -- 7. Three receipts of one consume the whole ten, in whole units (found
    -- on review: 9.999999 went, and a millionth of a unit stayed).
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'FG3', 'Made in threes', v_uom, 'active') returning id into v_fg3;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'C3', 'Ten to three', v_uom, 'active') returning id into v_c3;
    insert into erp.bom (tenant_id, code, item_id, site_id, version, name,
                         output_quantity, yield_factor, status, effective_from)
    values (r.tenant_id, 'FG3-1', v_fg3, v_site, 1, 'Made in threes', 3, 1, 'active', current_date - 1)
    returning id into v_bom3;
    insert into erp.bom_line (tenant_id, bom_id, seq, component_item_id, quantity, uom_id, scrap_factor, is_phantom)
    values (r.tenant_id, v_bom3, 10, v_c3, 10, v_uom, 0, false);
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_c3, 20, 100, 'ten to three');
    perform erp.transition_document(v_grn, 'post');
    v_wo4 := erp.raise_works_order(v_fg3, v_site, 3);
    perform erp.release_works_order(v_wo4);
    perform erp.receive_works_order_output(v_wo4, 1, null, v_recv);
    perform erp.receive_works_order_output(v_wo4, 1, null, v_recv);
    perform erp.receive_works_order_output(v_wo4, 1, null, v_recv);
    return query select 'three receipts of one against ten to three consume the ten in whole units',
      (select c.issued_quantity from erp.works_order_component c where c.works_order_id = v_wo4) = 10
      and (select sum(b.quantity) from erp.stock_balance b where b.item_id = v_c3 and b.site_id = v_site) = 10
      and not exists (select 1 from erp.stock_movement m
                       where m.works_order_id = v_wo4 and m.movement_type = 'production_issue'
                         and m.quantity <> trunc(m.quantity)),
      (select string_agg(m.quantity::text, ', ' order by m.id) from erp.stock_movement m
        where m.works_order_id = v_wo4 and m.movement_type = 'production_issue');

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
  passed := not exists (select 1 from erp.tenant t where t.code = 'zz-bfd-' || v_hex);
  detail := 'the organisation and its orders rolled back';
  return next;
end;
$function$;

revoke all on function erp_test.backflush_default_suite() from public, anon;

create or replace function erp_test.assert_backflush_default_suite()
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
    from erp_test.backflush_default_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_BACKFLUSH_DEFAULT_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'Production installed without a choice no longer backflushes, or backflushing no longer consumes through the ledger. Read the case.';
  end if;
  if v_total <> 8 then
    raise exception 'CLOVEERP_BACKFLUSH_DEFAULT_SUITE_SHRANK: % case(s), expected 8', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
end;
$$;

revoke all on function erp_test.assert_backflush_default_suite() from public, anon;

comment on function erp_test.assert_backflush_default_suite() is
  'Production installed without a choice backflushes: the installer, the setting and the '
  'manufacturing pack say so, its works orders take it, and finished goods taken in '
  'consume their components through the ledger (20260925200000).';

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
