set lock_timeout = '30s';

-- =============================================================================
-- 20261007042000  A service is chosen from the carrier's list
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-64). "Book a
-- collection" asked for the carrier's Service as typed text, with
-- "standard" written in the box. No carrier's rate card quotes a service
-- called standard (the demonstration's road haulier quotes ECONOMY and
-- NEXT_DAY), so a booking left without a cost was refused with
-- CLOVEERP_NO_TARIFF. The outbound forms, "Ship these deliveries" and "Book a
-- shipment", asked the same way. public.erp_carriers answered each carrier's
-- services only as one line of text, so no form could offer them as a list.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. public.erp_carriers answers service_options for each carrier: each
--      service on its rate card, by code, with its days in transit. The
--      services line it answered before is kept as it was.
--      The three forms offer Service as a choice within the carrier chosen,
--      and the "standard" placeholder goes. Where a service is left empty it
--      still means what it meant: the rate card's recommended service, on the
--      forms where that was so.
--   B. The words a carrier with no service on its rate card shows.
--   C. erp_test.carrier_service_options_suite.
--
-- Production: one read door is patched. No table is altered and no row is
-- changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. Each carrier lists its services
-- ─────────────────────────────────────────────────────────────────────────────

do $carriers$
declare
  v_sig  constant text := 'public.erp_carriers()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$                                       from jsonb_array_elements(c.services) sv), '')) as x$o$;
  v_new  constant text := $n$                                       from jsonb_array_elements(c.services) sv), ''),
               -- Each service on the carrier's rate card, to be chosen
               -- rather than typed (20261007042000, J-64): its code and its
               -- days in transit.
               'service_options', coalesce((select jsonb_agg(jsonb_build_object(
                                                     'code', sv.value ->> 'code',
                                                     'transit_days', sv.value -> 'transit_days')
                                                   order by sv.value ->> 'code')
                                              from jsonb_array_elements(c.services) sv
                                             where coalesce(sv.value ->> 'code', '') <> ''), '[]'::jsonb)) as x$n$;
begin
  if strpos(v_src, '20261007042000') > 0 then
    raise notice '% already lists each carrier''s services; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'df9f6ccc61ce92cd2123f0615615f02e' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261007042000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$carriers$;

comment on function public.erp_carriers() is
  'The carriers the organisation may book a shipment with, from erp.carrier, each with its party, the codes of its '
  'services as one line, and its services as a list to choose from, each with its days in transit '
  '(20261007042000). Reads under row security as the caller, and authorises nothing.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The words
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). A service is chosen from the carrier''s list (20261007042000).'
  from (values
    ('No service to choose: this carrier''s rate card names none.')
  ) as v(text)
