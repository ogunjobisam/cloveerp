set lock_timeout = '30s';

-- =============================================================================
-- 20260920250000  Stock costed first in, first out has a unit cost
-- -----------------------------------------------------------------------------
-- 20260920175000 wrote down the mirror image of the empty ageing and did not fix
-- it. erp.item_cost is filled only for stock costed at average or at standard
-- cost: erp.receive_cost(), erp.issue_cost() and erp.transfer_cost() all return
-- from their layer branch before they touch it. Eight routines and one view
-- read a unit cost from it and from nothing else, so for a product costed
-- first in, first out every one of them read nought, or nothing:
--
--   erp.post_count, erp.post_stock_adjustment
--       stock found was layered at a unit cost of nought, so the movement cost
--       nothing and erp.post_movement_finance() posted nothing. The stock went
--       up and the inventory account did not. Money wrong, so first.
--   erp.check_margin
--       no cost row, so every price failed as one that "cannot be checked".
--   erp.expiry_horizon_report
--       expiring stock valued at nothing.
--   erp.calculate_policy
--       no cost, so no economic order quantity.
--   erp.release_works_order, erp.roll_up_standard_cost, erp.works_order_variance
--       components, bought items and the yield priced at nought.
--   view erp.stock_valuation, behind the "Stock on hand and valuation" report
--       version: positions valued at nought.
--
-- All nine were in erp.conditional_store_allowance() as KNOWN GAPS. They leave
-- it here, and erp_test.conditional_store_suite()'s pinned count of them goes
-- from nine to none.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- What one unit is worth, and why that figure
--
-- One rule, in one place: erp.unit_cost_at(product, site).
--
--   Average or standard   the unit cost erp.item_cost holds, exactly what all
--                         eight routines read until today. Nothing changes
--                         for stock costed either way.
--   First in, first out   what the open layers at the site hold divided by
--                         what remains in them: round(sum(remaining × cost) /
--                         sum(remaining)). That is the unit cost
--                         erp.stock_valuation_report() shows for the position,
--                         so the Stock screen, the margin check and a count
--                         all say the same thing a unit is worth.
--                         With nothing open, the cost of the latest layer
--                         received there: the last price actually paid at that
--                         site is the best evidence left of what one costs.
--   Nothing ever costed   null, as for a product at average cost that has
--                         never had a valued receipt. The callers do with it
--                         what they did with a missing row.
--
-- Why the valuation's figure and not the latest layer for a gain. The adjustment
-- routine already says stock found "arrives at what the books already say a
-- unit of it is worth", and under average cost that is what happens: the gain
-- goes in at the average, and the position's unit cost does not move. Valuing a
-- first-in-first-out gain at the open layers' figure is the same rule, so the
-- position's unit cost does not move under that method either, and a count
-- that finds five units adds exactly what the valuation says five units are
-- worth. The latest layer is used only when nothing is open to take a figure
-- from.
--
-- Why not the next layer out for the margin check, which is what the next sale
-- would actually be costed at. The check is asked about a price, not a sale of
-- a quantity, so it cannot know how many layers the sale would reach; and a
-- margin measured against the oldest layer would jump each time one ran out,
-- with nothing about the product having changed.
--
-- The view values a position from the open layers only, with no fallback,
-- because it is a valuation: it values what is on the books, as
-- erp.stock_valuation_report() does, and the two agree.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- How
--
-- Each routine is patched where it reads the unit cost and nowhere else, by
-- guarded replacement of its deployed body: post_count and
-- post_stock_adjustment have been rewritten in place before (20260914070000,
-- 20260920110000), and restating any of these whole would carry a body this
-- migration has not read. Each needle must occur exactly once or nothing is
-- changed. The view is restated with the same columns.
--
-- Left as it was, on purpose: stock found for a product never costed at the
-- site still goes in at nought, under every method. That is not this class —
-- average cost does the same with no row — and refusing it would change what
-- average and standard do too.
--
-- Proof: erp_test.fifo_is_costed_from_its_layers_suite() (12 cases, pinned),
-- a product costed first in, first out through every one of the nine; the
-- census; and the suites that already read these routines.
-- =============================================================================


-- ═════════════════════════════════════════════════════════════════════════════
-- 1. What one unit of a product at a site is worth
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.unit_cost_at(p_item_id uuid, p_site_id uuid)
returns bigint
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_cost   bigint;
begin
  if erp.costing_method_for(p_item_id, p_site_id) <> 'fifo' then
    -- Average and standard keep one running figure per product and site.
    select c.unit_cost_minor into v_cost
      from erp.item_cost c
     where c.tenant_id = v_tenant and c.item_id = p_item_id
       and c.site_id is not distinct from p_site_id;
    return v_cost;
  end if;

  -- First in, first out: the open layers, weighted by what remains in each,
  -- which is the unit cost the valuation shows for the position.
  select round(sum(l.remaining * l.unit_cost_minor) / nullif(sum(l.remaining), 0))::bigint
    into v_cost
    from erp.stock_valuation_layer l
   where l.tenant_id = v_tenant and l.item_id = p_item_id
     and l.site_id is not distinct from p_site_id
     and l.remaining > 0;

  if v_cost is null then
    -- Nothing open: the last price paid here.
    select l.unit_cost_minor into v_cost
      from erp.stock_valuation_layer l
     where l.tenant_id = v_tenant and l.item_id = p_item_id
       and l.site_id is not distinct from p_site_id
     order by l.received_at desc, l.id desc
     limit 1;
  end if;

  return v_cost;
