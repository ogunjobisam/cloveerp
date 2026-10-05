set lock_timeout = '30s';

-- =============================================================================
-- 20261007030000  A received line offers its own places
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-58). "Receive this
-- order" put a Location and a Batch picker on every line. Location listed
-- every active location of the organisation, another site's among them and
-- Despatch and In transit; Batch listed every batch of every product, and on a
-- product that is not batch-controlled, in an organisation with no batches,
-- said the list was "empty for this organisation". The database already
-- refuses a location at another site and a batch of another product
-- (erp.set_line_stock_identity); the screen offered them.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. public.erp_receivable_lines answers, for each line, the places it can
--      be received into and the batches it can be received as:
--        locations  the active locations of the order's site, less despatch
--                   and transit locations;
--        batches    the batches of the line's product, none when the product
--                   is not batch-controlled.
--      The screen's Location and Batch columns read the row's own line's.
--      Receiving is unchanged: a line given no location goes to the site's
--      goods-in, as erp.default_posting_location has always chosen.
--   B. The words: the Batch column's empty sentence, and the line editor's
--      hint, which now says a line with no location goes to goods-in.
--   C. erp_test.received_line_places_suite.
--
-- Production: one read door is patched. No table is altered and no row is
-- changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. Each line says where it can go and what batches it can be
-- ─────────────────────────────────────────────────────────────────────────────

do $receivable$
declare
  v_sig  constant text := 'public.erp_receivable_lines(uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$           'unit_price_minor', dl.unit_price_minor, 'currency', dl.currency)$o$;
  v_new  constant text := $n$           'unit_price_minor', dl.unit_price_minor, 'currency', dl.currency,
           -- Where the line can be received into: the order's site's active
           -- locations, not despatch or in transit (20261007030000, J-58).
           'locations', coalesce((
             select jsonb_agg(jsonb_build_object(
                      'location_id', loc.id, 'code', loc.code, 'name', loc.name,
                      'location_type', loc.location_type) order by loc.code)
               from erp.location loc
              where loc.tenant_id = dl.tenant_id
                and loc.site_id = (select o.site_id from erp.document o
                                    where o.tenant_id = dl.tenant_id and o.id = p_order_id)
                and loc.status = 'active'::erp.record_status
                and loc.location_type not in ('despatch'::erp.location_type, 'transit'::erp.location_type)),
             '[]'::jsonb),
           -- The batches it can be received as: its product's, none when the
           -- product is not batch-controlled (20261007030000, J-58).
           'batches', case when coalesce(i.is_batch_controlled, false) then coalesce((
             select jsonb_agg(jsonb_build_object(
                      'batch_id', b.id, 'batch_number', b.batch_number,
                      'expires_on', b.expires_on, 'status', b.status) order by b.batch_number)
               from erp.batch b
              where b.tenant_id = dl.tenant_id and b.item_id = dl.item_id), '[]'::jsonb)
             else '[]'::jsonb end)$n$;
begin
  if strpos(v_src, '20261007030000') > 0 then
    raise notice '% already offers each line its own places; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '230aeb3499b882359c0e1f53290e2bb1' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261007030000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$receivable$;

comment on function public.erp_receivable_lines(uuid) is
  'The lines of a purchase order with something left to receive: ordered, received, on goods receipts not yet '
  'cancelled, and left, with whether the product needs a batch, the locations of the order''s site it can be '
  'received into (not despatch or in transit) and the batches of its product (none when not batch-controlled) '
  '(20261007030000). Reads under row security as the caller, and authorises nothing.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The words
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). A received line offers its own places (20261007030000).'
  from (values
    ('No batch to choose: this product is not batch-controlled, or has no batch yet.'),
    ('Each line with something left to receive arrives holding what is left. Lower a quantity to receive part of a line, remove a line to leave it for a later delivery, or add the same line twice for two batches. A batch-controlled product needs its batch before the receipt posts. A line with no location goes to the site''s goods-in.')
  ) as v(text)
