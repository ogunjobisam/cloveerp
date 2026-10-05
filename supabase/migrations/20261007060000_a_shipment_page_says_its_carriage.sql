set lock_timeout = '30s';

-- =============================================================================
-- 20261007060000  A shipment's page says its carriage
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-66). A collection was
-- booked for an order we collect, with a carrier, a service, a cost of £45
-- and an expected arrival, and its shipment page showed none of it: "£0.00",
-- "Lines (0)", and a Carriage card with the weight alone. A shipment document
-- has no lines and no value of its own (erp.ship_inbound opens it with
-- attributes only), so the generic page had nothing to draw from it.
--
-- public.erp_shipment_tracking, the one read the Carriage card makes,
-- answered the weight, the tracking code and the label, and not the carrier,
-- the service, the cost, the expected arrival or what the shipment carries,
-- although erp.shipment and erp.shipment_line hold every one of them. An
-- outbound shipment's page lacked its carrier, cost and deliveries the same
-- way.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. public.erp_shipment_tracking also answers carrier (the carrier's
--      name), service_code, cost_minor (the freight cost booked),
--      expected_arrival, and carries: each document the shipment carries
--      (the order of a collection, the deliveries of an outbound shipment),
--      by id and number, from erp.shipment_line. Every key it answered
--      before is kept as it was.
--      The Carriage card shows Carrier, Service, Cost, Expected and links to
--      what the shipment carries, and is drawn whenever a carrier is booked.
--      The page no longer draws an empty Lines card, or a value of nothing,
--      on a shipment.
--   B. erp_test.inbound_freight_suite proves the door answers a booked
--      collection's carrier, service, cost, expected arrival and order.
--
-- Production: one read door is patched and one suite extended. No table is
-- altered and no row is changed, in any organisation.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The shipment as booked
-- ─────────────────────────────────────────────────────────────────────────────

do $tracking$
declare
  v_sig  constant text := 'public.erp_shipment_tracking(uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$           'provider', c.provider, 'weight_g', nullif(s.total_weight_g, 0),$o$;
  v_new  constant text := $n$           'provider', c.provider, 'weight_g', nullif(s.total_weight_g, 0),
           -- The shipment as it was booked (20261007060000, J-66): with which
           -- carrier and service, at what cost, expected when, and what it
           -- carries (a collection's order, an outbound shipment's
           -- deliveries).
           'carrier', c.name, 'service_code', s.service_code,
           'cost_minor', s.freight_cost_minor, 'expected_arrival', s.planned_arrival,
           'carries', coalesce((select jsonb_agg(jsonb_build_object(
                                         'document_id', cd.id, 'document_number', cd.document_number)
                                       order by cd.document_number)
                                  from erp.shipment_line sl
                                  join erp.document cd on cd.tenant_id = sl.tenant_id and cd.id = sl.document_id
                                 where sl.tenant_id = s.tenant_id and sl.shipment_id = s.id), '[]'::jsonb),$n$;
begin
  if strpos(v_src, '20261007060000') > 0 then
    raise notice '% already says how the shipment was booked; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '5aa5d422cb09c860f4cfea29c7ca00c9' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261007060000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$tracking$;

comment on function public.erp_shipment_tracking(uuid) is
  'A shipment as its page draws it (20261004965000): its weight, its label, its tracking code and status, '
  'whether its carrier is booked through the organisation''s provider, and as it was booked (20261007060000): '
  'the carrier, the service, the cost, the expected arrival and each document it carries. Reads under row '
  'security as the caller, and authorises nothing.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The proof
-- ─────────────────────────────────────────────────────────────────────────────

do $freight$
declare
  v_sig  constant text := 'erp_test.inbound_freight_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  text[] := array[
$o$  c_expected constant integer := 9;
$o$,
$o$    -- ── 3. What may not be booked ───────────────────────────────────────────
$o$];
  v_new  text[] := array[
$n$  -- Nine until 20261007060000, which added that the shipment's page reads
  -- how the collection was booked.
  c_expected constant integer := 10;
  v_trk    jsonb;
$n$,
$n$    -- ── 2b. The shipment's page says how it was booked (20261007060000, J-66)
    v_step := 'reading the collection as its shipment page reads it';
    v_trk := public.erp_shipment_tracking((v_ship ->> 'document_id')::uuid);
    v_cases := v_cases + 1;
    case_name := 'the shipment''s page reads the collection as it was booked: the carrier by name, the service, the £100 cost, the expected arrival, and the one order it carries, by number';
    passed := v_state is null
          and v_trk ->> 'carrier' = (select c.name from erp.carrier c
                                       where c.tenant_id = rb.tenant_id and c.code = v_carrier)
          and v_trk ->> 'service_code' = 'standard'
          and (v_trk ->> 'cost_minor')::bigint = 10000
          and (v_trk ->> 'expected_arrival')::date = current_date + 3
          and jsonb_array_length(v_trk -> 'carries') = 1
          and v_trk -> 'carries' -> 0 ->> 'document_id' = v_po::text
          and v_trk -> 'carries' -> 0 ->> 'document_number'
              = (select d.document_number from erp.document d where d.id = v_po)
          and (v_trk ->> 'weight_g')::numeric = 12500;
    detail := coalesce(v_state, left(format('tracking %s', v_trk), 600));
    return next;

    -- ── 3. What may not be booked ───────────────────────────────────────────
$n$];
  v_def2 text;
  i      integer;
begin
  if strpos(v_src, '20261007060000') > 0 then
    raise notice '% already reads the shipment as booked; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'e3bd29761de85e778196f8bf6843c95b' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261007060000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  v_def2 := v_def;
  for i in 1 .. array_length(v_old, 1) loop
    if (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]) <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found other than once', v_sig, i;
    end if;
    v_def2 := replace(v_def2, v_old[i], v_new[i]);
  end loop;
  execute v_def2;
end
$freight$;

do $freight_count$
declare
  v_sig  constant text := 'erp_test.assert_inbound_freight_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  if v_total <> 9 then
    raise exception 'CLOVEERP_INBOUND_FREIGHT_SUITE_SHRANK: % case(s), expected 9', v_total
$o$;
  v_new  constant text := $n$  -- Nine until 20261007060000, which added that the shipment's page reads
  -- how the collection was booked.
  if v_total <> 10 then
    raise exception 'CLOVEERP_INBOUND_FREIGHT_SUITE_SHRANK: % case(s), expected 10', v_total
$n$;
begin
  if strpos(v_src, '20261007060000') > 0 then
    raise notice '% already counts 10; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '36a257a35d391b1fa8a2ce4abcc5e98a' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261007060000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$freight_count$;

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