end;
$$;

revoke all on function erp.unit_cost_at(uuid, uuid) from public, anon;

comment on function erp.unit_cost_at(uuid, uuid) is
  'What one unit of a product at a site is worth now, under whichever method '
  'costs it. Average or standard: the running unit cost. First in, first out: '
  'the open layers there weighted by what remains in each, as the stock '
  'valuation prices the position; with nothing open, the latest layer received '
  'there. Null when nothing has ever been costed there. The one figure a '
  'count, an adjustment, the margin check, the expiry horizon, planning and '
  'production read (20260920250000).';


-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The eight routines read it
--
-- One row per place a unit cost is read: works_order_variance reads it twice,
-- for the material standard and for the yield. Every needle is the deployed
-- text and must occur exactly once in the body it patches.
-- ═════════════════════════════════════════════════════════════════════════════

do $patch$
declare
  p      record;
  v_def  text;
  v_hits integer;
begin
  for p in
    select x.seq, x.sig, x.needle, x.replacement
      from (values
        (1, 'erp.post_count(uuid)',
$n$                  coalesce((select c.unit_cost_minor from erp.item_cost c
                             where c.tenant_id = v_tenant and c.item_id = t.item_id
                               and c.site_id is not distinct from t.site_id), 0),
$n$,
$r$                  -- What a unit is worth under whichever method costs it (20260920250000).
                  coalesce(erp.unit_cost_at(t.item_id, t.site_id), 0),
$r$),
        (2, 'erp.post_stock_adjustment(uuid)',
$n$                  coalesce((select c.unit_cost_minor from erp.item_cost c
                             where c.tenant_id = v_tenant and c.item_id = ln.item_id
                               and c.site_id is not distinct from d.site_id), 0),
$n$,
$r$                  -- What a unit is worth under whichever method costs it (20260920250000).
                  coalesce(erp.unit_cost_at(ln.item_id, d.site_id), 0),
$r$),
        (3, 'erp.check_margin(uuid,uuid,bigint,text)',
$n$  select c.unit_cost_minor into cost_minor
    from erp.item_cost c
   where c.tenant_id = v_tenant and c.item_id = p_item_id
     and c.site_id is not distinct from p_site_id;
$n$,
$r$  -- What a unit is worth under whichever method costs it (20260920250000).
  cost_minor := erp.unit_cost_at(p_item_id, p_site_id);
$r$),
        (4, 'erp.expiry_horizon_report(integer)',
$n$         round(sum(sb.quantity) * coalesce(
           (select c.unit_cost_minor from erp.item_cost c
             where c.tenant_id = b.tenant_id and c.item_id = b.item_id
               and c.site_id is not distinct from sb.site_id), 0))::bigint,
$n$,
$r$         round(sum(sb.quantity) * coalesce(erp.unit_cost_at(b.item_id, sb.site_id), 0))::bigint,
$r$),
        (5, 'erp.calculate_policy(uuid,uuid,bigint,numeric)',
$n$  select c.unit_cost_minor into v_cost from erp.item_cost c
   where c.tenant_id = v_tenant and c.item_id = p_item_id
     and c.site_id is not distinct from p_site_id;
$n$,
$r$  -- What a unit is worth under whichever method costs it (20260920250000).
  v_cost := erp.unit_cost_at(p_item_id, p_site_id);
$r$),
        (6, 'erp.release_works_order(uuid,boolean)',
$n$    select c.unit_cost_minor into v_cost from erp.item_cost c
     where c.tenant_id = v_tenant and c.item_id = r.item_id
       and c.site_id is not distinct from wo.site_id;
$n$,
$r$    v_cost := erp.unit_cost_at(r.item_id, wo.site_id);
$r$),
        (7, 'erp.roll_up_standard_cost(uuid,uuid,integer)',
$n$    select c.unit_cost_minor into v_cost from erp.item_cost c
     where c.tenant_id = v_tenant and c.item_id = p_item_id
       and c.site_id is not distinct from p_site_id;
$n$,
$r$    v_cost := erp.unit_cost_at(p_item_id, p_site_id);
$r$),
        (8, 'erp.works_order_variance(uuid)',
$n$             * coalesce((select ic.unit_cost_minor from erp.item_cost ic
                          where ic.tenant_id = c.tenant_id and ic.item_id = c.item_id
                            and ic.site_id is not distinct from wo.site_id), 0))), 0)::bigint as amt
