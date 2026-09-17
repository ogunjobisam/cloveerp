set lock_timeout = '30s';

-- =============================================================================
-- 20260918100000  The demonstration moves stock between two sites
-- -----------------------------------------------------------------------------
-- The Definition of Done's master gate asks for a seeded trading month that
-- holds, among other things, an inter-site transfer. 20260917130000 built the
-- mechanism: a transfer order raised, approved, loaded and booked in, the value
-- crossing at cost with no journal. The demonstration still could not use it.
-- erp.ensure_demo_configuration() gives the company ONE site, MAIN-WH, and a
-- company with one warehouse has nowhere to send a lorry. So the month the
-- build seeds held no transfer, and nothing said so.
--
-- ── 1. A SECOND SITE ─────────────────────────────────────────────────────────
--
-- NORTH-DC, the Northern distribution centre: the same company, a goods-in
-- place, a bulk store and a despatch bay. Two things about it are deliberate.
--
--   Its code sorts after MAIN-WH (and after BHM-WH, the warehouse
--   erp.seed_demo() gives its own organisations). Everything that looks for
--   "the" warehouse of a demonstration takes the first by code:
--   erp.seed_demo_history() does, erp.seed_demo_operations() does, and so do
--   the thirty-odd suites that configure a demonstration and then pick their
--   site with "order by s.code limit 1". Each of those was read before this
--   was written; every one still finds the main warehouse, and every location
--   any of them picks is filtered by that site.
--
--   It is a distribution centre, not a warehouse. The suites that pick with
--   site_type = 'warehouse' do not see it at all.
--
-- It is added only where the company has no second place to keep stock
-- already, so a demonstration somebody has shaped keeps its shape, and a
-- second call installs nothing. Its locations carry their own codes, so a list
-- of every place the company keeps stock does not show two called RECV.
--
-- ── 2. A TRANSFER IN THE MONTH ───────────────────────────────────────────────
--
-- erp.seed_demo_history() builds one day at a time (20260914072000). At the end
-- of every Wednesday a lorry takes finished goods from the main warehouse's
-- bulk store to the distribution centre: the three it holds most of, a quarter
-- of what is on the shelf and never more than half a week's demand. It goes
-- through the doors a warehouse uses — erp.raise_transfer_order(), the
-- approval transition, erp.despatch_transfer(), erp.receive_transfer() — and
-- is dated the day the lorry ran, the way the builder dates its invoices.
--
-- A weekday rather than a roll of the dice, for two reasons. Any run of seven
-- days holds one, so the month the build seeds always holds four or five
-- transfers and the suite below can say exactly how many ten days hold. And
-- the block draws nothing from random(), so every other document a day builds
-- is the document it built before this migration.
--
-- The lines are pinned to the bulk store, as the builder's deliveries are, so
-- the lorry is loaded from the shelf whose quantity it was sized against.
--
-- Deployed bodies, asserted needles. erp.ensure_demo_configuration() carries
-- eight patches since 20260905010000 defined it whole and
-- erp.seed_demo_history() five (20260906050000, 20260912190000,
-- 20260914062000 twice, 20260914072000); a re-emission from any file would
-- drop them. Each needle is counted before it is replaced and the patches the
-- body already had are asserted afterwards.
--
-- Proof: erp_test.demo_site_transfer_suite() (9 cases, wrapper pinned) builds
-- its own demonstration, seeds the ten days the build seeds first, and holds
-- the transfers to both sites' quantities, the value to the penny, no journal,
-- and the stock, inventory and ownership reconciliations.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The company has a second site
-- ═════════════════════════════════════════════════════════════════════════════