on conflict (key, locale) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.received_line_places_suite()
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
  v_entity  uuid; v_site uuid; v_far uuid; v_uom uuid; v_sa uuid;
  v_batched uuid; v_plain uuid; v_other uuid;
  v_po      uuid; v_lb uuid; v_lp uuid;
  v_bulk    uuid; v_b1 uuid; v_b2 uuid;
  v_rows    jsonb; v_rb jsonb; v_rp jsonb;
  v_want    text[]; v_got_b text[]; v_got_p text[];
  v_r       jsonb;
  v_line    record;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    v_step := 'an organisation with two sites, a batch-controlled product and a plain one, on one order';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzrlp-' || v_tag, 'Received Line Places Suite',
      'admin@zzrlp-' || v_tag || '.test', 'Received Line Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzrlp-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    select e.id into v_entity from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    v_far := erp.create_site('ZRLP-FAR', 'Received Line Far Site', 'warehouse', v_entity);

    -- The order's site: a shelf, a despatch bay, a van in transit and a shelf
    -- no longer used; the other site: a shelf.
    insert into erp.location (tenant_id, site_id, code, name, location_type)
    values (rb.tenant_id, v_site, 'ZRLP-BULK', 'Received line shelf', 'bulk')
    returning id into v_bulk;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status) values
      (rb.tenant_id, v_site, 'ZRLP-DESP', 'Received line despatch', 'despatch', 'active'),
      (rb.tenant_id, v_site, 'ZRLP-VAN', 'Received line van', 'transit', 'active'),
      (rb.tenant_id, v_site, 'ZRLP-OLD', 'Received line old shelf', 'bulk', 'inactive'),
      (rb.tenant_id, v_far, 'ZRLP-AWAY', 'Received line far shelf', 'bulk', 'active');

    insert into erp.item (tenant_id, code, name, stock_uom_id, status, is_batch_controlled)
    values (rb.tenant_id, 'ZRLPBATCH', 'Received Line Serum', v_uom, 'active', true) returning id into v_batched;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status, is_batch_controlled)
    values (rb.tenant_id, 'ZRLPPLAIN', 'Received Line Box', v_uom, 'active', false) returning id into v_plain;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status, is_batch_controlled)
    values (rb.tenant_id, 'ZRLPOTHER', 'Received Line Other Serum', v_uom, 'active', true) returning id into v_other;
    insert into erp.batch (tenant_id, item_id, batch_number) values (rb.tenant_id, v_batched, 'ZRLP-B1')
    returning id into v_b1;
    insert into erp.batch (tenant_id, item_id, batch_number) values (rb.tenant_id, v_batched, 'ZRLP-B2')
    returning id into v_b2;
    -- Batches the order's lines are not: another product's, and one of the
    -- plain product from before it stopped being batch-controlled.
    insert into erp.batch (tenant_id, item_id, batch_number) values
      (rb.tenant_id, v_other, 'ZRLP-OTHER'),
      (rb.tenant_id, v_plain, 'ZRLP-PLAIN');

    v_sa := erp_test.cash_payment_supplier('ZRLPA');
    v_po := erp.open_document('purchase_order', v_sa, v_entity, v_site);
    perform erp.add_document_line(v_po, v_batched, 10, 1500, 'serum for ZRLP');
    perform erp.add_document_line(v_po, v_plain, 4, 900, 'boxes for ZRLP');
    perform erp.transition_document(v_po, 'submit', null);
    perform erp_test.approve_document(v_po, 'received line places suite');
    perform erp.transition_document(v_po, 'send', null);
    select l.id into v_lb from erp.document_line l where l.document_id = v_po and l.item_id = v_batched;
    select l.id into v_lp from erp.document_line l where l.document_id = v_po and l.item_id = v_plain;

    v_rows := public.erp_receivable_lines(v_po);
    select x into v_rb from jsonb_array_elements(v_rows) x where x ->> 'line_id' = v_lb::text;
    select x into v_rp from jsonb_array_elements(v_rows) x where x ->> 'line_id' = v_lp::text;

    -- ── 1. The order's site, less despatch and in transit ───────────────────
    v_step := 'reading the places each line is offered';
    select coalesce(array_agg(l.code order by l.code), '{}') into v_want
      from erp.location l
     where l.tenant_id = rb.tenant_id and l.site_id = v_site and l.status = 'active'
       and l.location_type not in ('despatch', 'transit');
    select coalesce(array_agg(x ->> 'code' order by x ->> 'code'), '{}') into v_got_b
      from jsonb_array_elements(v_rb -> 'locations') x;
    select coalesce(array_agg(x ->> 'code' order by x ->> 'code'), '{}') into v_got_p
      from jsonb_array_elements(v_rp -> 'locations') x;
    v_cases := v_cases + 1;
    case_name := 'each line is offered the active locations of the order''s site and no other: not despatch, not in transit, not one no longer used, not another site''s';
    passed := v_state is null
          and jsonb_array_length(v_rows) = 2
          and 'ZRLP-BULK' = any(v_got_b)
          and v_got_b = v_want and v_got_p = v_want
          and not (v_got_b && array['ZRLP-DESP', 'ZRLP-VAN', 'ZRLP-OLD', 'ZRLP-AWAY']);
    detail := coalesce(v_state, left(format('wanted %s; batched line %s; plain line %s', v_want, v_got_b, v_got_p), 500));
    return next;

    -- ── 2. The product's batches, and none for a plain product ──────────────
    v_step := 'reading the batches each line is offered';
    select coalesce(array_agg(x ->> 'batch_number' order by x ->> 'batch_number'), '{}') into v_got_b
      from jsonb_array_elements(v_rb -> 'batches') x;
    v_cases := v_cases + 1;
    case_name := 'a batch-controlled line is offered its own product''s batches and no other product''s; a line whose product is not batch-controlled is offered none';
    passed := v_state is null
          and v_got_b = array['ZRLP-B1', 'ZRLP-B2']
          and jsonb_typeof(v_rp -> 'batches') = 'array'
          and jsonb_array_length(v_rp -> 'batches') = 0
          and (v_rb ->> 'batch_controlled')::boolean
          and not (v_rp ->> 'batch_controlled')::boolean;
    detail := coalesce(v_state, left(format('batched %s; plain %s', v_got_b, v_rp -> 'batches'), 500));
    return next;

    -- ── 3. What is offered is what receiving takes ──────────────────────────
    v_step := 'receiving the order with an offered place and batch';
    v_r := public.erp_create_receipt_from_order(v_po, jsonb_build_array(
             jsonb_build_object('line_id', v_lb, 'quantity', 6, 'location_id', v_bulk, 'batch_id', v_b2),
             jsonb_build_object('line_id', v_lp)));
    select dl.location_id, dl.batch_id into v_line
      from erp.document_line dl
     where dl.document_id = (v_r ->> 'document_id')::uuid and dl.item_id = v_batched;
    v_cases := v_cases + 1;
    case_name := 'a receipt raised with an offered location and batch holds them, and the plain line with none goes as it always has';
    passed := v_state is null
          and v_line.location_id = v_bulk
          and v_line.batch_id = v_b2
          and (v_r ->> 'lines')::integer = 2;
    detail := coalesce(v_state, left(format('%s | line %s/%s', v_r, v_line.location_id, v_line.batch_id), 500));
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
    raise exception 'CLOVEERP_RECEIVED_LINE_PLACES_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.received_line_places_suite() from public, anon;

comment on function erp_test.received_line_places_suite() is
  'A received line offers its own places (20261007030000, J-58): erp_receivable_lines offers each line the '
  'order''s site''s active locations less despatch and in transit, and its own product''s batches, none when '
  'the product is not batch-controlled; a receipt raised with what is offered holds it.';

create or replace function erp_test.assert_received_line_places_suite()
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
    from erp_test.received_line_places_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_RECEIVED_LINE_PLACES_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A line to receive is offered another site''s place or another product''s batch. Read the case that failed.';
  end if;
  if v_total <> 3 then
    raise exception 'CLOVEERP_RECEIVED_LINE_PLACES_SUITE_SHRANK: % case(s), expected 3', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('a received line offers its own places: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_received_line_places_suite() from public, anon;

comment on function erp_test.assert_received_line_places_suite() is
  'erp_receivable_lines offers each line the order''s site''s places and its own product''s batches '
  '(20261007030000).';

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