$n$,
$r$             * coalesce(erp.unit_cost_at(c.item_id, wo.site_id), 0))), 0)::bigint as amt
$r$),
        (9, 'erp.works_order_variance(uuid)',
$n$         round(coalesce((select ic.unit_cost_minor from erp.item_cost ic, wo
                          where ic.tenant_id = wo.tenant_id and ic.item_id = wo.item_id
                            and ic.site_id is not distinct from wo.site_id), 0)
$n$,
$r$         round(coalesce((select erp.unit_cost_at(wo.item_id, wo.site_id) from wo), 0)
$r$)
      ) as x(seq, sig, needle, replacement)
     order by x.seq
  loop
    v_def := pg_get_functiondef(p.sig::regprocedure);
    v_hits := (length(v_def) - length(replace(v_def, p.needle, ''))) / length(p.needle);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % reads the unit cost % time(s) in the text 20260920250000 patches, where it expects once (place %)',
        p.sig, v_hits, p.seq
        using hint = 'A later migration changed how it reads the unit cost. Read pg_get_functiondef() of it and re-anchor this patch on that body.';
    end if;
    execute replace(v_def, p.needle, p.replacement);
  end loop;
end
$patch$;


-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The view behind the Stock on hand and valuation report version
--
-- The same columns, in the same order and of the same types. A position costed
-- first in, first out takes its unit cost from the open layers at its site,
-- the valuation's own rule; every other position reads what it read before.
-- ═════════════════════════════════════════════════════════════════════════════

create or replace view erp.stock_valuation with (security_invoker = true) as
select sp.tenant_id, sp.site_id, sp.location_id, sp.item_id,
       it.code as item_code, it.name as item_name,
       sp.batch_id, sp.serial_id, sp.container_id, sp.stock_status, sp.quantity,
       (case when cm.method = 'fifo' then cm.method else ic.method end)::erp.costing_method as method,
       (case when cm.method = 'fifo' then fl.unit_cost_minor else ic.unit_cost_minor end)::bigint as unit_cost_minor,
       (case when cm.method = 'fifo' then fl.currency else ic.currency end)::char(3) as currency,
       case when sp.owner_party_id = erp.entity_party_for_site(sp.site_id)
            then (sp.quantity * coalesce(case when cm.method = 'fifo' then fl.unit_cost_minor
                                               else ic.unit_cost_minor end, 0))::bigint
            else 0::bigint end as value_minor,
       sp.owner_party_id, sp.custody_party_id,
       (sp.owner_party_id = erp.entity_party_for_site(sp.site_id)) as is_owned
  from erp.stock_position sp
  join erp.item it on it.tenant_id = sp.tenant_id and it.id = sp.item_id
  cross join lateral (
    select erp.costing_method_for(sp.item_id, sp.site_id) as method) cm
  left join lateral (
    select c.method, c.unit_cost_minor, c.currency
      from erp.item_cost c
     where cm.method <> 'fifo'
       and c.tenant_id = sp.tenant_id and c.item_id = sp.item_id
       and (c.site_id = sp.site_id or c.site_id is null)
     order by (c.site_id is not null) desc, c.effective_from desc
     limit 1) ic on true
  left join lateral (
    select round(sum(l.remaining * l.unit_cost_minor) / nullif(sum(l.remaining), 0))::bigint as unit_cost_minor,
           max(l.currency) as currency
      from erp.stock_valuation_layer l
     where cm.method = 'fifo'
       and l.tenant_id = sp.tenant_id and l.item_id = sp.item_id
       and l.site_id is not distinct from sp.site_id
       and l.remaining > 0) fl on true;

comment on view erp.stock_valuation is
  'Every stock position with its owner and keeper and the cost that applies '
  'to it; valued only when the company owns it. Stock costed first in, first '
  'out is priced from its open layers at the site, as the stock valuation '
  'prices it (20260920250000). Behind the Stock on hand and valuation report.';


-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The known gaps leave the allowance
--
-- What is left is the one reader that serves only what fills the store. The
-- census suite pinned nine known gaps; it now pins none.
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.conditional_store_allowance()
returns table (reader text, store text, known_gap boolean, rationale text)
language sql
immutable
set search_path = ''
as $$
  select v.reader, v.store, v.known_gap, v.rationale
    from (values
      ('erp.set_standard_cost'::text, 'erp.item_cost'::text, false,
       'By design. It sets the standard for a product costed at standard and '
       'refuses any other, and a product costed at standard always has its row '
       'here.'::text)
    ) as v(reader, store, known_gap, rationale);
$$;

revoke all on function erp.conditional_store_allowance() from public, anon;

do $pin$
declare
  v_sig text := 'erp_test.conditional_store_suite()';
  v_def text := pg_get_functiondef('erp_test.conditional_store_suite()'::regprocedure);
  v_n   text := $n$and v_gaps = 9 and v_verdict = 'answers otherwise'$n$;
  v_r   text := $r$and v_gaps = 0 and v_verdict = 'answers otherwise'$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % does not pin nine known gaps the way 20260920175000 wrote it', v_sig
      using hint = 'A later migration changed the census case. Read pg_get_functiondef() of it and pin the known gaps there.';
  end if;
  execute replace(v_def, v_n, v_r);
end
$pin$;

comment on function erp_test.conditional_store_suite() is
  'The conditional-store check, proved and falsified. The product as it stands '
  'passes with no known gaps written down (nine until 20260920250000 gave '
  'stock costed first in, first out a unit cost); the stock ageing and the '
  'slow-moving provision as they read until 20260920175000 are both refused by '
  'name; a routine that also reads the movement ledger is accepted; a view '
  'that reads only unit costs is refused from the catalogue; an allowance for '
  'a routine that is gone and a register row for a store that does not exist '
  'are refused. Rolls back everything it built.';


-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Proof: a product costed first in, first out, through all nine
--
-- One depot. F is costed first in, first out and received twice, ten at 400
-- and ten at 600, so its open layers are worth 500 a unit. G was received at
-- 300 then 700 and has sold out. H was never received. A is at the
-- organisation's own method, average, received at 450. E is a batch that
-- expires in ten days, four at 250. Q is received at 500 and has sold ten.
-- P is made of two F and has one layer of its own at 1,200. Every figure is
-- worked out by hand in the case that asserts it.
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.fifo_is_costed_from_its_layers_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $suite$
declare
  c_expected constant integer := 12;
  v_cases   integer := 0;
  v_tag     text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1        uuid := gen_random_uuid();
  v_step    text := 'before the fixture started';
  v_state   text;
  v_msg     text;
  v_tenant  uuid; v_admin uuid; v_token text;
  v_entity  uuid; v_ccy char(3); v_uom uuid;
  v_site    uuid; v_loc uuid;
  v_f uuid; v_g uuid; v_h uuid; v_a uuid; v_e uuid; v_q uuid; v_p uuid;
  v_batch   uuid; v_task uuid; v_doc uuid; v_wo uuid; v_bom uuid;
  v_res     jsonb;
  v_n       integer; v_m integer;
  v_old     bigint; v_unit bigint; v_cost bigint; v_other bigint;
  v_before  bigint; v_after bigint;
  v_qty     numeric; v_value bigint;
  v_got     text;
  mg        record; mg2 record; pol record;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    v_step := 'provisioning the organisation';
    perform set_config('request.jwt.claims', '', true);
    select t.tenant_id, t.admin_user_id, t.admin_token
      into v_tenant, v_admin, v_token
      from erp.provision_tenant('zz-fifo-' || v_tag, 'FIFO cost suite',
                                'admin@zz-fifo-' || v_tag || '.test', 'FIFO Admin') t;
    update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zz-fifo-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(v_token);
    -- Average cost, as the demonstration is. The products below that are
    -- costed first in, first out say so on their own policy.
    perform erp.ensure_demo_configuration(v_tenant, v_admin);

    select l.entity_id, l.currency into v_entity, v_ccy
      from erp.ledger l where l.tenant_id = v_tenant and l.is_primary order by l.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = v_tenant order by u.code limit 1;

    v_step := 'a depot and the products';
    v_site := erp.create_site('ZZ-FIFO', 'FIFO cost depot', 'warehouse', v_entity);
    insert into erp.location (tenant_id, site_id, code, name, location_type, is_pickable, status)
    values (v_tenant, v_site, 'ZZ-FIFO-BULK', 'FIFO cost bulk', 'bulk'::erp.location_type,
            true, 'active'::erp.record_status)
    returning id into v_loc;

    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (v_tenant, 'ZZ-FIFO-F', 'Costed first in, first out', v_uom, 'active'::erp.record_status)
    returning id into v_f;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (v_tenant, 'ZZ-FIFO-G', 'Costed in layers, sold out', v_uom, 'active'::erp.record_status)
    returning id into v_g;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (v_tenant, 'ZZ-FIFO-H', 'Costed in layers, never received', v_uom, 'active'::erp.record_status)
    returning id into v_h;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (v_tenant, 'ZZ-FIFO-A', 'Costed at average', v_uom, 'active'::erp.record_status)
    returning id into v_a;

    insert into erp.costing_policy (tenant_id, code, name, method, item_id, status)
    select v_tenant, 'zz_fifo_' || lower(x.code), 'FIFO cost suite, ' || x.code,
           'fifo'::erp.costing_method, x.id, 'active'::erp.record_status
      from (values ('F', v_f), ('G', v_g), ('H', v_h)) as x(code, id);

    v_step := 'receiving F twice, G twice and selling G out, and A once';
    perform erp.receive_cost(v_f, v_site, 10, 400, v_ccy);
    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id, to_location_id, to_status,
      quantity, uom_id, unit_cost_minor, currency, reason_code)
    values (v_tenant, v_entity, v_site, 'receipt_no_order', v_f, v_loc,
            'available'::erp.stock_status, 10, v_uom, 400, v_ccy, 'OPENING');
    perform erp.receive_cost(v_f, v_site, 10, 600, v_ccy);
    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id, to_location_id, to_status,
      quantity, uom_id, unit_cost_minor, currency, reason_code)
    values (v_tenant, v_entity, v_site, 'receipt_no_order', v_f, v_loc,
            'available'::erp.stock_status, 10, v_uom, 600, v_ccy, 'OPENING');

    -- G's layers only: the unit cost reads layers, not the shelf.
    perform erp.receive_cost(v_g, v_site, 5, 300, v_ccy);
    perform erp.receive_cost(v_g, v_site, 5, 700, v_ccy);
    perform erp.issue_cost(v_g, v_site, 10);

    perform erp.receive_cost(v_a, v_site, 10, 450, v_ccy);

    -- ── 1. The store is empty, and the one rule answers ─────────────────────
    v_step := 'reading the unit cost the old way and the new';
    select count(*) into v_n
      from erp.item_cost c
     where c.tenant_id = v_tenant and c.item_id in (v_f, v_g, v_h);
    -- Exactly what the eight routines read until today.
    v_old := coalesce((select c.unit_cost_minor from erp.item_cost c
                        where c.tenant_id = v_tenant and c.item_id = v_f
                          and c.site_id is not distinct from v_site), 0);
    v_got := format('%s, %s, %s, %s',
                    coalesce(erp.unit_cost_at(v_f, v_site)::text, 'none'),
                    coalesce(erp.unit_cost_at(v_g, v_site)::text, 'none'),
                    coalesce(erp.unit_cost_at(v_h, v_site)::text, 'none'),
                    coalesce(erp.unit_cost_at(v_a, v_site)::text, 'none'));

    v_cases := v_cases + 1;
    case_name := 'stock costed first in, first out has no unit cost row, which the nine read as nought; the open layers weighted, the latest layer when none is open, nothing when nothing was received, and average unchanged';
    passed := coalesce(v_n = 0 and v_old = 0 and v_got = '500, 700, none, 450', false);
    detail := format('%s unit cost row(s) for the three in layers, read as %s; F, G, H, A now %s',
                     v_n, v_old, v_got);
    return next;

    -- ── 2. A count that finds stock ─────────────────────────────────────────
    -- Twenty on the shelf, twenty-two counted. The two go in at 500, which is
    -- 1,000 onto the inventory account; until today they went in at nought and
    -- nothing was posted.
    v_step := 'counting F and finding two more';
    insert into erp.count_programme (tenant_id, code, name, site_id, kind, selector,
                                     tolerance_absolute, tolerance_pct, status)
    values (v_tenant, 'zz_fifo_count', 'FIFO cost suite count', v_site, 'cycle', 'true'::jsonb,
            5, 100, 'active');
    perform erp.raise_count_tasks('zz_fifo_count');
    select t.id into v_task from erp.count_task t
     where t.tenant_id = v_tenant and t.item_id = v_f and t.status = 'open';
    select coalesce(sum(jl.debit_minor - jl.credit_minor), 0)::bigint into v_before
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
     where j.tenant_id = v_tenant and j.status = 'posted'
       and j.source_code = 'stock.adjusted' and jl.line_no = 1;
    v_got := erp.record_count(v_task, 22)::text;
    perform erp.post_count(v_task);
    select m.unit_cost_minor, m.cost_minor into v_unit, v_cost
      from erp.stock_movement m
     where m.tenant_id = v_tenant and m.item_id = v_f
       and m.movement_type = 'count_adjustment' and m.document_id is null;
    select coalesce(sum(jl.debit_minor - jl.credit_minor), 0)::bigint into v_after
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
     where j.tenant_id = v_tenant and j.status = 'posted'
       and j.source_code = 'stock.adjusted' and jl.line_no = 1;
    select count(*) into v_n
      from erp.stock_valuation_layer l
     where l.tenant_id = v_tenant and l.item_id = v_f and l.quantity = 2 and l.unit_cost_minor = 500;

    v_cases := v_cases + 1;
    case_name := 'a count that finds stock costed first in, first out layers it at what the books say a unit is worth, and the inventory account goes up by it';
    passed := coalesce(v_got = 'approved' and v_unit = 500 and v_cost = 1000
                       and v_after - v_before = 1000 and v_n = 1, false);
    detail := format('count %s; movement at %s costing %s; inventory up %s; %s layer(s) of two at 500',
                     v_got, v_unit, v_cost, v_after - v_before, v_n);
    return next;

    -- ── 3. An adjustment that finds stock ───────────────────────────────────
    -- Four more at 500 is 2,000. The layers are now 10 at 400, 10 at 600, 2 at
    -- 500 and 4 at 500: 13,000 over 26, still 500 a unit.
    v_step := 'an adjustment that finds four of F';
    v_before := v_after;
    v_res := erp.raise_stock_adjustment(
               v_site, 'FOUND',
               jsonb_build_array(jsonb_build_object(
                 'item_id', v_f, 'quantity', 4, 'location_id', v_loc)),
               null, 'Four turned up behind the racking', 'ZZ-FIFO-' || v_tag);
    v_doc := (v_res ->> 'document_id')::uuid;
    perform erp.transition_document(v_doc, 'approve', 'suite');
    v_res := erp.post_stock_adjustment(v_doc);
    select m.unit_cost_minor, m.cost_minor into v_unit, v_cost
      from erp.stock_movement m
     where m.tenant_id = v_tenant and m.document_id = v_doc;
    select coalesce(sum(jl.debit_minor - jl.credit_minor), 0)::bigint into v_after
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
     where j.tenant_id = v_tenant and j.status = 'posted'
       and j.source_code = 'stock.adjusted' and jl.line_no = 1;

    v_cases := v_cases + 1;
    case_name := 'an adjustment that finds stock costed first in, first out values it the same way and raises its journal';
    passed := coalesce(v_unit = 500 and v_cost = 2000 and v_after - v_before = 2000
                       and (v_res ->> 'cost_minor')::bigint = -2000
                       and (v_res ->> 'journals')::integer = 1
                       and erp.unit_cost_at(v_f, v_site) = 500, false);
    detail := format('movement at %s costing %s; inventory up %s; the adjustment says %s through %s journal(s); F now %s a unit',
                     v_unit, v_cost, v_after - v_before, v_res ->> 'cost_minor',
                     v_res ->> 'journals', erp.unit_cost_at(v_f, v_site));
    return next;

    -- ── 4. The margin check measures it ─────────────────────────────────────
    -- A floor of thirty per cent. 800 against 500 is 37.5 per cent, inside it;
    -- 600 against 500 is 16.667, under it. A, at average, is measured at 450.
    v_step := 'checking margins';
    insert into erp.pricing_policy (tenant_id, code, name, min_margin_pct, allow_below_cost, status)
    values (v_tenant, 'zz_fifo_margin', 'FIFO cost suite floor', 30, false, 'active'::erp.record_status);
    select * into mg from erp.check_margin(v_f, v_site, 800, 'zz_fifo_margin');
    select * into mg2 from erp.check_margin(v_f, v_site, 600, 'zz_fifo_margin');
    select c.cost_minor into v_other from erp.check_margin(v_a, v_site, 800, 'zz_fifo_margin') c;

    v_cases := v_cases + 1;
    case_name := 'the margin check measures a price for stock costed first in, first out against its layers, where it could not measure one at all';
    passed := coalesce(mg.cost_minor = 500 and mg.margin_pct = 37.5 and mg.within_policy
                       and mg2.cost_minor = 500 and not mg2.within_policy
                       and mg2.message like 'margin 16.667 per cent is under the floor%'
                       and v_other = 450, false);
    detail := format('800: cost %s, %s per cent, %s (%s); 600: %s (%s); A at %s',
                     mg.cost_minor, mg.margin_pct, mg.within_policy, mg.message,
                     mg2.within_policy, mg2.message, v_other);
    return next;

    -- ── 5. The expiry horizon values it ─────────────────────────────────────
    v_step := 'a batch of E that expires in ten days';
    insert into erp.item (tenant_id, code, name, stock_uom_id, is_batch_controlled, status)
    values (v_tenant, 'ZZ-FIFO-E', 'Costed in layers, expiring', v_uom, true, 'active'::erp.record_status)
    returning id into v_e;
    insert into erp.costing_policy (tenant_id, code, name, method, item_id, status)
    values (v_tenant, 'zz_fifo_e', 'FIFO cost suite, E', 'fifo'::erp.costing_method, v_e,
            'active'::erp.record_status);
    insert into erp.batch (tenant_id, item_id, batch_number, status, manufactured_on, expires_on)
    values (v_tenant, v_e, 'ZZ-FIFO-E-1', 'released', current_date - 20, current_date + 10)
    returning id into v_batch;
    perform erp.receive_cost(v_e, v_site, 4, 250, v_ccy, v_batch);
    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id, batch_id, to_location_id, to_status,
      quantity, uom_id, unit_cost_minor, currency, reason_code)
    values (v_tenant, v_entity, v_site, 'receipt_no_order', v_e, v_batch, v_loc,
            'available'::erp.stock_status, 4, v_uom, 250, v_ccy, 'OPENING');
    select e.quantity, e.value_minor into v_qty, v_value
      from erp.expiry_horizon_report(30) e where e.batch_id = v_batch;

    v_cases := v_cases + 1;
    case_name := 'the expiry horizon values expiring stock costed first in, first out at its layers, where it valued it at nothing';
    passed := coalesce(v_qty = 4 and v_value = 1000, false);
    detail := format('%s expiring, valued at %s', coalesce(v_qty::text, 'nothing'),
                     coalesce(v_value::text, 'nothing'));
    return next;

    -- ── 6. Planning can order it ─────────────────────────────────────────────
    -- Ten sold forty days ago and nothing else in two years: a mean of 10/24 a
    -- month, five a year. sqrt(2 × 5 × 5,000 / (0.25 × 500)) = sqrt(400) = 20.
    v_step := 'planning Q';
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (v_tenant, 'ZZ-FIFO-Q', 'Costed in layers, planned', v_uom, 'active'::erp.record_status)
    returning id into v_q;
    insert into erp.costing_policy (tenant_id, code, name, method, item_id, status)
    values (v_tenant, 'zz_fifo_q', 'FIFO cost suite, Q', 'fifo'::erp.costing_method, v_q,
            'active'::erp.record_status);
    perform erp.receive_cost(v_q, v_site, 30, 500, v_ccy);
    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id, to_location_id, to_status,
      quantity, uom_id, unit_cost_minor, currency, reason_code, occurred_at)
    values (v_tenant, v_entity, v_site, 'receipt_no_order', v_q, v_loc,
            'available'::erp.stock_status, 30, v_uom, 500, v_ccy, 'OPENING',
            now() - interval '90 days');
    perform erp.issue_cost(v_q, v_site, 10);
    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id, from_location_id, from_status,
      quantity, uom_id, unit_cost_minor, currency, occurred_at)
    values (v_tenant, v_entity, v_site, 'despatch', v_q, v_loc,
            'available'::erp.stock_status, 10, v_uom, 500, v_ccy, now() - interval '40 days');
    insert into erp.item_site (tenant_id, item_id, site_id, is_stocked, planning_policy_code,
                               lead_time_days, min_order_quantity, order_multiple, status)
    values (v_tenant, v_q, v_site, true, 'standard', 30, 0, 0, 'active'::erp.record_status);
    select * into pol from erp.calculate_policy(v_q, v_site);

    v_cases := v_cases + 1;
    case_name := 'planning works out an order quantity for stock costed first in, first out, where it had no cost to work one out from';
    passed := coalesce(pol.mean_demand > 0 and pol.eoq = 20 and pol.rounded_eoq = 20, false);
    detail := format('mean demand %s a month; economic order quantity %s, rounded %s',
                     round(pol.mean_demand, 4), coalesce(pol.eoq::text, 'none'),
                     coalesce(pol.rounded_eoq::text, 'none'));
    return next;

    -- ── 7. The roll-up prices a bought component ────────────────────────────
    -- F is bought: 500. P is two of F: 1,000.
    v_step := 'rolling up P, made of two F';
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (v_tenant, 'ZZ-FIFO-P', 'Made of two F', v_uom, 'active'::erp.record_status)
    returning id into v_p;
    insert into erp.costing_policy (tenant_id, code, name, method, item_id, status)
    values (v_tenant, 'zz_fifo_p', 'FIFO cost suite, P', 'fifo'::erp.costing_method, v_p,
            'active'::erp.record_status);
    insert into erp.bom (tenant_id, code, item_id, site_id, version, name,
                         output_quantity, yield_factor, status, effective_from)
    values (v_tenant, 'ZZ-FIFO-P-1', v_p, v_site, 1, 'Two of F', 1, 1, 'active', current_date - 1)
    returning id into v_bom;
    insert into erp.bom_line (tenant_id, bom_id, seq, component_item_id, quantity,
                              uom_id, scrap_factor, is_phantom)
    values (v_tenant, v_bom, 10, v_f, 2, v_uom, 0, false);
    v_unit := erp.roll_up_standard_cost(v_f, v_site);
    v_cost := erp.roll_up_standard_cost(v_p, v_site);

    v_cases := v_cases + 1;
    case_name := 'the standard cost roll-up prices a bought component costed first in, first out at its layers, and what it is part of with it';
    passed := coalesce(v_unit = 500 and v_cost = 1000, false);
    detail := format('F rolls up to %s, P to %s', v_unit, v_cost);
    return next;

    -- ── 8. Releasing a works order freezes the right standard ───────────────
    -- Three of P need six of F: 3,000, and no routing adds nothing.
    v_step := 'raising and releasing three of P';
    perform erp.configure_production();
    -- A layer of P's own, so the yield below has something to be priced at.
    perform erp.receive_cost(v_p, v_site, 1, 1200, v_ccy);
    v_wo := erp.raise_works_order(v_p, v_site, 3);
    perform erp.release_works_order(v_wo, true);
    select wo.standard_cost_minor into v_cost from erp.works_order wo where wo.id = v_wo;
    select c.required_quantity into v_qty
      from erp.works_order_component c where c.works_order_id = v_wo and c.item_id = v_f;

    v_cases := v_cases + 1;
    case_name := 'a works order released for components costed first in, first out freezes their cost in its standard, where it froze nought';
    passed := coalesce(v_qty = 6 and v_cost = 3000, false);
    detail := format('%s of F required; standard frozen at %s', v_qty, v_cost);
    return next;

    -- ── 9. And its variance is priced ───────────────────────────────────────
    -- Nothing issued and nothing made yet: the material standard is six at 500,
    -- and the yield still to come is three of P at 1,200.
    v_step := 'reading the works order variance';
    select v.standard_minor into v_unit
      from erp.works_order_variance(v_wo) v where v.kind = 'material';
    select v.variance_minor into v_cost
      from erp.works_order_variance(v_wo) v where v.kind = 'yield';

    v_cases := v_cases + 1;
    case_name := 'the works order variance prices material and yield costed first in, first out at their layers, where it priced both at nought';
    passed := coalesce(v_unit = 3000 and v_cost = 3600, false);
    detail := format('material standard %s, yield %s', v_unit, v_cost);
    return next;

    -- ── 10. The view values it as the valuation does ────────────────────────
    v_step := 'reading the view behind the Stock on hand and valuation report';
    select count(*), count(*) filter (where s.method = 'fifo' and s.unit_cost_minor = 500 and s.is_owned),
           coalesce(sum(s.quantity), 0), coalesce(sum(s.value_minor), 0)
      into v_n, v_m, v_qty, v_value
      from erp.stock_valuation s where s.item_id = v_f;
    select v.value_minor into v_old
      from erp.stock_valuation_report() v where v.item_id = v_f and v.site_id = v_site;

    v_cases := v_cases + 1;
    case_name := 'the view behind the Stock on hand and valuation report values stock costed first in, first out as the valuation does, where it valued it at nought';
    passed := coalesce(v_n > 0 and v_m = v_n and v_qty = 26 and v_value = 13000
                       and v_old = 13000, false);
    detail := format('%s position(s), %s at 500 in layers; %s units worth %s; the valuation says %s',
                     v_n, v_m, v_qty, v_value, v_old);
    return next;

    -- ── 11. The census has nothing left to write down ───────────────────────
    v_step := 'reading the census';
    select count(*) filter (where r.verdict = 'known gap'),
           count(*) filter (where r.reader in ('erp.post_count', 'erp.post_stock_adjustment',
                                               'erp.check_margin', 'erp.expiry_horizon_report',
                                               'erp.calculate_policy', 'erp.release_works_order',
                                               'erp.roll_up_standard_cost', 'erp.works_order_variance'))
      into v_n, v_m
      from erp.conditional_store_report() r;
    select string_agg(format('%s %s', r.reader, r.verdict), '; ' order by r.reader)
      into v_got
      from erp.conditional_store_report() r
     where r.store = 'erp.item_cost'
       and r.reader in ('erp.unit_cost_at', 'erp.stock_valuation');

    v_cases := v_cases + 1;
    case_name := 'no known gap is left: the eight routines no longer read the unit costs alone, and the rule and the view read the layers as well';
    passed := coalesce(v_n = 0 and v_m = 0
                       and v_got = 'erp.stock_valuation answers otherwise; erp.unit_cost_at answers otherwise', false);
    detail := format('%s known gap(s); %s of the eight still read a conditional store; %s',
                     v_n, v_m, coalesce(v_got, 'neither the rule nor the view found'));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
      v_msg := sqlerrm;
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);

  -- ── 12. Undone ────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code = 'zz-fifo-' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1);
  detail := coalesce(v_state, 'the depot, its seven products, the count, the adjustment and the works order rolled back');
  return next;

  -- The count guard says what stopped the fixture, so the refusal this suite
  -- caught — and the step that produced it — reaches the build log.
  if v_cases <> c_expected then
    raise exception 'CLOVEERP_SUITE_SHRANK: fifo_is_costed_from_its_layers_suite ran % case(s), expected %; the fixture stopped %; the last refusal it caught was %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost'),
      coalesce(left(v_msg, 200), 'none')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$suite$;