do $depot$
declare
  v_sig  constant text := 'erp.ensure_demo_configuration(uuid,uuid)';
  v_def  text := pg_get_functiondef('erp.ensure_demo_configuration(uuid,uuid)'::regprocedure);
  -- The end of the main warehouse's locations. The site and its places are
  -- one thought, so the second site follows the first.
  v_n    constant text := E'x(code, name, kind, pick)\n  on conflict (tenant_id, site_id, code) do nothing;\n';
  v_r    constant text := $r$x(code, name, kind, pick)
  on conflict (tenant_id, site_id, code) do nothing;

  -- A second site of the same company (20260918100000), so the history has
  -- somewhere to move stock to. Coded to sort after the main warehouse, and a
  -- distribution centre rather than a warehouse: whatever looks for "the"
  -- warehouse of a demonstration takes the first by code, or the first of
  -- type warehouse, and still finds the main one. A company that already
  -- keeps stock somewhere else keeps what it has.
  if not exists (select 1 from erp.site s
                  where s.tenant_id = p_tenant_id and s.entity_id = v_entity
                    and s.id is distinct from v_site
                    and s.site_type in ('warehouse'::erp.site_type, 'distribution'::erp.site_type)
                    and s.status = 'active'::erp.record_status) then
    insert into erp.site (tenant_id, entity_id, code, name, site_type, country_code, status, created_by)
    values (p_tenant_id, v_entity, 'NORTH-DC', 'Northern distribution centre', 'distribution'::erp.site_type,
            (select e.country_code from erp.entity e where e.id = v_entity), 'active'::erp.record_status, p_principal)
    on conflict (tenant_id, code) do nothing;
    if found then
      v_did := v_did || '"site NORTH-DC"'::jsonb;
    end if;
  end if;

  -- Its goods in, its bulk store and its despatch bay, so stock can arrive
  -- there and leave again. Codes of its own, so a list of every place the
  -- company keeps stock does not show two called RECV.
  insert into erp.location (tenant_id, site_id, code, name, location_type, is_pickable, status, created_by)
  select p_tenant_id, s.id, x.code, x.name, x.kind::erp.location_type, x.pick, 'active'::erp.record_status, p_principal
    from erp.site s
   cross join (values ('NDC-RECV', 'Goods in',   'receiving', false),
                      ('NDC-BULK', 'Bulk store', 'bulk',      true),
                      ('NDC-DESP', 'Despatch',   'despatch',  false)) x(code, name, kind, pick)
   where s.tenant_id = p_tenant_id and s.entity_id = v_entity and s.code = 'NORTH-DC'
  on conflict (tenant_id, site_id, code) do nothing;
$r$;
  v_hits integer;
begin
  if position('NORTH-DC' in v_def) > 0 then
    raise exception
      'CLOVEERP_DEMO_CONFIGURATION_UNRECOGNISED: % already gives the company a second site; this migration would give it two', v_sig;
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_DEMO_CONFIGURATION_UNRECOGNISED: expected the main warehouse''s locations to end once in %, found %',
      v_sig, v_hits;
  end if;

  execute replace(v_def, v_n, v_r);

  -- What the body already carried is still in it, and the second site took.
  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('''NORTH-DC'', ''Northern distribution centre''' in v_def) = 0
     or position('''MAIN-WH'', ''Main warehouse''' in v_def) = 0
     or position('chart_8_1' in v_def) = 0                                   -- 20260905020000
     or position('renamed ACME' in v_def) = 0                                -- 20260905030000
     or position('"inventory upgraded"' in v_def) = 0                        -- 20260906141000
     or position('"procurement controls"' in v_def) = 0                      -- 20260909212619
     or position('erp.seed_demo_item_suppliers(p_tenant_id)' in v_def) = 0   -- 20260914076000
     or position('erp.configure_tax(''GB'', 20)' in v_def) = 0               -- 20260916030000
     or position('erp.rule_set_version rsv' in v_def) = 0                    -- 20260916030000
     or position('entity_tax_registration' in v_def) = 0                     -- 20260916090000
     or position('"site transfers"' in v_def) = 0 then                       -- 20260917130000
    raise exception
      'CLOVEERP_DEMO_CONFIGURATION_UNRECOGNISED: % dropped a patch it already had, or did not take its second site', v_sig;
  end if;
end
$depot$;

comment on function erp.ensure_demo_configuration(uuid, uuid) is
  'Takes a demonstration organisation from provisioned to able to trade, once: '
  'sandbox, the installers, four years of periods, posting rules in force '
  'from two years back, numbering without the year, two sites of the trading '
  'company — a main warehouse and a distribution centre, each with its '
  'locations — and master data to trade with. Idempotent; refused in a live '
  'environment.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Every Wednesday a lorry runs to the distribution centre
-- ═════════════════════════════════════════════════════════════════════════════