on conflict (key, locale) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.carrier_service_options_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 3;
  v_cases   integer := 0;
  v_tag     text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1        uuid := gen_random_uuid();
  rb        record;
  v_step    text := 'provisioning';
  v_state   text;
  v_entity  uuid; v_site uuid; v_uom uuid; v_item uuid; v_sa uuid;
  v_list    jsonb; v_row jsonb; v_bare jsonb;
  v_bad     integer;
  v_carrier text; v_service text;
  v_po      uuid; v_po2 uuid;
  v_ship    jsonb;
  v_err     text;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    v_step := 'an organisation that buys and ships, and a carrier with no rate card yet';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzcso-' || v_tag, 'Carrier Service Options Suite',
      'admin@zzcso-' || v_tag || '.test', 'Carrier Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzcso-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    select e.id into v_entity from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZCSOCOAT', 'Carried Coat', v_uom, 'active') returning id into v_item;
    v_sa := erp_test.cash_payment_supplier('ZCSOA');
    insert into erp.carrier (tenant_id, code, name, services)
    values (rb.tenant_id, 'ZCSO-BARE', 'Carrier Service Options Bare', '[]'::jsonb);

    v_list := public.erp_carriers();

    -- ── 1. Each carrier's list is its rate card ─────────────────────────────
    v_step := 'comparing each carrier''s list with its rate card';
    select count(*) into v_bad
      from erp.carrier c
      left join lateral (select x from jsonb_array_elements(v_list) x where x ->> 'code' = c.code) r on true
     where c.tenant_id = rb.tenant_id and c.status = 'active'
       and (r.x is null
            or (select coalesce(jsonb_agg(o ->> 'code'), '[]'::jsonb)
                  from jsonb_array_elements(r.x -> 'service_options') o)
               is distinct from
               (select coalesce(jsonb_agg(sv.value ->> 'code' order by sv.value ->> 'code'), '[]'::jsonb)
                  from jsonb_array_elements(c.services) sv)
            or exists (select 1 from jsonb_array_elements(r.x -> 'service_options') o
                        join jsonb_array_elements(c.services) sv on sv.value ->> 'code' = o ->> 'code'
                       where (o -> 'transit_days') is distinct from (sv.value -> 'transit_days'))
            or r.x ->> 'services' is distinct from
               coalesce((select string_agg(sv.value ->> 'code', ', ' order by sv.value ->> 'code')
                           from jsonb_array_elements(c.services) sv), ''));
    select x into v_row from jsonb_array_elements(v_list) x
     where jsonb_array_length(x -> 'service_options') > 1 order by x ->> 'code' limit 1;
    v_cases := v_cases + 1;
    case_name := 'every active carrier lists the services of its rate card, in code order, each with its days in transit, and still names them in one line as before';
    passed := v_state is null
          and v_bad = 0
          and v_row is not null
          and (select count(*) from erp.carrier c
                where c.tenant_id = rb.tenant_id and c.status = 'active' and jsonb_array_length(c.services) > 0) > 0;
    detail := coalesce(v_state, left(format('%s carrier(s) disagree; a carrier with several: %s', v_bad, v_row), 500));
    return next;

    -- ── 2. A carrier with no rate card lists nothing ────────────────────────
    v_step := 'reading the carrier with no rate card';
    select x into v_bare from jsonb_array_elements(v_list) x where x ->> 'code' = 'ZCSO-BARE';
    v_cases := v_cases + 1;
    case_name := 'a carrier whose rate card names no service lists none, as an empty list and an empty line';
    passed := v_state is null
          and v_bare is not null
          and jsonb_typeof(v_bare -> 'service_options') = 'array'
          and jsonb_array_length(v_bare -> 'service_options') = 0
          and v_bare ->> 'services' = '';
    detail := coalesce(v_state, left(format('%s', v_bare), 500));
    return next;

    -- ── 3. A service from the list books without a cost typed ───────────────
    v_step := 'booking a collection with a service from the list and no cost, and with the old placeholder';
    v_carrier := v_row ->> 'code';
    v_service := v_row -> 'service_options' -> 0 ->> 'code';
    v_po := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 10, 9000, 'ZCSO1', false);
    perform public.erp_set_freight_terms(v_po, 'we_collect');
    perform erp.transition_document(v_po, 'send', null);
    v_po2 := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 3, 9000, 'ZCSO2', false);
    perform public.erp_set_freight_terms(v_po2, 'we_collect');
    perform erp.transition_document(v_po2, 'send', null);
    v_ship := public.erp_ship_inbound(v_po, v_carrier, v_service, null, null, null, 12000);
    begin
      perform public.erp_ship_inbound(v_po2, v_carrier, 'standard', null, null, null, 12000);
      v_err := 'booked';
    exception when others then v_err := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'a collection booked with a service from the carrier''s list and no cost is priced by its rate card; the word the box used to suggest, which no rate card names, is refused for want of a tariff';
    passed := v_state is null
          and v_ship ->> 'status' = 'booked'
          and v_ship ->> 'service_code' = v_service
          and coalesce((v_ship ->> 'cost_minor')::bigint, 0) > 0
          and v_err like 'CLOVEERP_NO_TARIFF%';
    detail := coalesce(v_state, left(format('%s %s booked %s; standard: %s', v_carrier, v_service, v_ship, v_err), 500));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('erp.job_tenant_id', '', true);
  perform set_config('erp.job_principal_id', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_CARRIER_SERVICE_OPTIONS_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.carrier_service_options_suite() from public, anon;

comment on function erp_test.carrier_service_options_suite() is
  'A service is chosen from the carrier''s list (20261007042000, J-64): erp_carriers lists each carrier''s rate-card '
  'services in code order with their days in transit and keeps the one-line services; a carrier with no rate card '
  'lists none; a service from the list books a collection priced by the rate card, where "standard" is refused.';

create or replace function erp_test.assert_carrier_service_options_suite()
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
    from erp_test.carrier_service_options_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_CARRIER_SERVICE_OPTIONS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'The Service picker offers something other than the carrier''s rate card. Read the case that failed.';
  end if;
  if v_total <> 3 then
    raise exception 'CLOVEERP_CARRIER_SERVICE_OPTIONS_SUITE_SHRANK: % case(s), expected 3', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('a service is chosen from the carrier''s list: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_carrier_service_options_suite() from public, anon;

comment on function erp_test.assert_carrier_service_options_suite() is
  'erp_carriers lists each carrier''s rate-card services to choose from (20261007042000).';

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