revoke all on function erp_test.fifo_is_costed_from_its_layers_suite() from public, anon;

comment on function erp_test.fifo_is_costed_from_its_layers_suite() is
  'Stock costed first in, first out through every routine that read a unit '
  'cost from erp.item_cost alone until 20260920250000: a count and an '
  'adjustment that find stock layer it at the open layers'' figure and post '
  'it; the margin check measures against it; the expiry horizon values it; '
  'planning orders it; the roll-up, a released works order and its variance '
  'price it; the valuation view agrees with the valuation; the census has no '
  'known gap left; average cost is unchanged. Rolls back everything it made.';

create or replace function erp_test.assert_fifo_is_costed_from_its_layers_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $wrap$
declare
  c_expected constant integer := 12;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _fifo_is_costed_from_its_layers on commit drop as
    select * from erp_test.fifo_is_costed_from_its_layers_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _fifo_is_costed_from_its_layers;
  drop table _fifo_is_costed_from_its_layers;
  if v_fail > 0 then
    raise exception E'CLOVEERP_FIFO_UNIT_COST_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_SUITE_SHRANK: fifo_is_costed_from_its_layers_suite ran % case(s), expected %',
      v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('stock costed first in, first out has a unit cost: %s/%s cases passed', v_all, v_all);
end;
$wrap$;

revoke all on function erp_test.assert_fifo_is_costed_from_its_layers_suite() from public, anon;


-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

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
select erp.assert_invoker_doors_executable();
select erp.assert_no_caller_reachable_internals();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_governed_views_are_safe();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_part5_coverage();

-- The census, with its known gaps gone, and the suite that pins them.
select erp.assert_conditional_stores_answer_otherwise();
select erp_test.assert_conditional_store_suite();

-- Stock costed first in, first out, through all nine.
select erp_test.assert_fifo_is_costed_from_its_layers_suite();

-- The suites that already count, adjust and value stock, and which recent
-- migrations have run at their end.
select erp_test.assert_inventory_suite();
select erp_test.assert_stock_adjustment_suite();
select erp_test.assert_stock_ageing_by_costing_suite();
select erp_test.assert_stock_site_filter_suite();