do $history$
declare
  v_sig  constant text := 'erp.seed_demo_history(date,date,numeric)';
  v_def  text := pg_get_functiondef('erp.seed_demo_history(date,date,numeric)'::regprocedure);
  -- The end of the day. What is built last in a day is built from what the
  -- day left on the shelf.
  v_n    constant text := E'  end loop days;\n';
  v_r    constant text := $r$  -- ── The trunk run to the other site ──────────────────────────────────────
  -- Every Wednesday a lorry takes finished goods from the main warehouse's
  -- bulk store to the company's other site (20260918100000): the three it
  -- holds most of, a quarter of what is on the shelf and never more than half
  -- a week's demand. Raised, approved, loaded and booked in through the doors
  -- a warehouse uses, so the value crosses at cost and no journal is posted.
  -- Nothing here draws on random(), so the rest of the day is what it was.
  if extract(isodow from v_day) = 3 then
    declare
      v_depot    uuid;
      v_load     jsonb;
      v_transfer uuid;
    begin
      select s.id into v_depot
        from erp.site s
       where s.tenant_id = v_tenant and s.entity_id = v_entity
         and s.id is distinct from v_site
         and s.site_type in ('warehouse'::erp.site_type, 'distribution'::erp.site_type)
         and s.status = 'active'::erp.record_status
         and exists (select 1 from erp.location dl
                      where dl.tenant_id = s.tenant_id and dl.site_id = s.id
                        and dl.location_type = 'receiving'::erp.location_type
                        and dl.status = 'active'::erp.record_status and not dl.is_blocked)
       order by s.code
       limit 1;

      select coalesce(jsonb_agg(jsonb_build_object('item_id', x.id, 'quantity', x.quantity,
                                                   'description', x.name)
                                order by x.code), '[]'::jsonb)
        into v_load
        from (select i.id, i.code, i.name,
                     least(floor(sb.on_hand / 4),
                           ceil((i.attributes -> 'demo' ->> 'demand_per_week')::numeric / 2)) as quantity
                from erp.item i
               cross join lateral (
                 select coalesce(sum(b.quantity), 0) as on_hand
                   from erp.stock_balance b
                  where b.tenant_id = v_tenant and b.site_id = v_site
                    and b.location_id = v_bulk and b.item_id = i.id
                    and b.batch_id is null and b.serial_id is null and b.container_id is null
                    and b.stock_status = 'available'::erp.stock_status) sb
               where v_depot is not null and v_bulk is not null
                 and i.tenant_id = v_tenant and i.status = 'active'::erp.record_status
                 and i.item_class = 'finished_good' and i.attributes ? 'demo'
                 and floor(sb.on_hand / 4) >= 1
               order by sb.on_hand desc, i.code
               limit 3) x;

      if jsonb_array_length(v_load) > 0 then
        v_seq := v_seq + 1;
        v_transfer := (erp.raise_transfer_order(v_site, v_depot, v_load, v_day + 1,
                                                v_prefix || lpad(v_seq::text, 3, '0'))
                         ->> 'document_id')::uuid;
        -- Opened today and dated the day the lorry ran, as the invoices above
        -- are; both legs read the document's date. Loaded from the shelf the
        -- quantities were sized against, as the deliveries above are.
        update erp.document set document_date = v_day
         where tenant_id = v_tenant and id = v_transfer;
        update erp.document_line set location_id = v_bulk
         where tenant_id = v_tenant and document_id = v_transfer;
        perform erp.transition_document(v_transfer, 'approved', 'demonstration');
        perform erp.despatch_transfer(v_transfer);
        perform erp.receive_transfer(v_transfer);
        v_built := v_built + 1;
      end if;
    end;
  end if;

  end loop days;
$r$;
  v_hits integer;
  v_secdef boolean;
begin
  if position('erp.despatch_transfer(' in v_def) > 0 then
    raise exception
      'CLOVEERP_DEMO_BUILDER_UNRECOGNISED: % already moves stock between sites; this migration would move it twice', v_sig;
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_DEMO_BUILDER_UNRECOGNISED: expected the day to end once in %, found %', v_sig, v_hits;
  end if;

  execute replace(v_def, v_n, v_r);

  -- What the body already carried is still in it, and the lorry took.
  v_def := pg_get_functiondef(v_sig::regprocedure);
  select p.prosecdef into v_secdef from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure;
  if position('erp.receive_transfer(v_transfer)' in v_def) = 0
     or position('0.92 + random()::numeric * 0.16' in v_def) = 0                         -- 20260906050000
     or position('Close only what actually arrived in Received.' in v_def) = 0           -- 20260912190000
     or (length(v_def) - length(replace(v_def, 'erp.approve_my_document_tasks(v_doc, ''demonstration'')', '')))
        / length('erp.approve_my_document_tasks(v_doc, ''demonstration'')') <> 2         -- 20260914062000
     or position('<<days>>' in v_def) = 0                                                -- 20260914072000
     or (length(v_def) - length(replace(v_def, E'  end loop days;\n', ''))) / length(E'  end loop days;\n') <> 1
     or not coalesce(v_secdef, false) then                                                -- 20260914030000
    raise exception
      'CLOVEERP_DEMO_BUILDER_UNRECOGNISED: % dropped a patch it already had, or did not take its transfer', v_sig;
  end if;
end
$history$;

comment on function erp.seed_demo_history(date, date, numeric) is
  'Builds demonstration trading one day at a time through the spine — purchase '
  'orders and receipts, sales orders, despatches, invoices and cash, quotations, '
  'requisitions, and every Wednesday a transfer from the main warehouse to the '
  'company''s other site — at most five days per call, starting no new day once '
  'a quarter of the caller''s statement timeout has gone, and says where the '
  'next call should start. A day already built, or inside a five-day slice built '
  'before, is skipped; refused in a live environment; every journal and movement '
  'is raised by the same bridges and doors a person''s document goes through.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Its own demonstration, configured and seeded the way supabase/ci/seed_demo.sql
-- seeds the build's: the same first day, the same five-day calls. Ten days hold
-- one Wednesday or two, and the suite says exactly how many transfers that is.

create or replace function erp_test.demo_site_transfer_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases      integer := 0;
  v_tenant     uuid; v_admin uuid; v_token text;
  v_conf       jsonb; v_again jsonb;
  v_entity     uuid; v_main uuid; v_depot uuid; v_first uuid;
  v_from       date := (date_trunc('month', current_date) - interval '12 months')::date;
  v_wednesdays integer;
  v_transfers  integer; v_transfers_again integer;
  v_sites      integer; v_sites_again integer;
  v_n          integer; v_m integer;
  v_qty_in     numeric; v_qty_depot numeric; v_transit numeric;
  v_out        bigint; v_in bigint; v_val_depot bigint;
  v_ok         boolean; v_msg text;
begin
  begin
  select t.tenant_id, t.admin_user_id, t.admin_token
    into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-two-sites', 'Two sites suite',
                              'admin@zz-two-sites.test', 'Two Sites Admin') t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email)
  values ('00000000-0000-4000-8000-00000000d2d2', 'admin@zz-two-sites.test');
  perform set_config('request.jwt.claims',
                     json_build_object('sub', '00000000-0000-4000-8000-00000000d2d2')::text, true);
  perform erp.claim_invitation(v_token);
  v_conf := erp.ensure_demo_configuration(v_tenant, v_admin);

  select l.entity_id into v_entity
    from erp.ledger l where l.tenant_id = v_tenant and l.is_primary order by l.code limit 1;
  select s.id into v_main from erp.site s where s.tenant_id = v_tenant and s.code = 'MAIN-WH';
  select s.id into v_depot from erp.site s where s.tenant_id = v_tenant and s.code = 'NORTH-DC';
  -- Exactly how erp.seed_demo_history() and the demonstration suites choose.
  select s.id into v_first from erp.site s
   where s.tenant_id = v_tenant and s.entity_id = v_entity
     and s.site_type in ('warehouse'::erp.site_type, 'distribution'::erp.site_type)
     and s.status = 'active'::erp.record_status
   order by s.code limit 1;

  -- ── 1. Two sites of one company ──────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the demonstration company keeps stock at two sites: the main warehouse, still the first by code, and a distribution centre with goods in, a bulk store and a despatch bay';
  passed := v_main is not null and v_depot is not null
        and v_first = v_main
        and (select s.entity_id from erp.site s where s.id = v_main) = v_entity
        and (select s.entity_id from erp.site s where s.id = v_depot) = v_entity
        and (select count(distinct l.location_type) from erp.location l
              where l.tenant_id = v_tenant and l.site_id = v_depot
                and l.status = 'active'::erp.record_status
                and l.location_type in ('receiving'::erp.location_type, 'bulk'::erp.location_type,
                                        'despatch'::erp.location_type)) = 3
        and (v_conf -> 'installed') ? 'site NORTH-DC';
  detail := format('MAIN-WH %s, NORTH-DC %s, first by code %s; installed %s',
                   v_main is not null, v_depot is not null,
                   (select s.code from erp.site s where s.id = v_first), v_conf -> 'installed');
  return next;

  -- ── 2. Configured again, nothing more ────────────────────────────────────
  v_cases := v_cases + 1;
  select count(*) into v_sites from erp.site s where s.tenant_id = v_tenant;
  v_again := erp.ensure_demo_configuration(v_tenant, v_admin);
  select count(*) into v_sites_again from erp.site s where s.tenant_id = v_tenant;
  case_name := 'configured again, the demonstration makes no third site and installs nothing';
  passed := v_sites = v_sites_again and jsonb_array_length(v_again -> 'installed') = 0;
  detail := format('%s site(s) before, %s after; installed %s',
                   v_sites, v_sites_again, v_again -> 'installed');
  return next;

  -- The ten days the build seeds first, in the calls it seeds them in.
  perform erp.seed_demo_history(v_from, null, 1);
  perform erp.seed_demo_history(v_from + 5, null, 1);
  set constraints all immediate;

  select count(*) into v_wednesdays
    from generate_series(0, 9) k(n)
   where extract(isodow from v_from + k.n) = 3;

  select count(*) into v_transfers
    from erp.document d
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
   where d.tenant_id = v_tenant and dt.base_type_code = 'transfer_order';

  -- ── 3. A transfer every Wednesday ────────────────────────────────────────
  v_cases := v_cases + 1;
  select count(*) into v_n
    from erp.document d
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
   where d.tenant_id = v_tenant and dt.base_type_code = 'transfer_order'
     and d.site_id = v_main and d.destination_site_id = v_depot
     and d.document_date between v_from and v_from + 9
     and extract(isodow from d.document_date) = 3
     and d.their_reference like 'DEMO-' || to_char(d.document_date, 'YYYYMMDD') || '-%';
  case_name := 'the ten days the build seeds first hold a transfer from the main warehouse to the distribution centre on every Wednesday, dated that day under that day''s reference';
  passed := v_wednesdays >= 1 and v_transfers = v_wednesdays and v_n = v_wednesdays;
  detail := format('%s Wednesday(s) from %s; %s transfer order(s), %s from MAIN-WH to NORTH-DC on a Wednesday under its day''s reference',
                   v_wednesdays, v_from, v_transfers, v_n);
  return next;

  -- ── 4. Each one made the whole journey ───────────────────────────────────
  v_cases := v_cases + 1;
  select count(*) into v_n
    from erp.document d
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
    cross join lateral (
      select count(*) filter (where m.movement_type = 'transfer_despatch') as despatched,
             count(*) filter (where m.movement_type = 'transfer_out')      as left_site,
             count(*) filter (where m.movement_type = 'transfer_in')       as arrived
        from erp.stock_movement m
       where m.tenant_id = d.tenant_id and m.document_id = d.id and not m.is_reversal) legs
   where d.tenant_id = v_tenant and dt.base_type_code = 'transfer_order'
     and (erp.document_state_code(d.id) is distinct from 'received'
          or legs.despatched = 0
          or legs.despatched <> (select count(*) from erp.document_line dl
                                  where dl.tenant_id = d.tenant_id and dl.document_id = d.id
                                    and not dl.is_cancelled and dl.quantity > 0)
          or legs.left_site <> legs.despatched
          or legs.arrived <> legs.despatched);
  select coalesce(sum(b.quantity), 0) into v_transit
    from erp.stock_balance b
   where b.tenant_id = v_tenant and b.stock_status = 'in_transit'::erp.stock_status;
  case_name := 'every transfer was approved, loaded and booked in: received, with a leg off the shelf, out of transit and in at the far end for every line, and nothing left on the road';
  passed := v_transfers > 0 and v_n = 0 and v_transit = 0;
  detail := format('%s of %s transfer(s) short of the journey; %s standing in transit',
                   v_n, v_transfers, v_transit);
  return next;

  -- ── 5. The distribution centre holds what arrived ────────────────────────
  v_cases := v_cases + 1;
  select coalesce(sum(m.quantity), 0) into v_qty_in
    from erp.stock_movement m
   where m.tenant_id = v_tenant and m.site_id = v_depot
     and m.movement_type = 'transfer_in' and not m.is_reversal;
  select coalesce(sum(b.quantity), 0) into v_qty_depot
    from erp.stock_balance b
   where b.tenant_id = v_tenant and b.site_id = v_depot;
  case_name := 'the distribution centre holds exactly what arrived, all of it in its goods-in place';
  passed := v_qty_in > 0 and v_qty_depot = v_qty_in
        and not exists (select 1 from erp.stock_balance b
                          join erp.location l on l.tenant_id = b.tenant_id and l.id = b.location_id
                         where b.tenant_id = v_tenant and b.site_id = v_depot and b.quantity <> 0
                           and l.code <> 'NDC-RECV');
  detail := format('%s arrived, %s on hand at NORTH-DC', v_qty_in, v_qty_depot);
  return next;

  -- ── 6. The value crossed to the penny ────────────────────────────────────
  v_cases := v_cases + 1;
  select coalesce(sum(m.cost_minor), 0)::bigint into v_out
    from erp.stock_movement m
   where m.tenant_id = v_tenant and m.site_id = v_main
     and m.movement_type = 'transfer_out' and not m.is_reversal;
  select coalesce(sum(m.cost_minor), 0)::bigint into v_in
    from erp.stock_movement m
   where m.tenant_id = v_tenant and m.site_id = v_depot
     and m.movement_type = 'transfer_in' and not m.is_reversal;
  select coalesce(sum(v.value_minor), 0)::bigint into v_val_depot
    from erp.stock_valuation_report() v
   where v.site_id = v_depot;
  case_name := 'the value that left the main warehouse is the value the distribution centre carries, to the penny';
  passed := v_out > 0 and v_in = v_out and v_val_depot = v_in;
  detail := format('%s left MAIN-WH, %s arrived at NORTH-DC, NORTH-DC is valued at %s',
                   v_out, v_in, v_val_depot);
  return next;

  -- ── 7. No journal, and the books still tie ───────────────────────────────
  v_cases := v_cases + 1;
  select count(*) into v_n
    from erp.journal j
    join erp.document d on d.tenant_id = j.tenant_id and d.id = j.document_id
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
   where j.tenant_id = v_tenant and dt.base_type_code = 'transfer_order';
  begin
    v_msg := erp.assert_stock_reconciles() || '; ' || erp.assert_inventory_reconciles()
             || '; ' || erp.assert_ownership_carried();
    v_ok := true;
  exception when others then
    v_ok := false;
    v_msg := left(sqlerrm, 240);
  end;
  case_name := 'no transfer raised a journal, and stock, inventory and ownership reconcile with the transfers in them';
  passed := v_ok and v_n = 0;
  detail := format('%s journal(s) against a transfer order; %s', v_n, v_msg);
  return next;

  -- ── 8. The same days again move nothing again ────────────────────────────
  v_cases := v_cases + 1;
  select count(*) into v_n from erp.document d where d.tenant_id = v_tenant;
  perform erp.seed_demo_history(v_from, null, 1);
  perform erp.seed_demo_history(v_from + 5, null, 1);
  select count(*) into v_m from erp.document d where d.tenant_id = v_tenant;
  select count(*) into v_transfers_again
    from erp.document d
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
   where d.tenant_id = v_tenant and dt.base_type_code = 'transfer_order';
  case_name := 'building the same days again raises no second transfer';
  passed := v_m = v_n and v_transfers_again = v_transfers;
  detail := format('%s document(s) before, %s after; %s transfer(s) before, %s after',
                   v_n, v_m, v_transfers, v_transfers_again);
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- ── 9. Undone ────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := not exists (select 1 from erp.tenant where code = 'zz-two-sites')
        and not exists (select 1 from auth.users
                         where id = '00000000-0000-4000-8000-00000000d2d2');
  detail := 'zz-two-sites rolled back with both its sites, its month and its transfers';
  return next;

  if v_cases <> 9 then
    raise exception 'CLOVEERP_SUITE_SHRANK: demo_site_transfer_suite ran % cases, expected 9', v_cases;
  end if;
end;
$$;

revoke all on function erp_test.demo_site_transfer_suite() from public, anon;

create or replace function erp_test.assert_demo_site_transfer_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _demo_site_transfer on commit drop as
    select * from erp_test.demo_site_transfer_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _demo_site_transfer;
  drop table _demo_site_transfer;
  if v_fail > 0 then
    raise exception E'CLOVEERP_DEMO_SITE_TRANSFER_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> 9 then
    raise exception 'CLOVEERP_SUITE_SHRANK: demo_site_transfer_suite ran % cases, expected 9', v_all;
  end if;
  return format('the demonstration moves stock between two sites: %s/%s cases passed', v_all, v_all);
end;
$$;

revoke all on function erp_test.assert_demo_site_transfer_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_demo_site_transfer_suite();

select erp.assert_public_api_safe();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_isolation();
