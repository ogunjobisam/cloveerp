set lock_timeout = '30s';

-- =============================================================================
-- 20260922120000  A count inside either tolerance passes
-- -----------------------------------------------------------------------------
-- Node C5 of the simplification plan (docs/spec/simplification-review.md).
--
-- erp.record_count() decided a variance was within tolerance only when it was
-- inside the absolute tolerance AND inside the percentage one:
--
--   v_ok := abs(v_var) <= pg.tolerance_absolute
--           and (v_expect = 0 or
--                abs(v_var) * 100.0 / abs(v_expect) <= pg.tolerance_pct);
--
-- Two thresholds joined by AND are one threshold: whichever is tighter decides,
-- and for any quantity worth counting that is the absolute one. The percentage
-- can narrow what passes and can never widen it, which is the opposite of what
-- a percentage band is for.
--
-- The base pack shows the cost. CYCLE_C is the low-value band — "so a five-pence
-- washer does not raise the same exception as a pallet of finished goods" — at
-- 10 units and 5 per cent. A hundred units out on ten thousand washers is one
-- per cent, well inside the band written for exactly that case, and the absolute
-- refuses it anyway. CYCLE_A, at 1 and 1, refuses five units on ten thousand.
--
-- ── WHAT THE OLD COMMENT SAID, AND WHY IT IS NOT AN OBJECTION ────────────────
--
-- The line carried a rationale: "Inside both tolerances, or inside the only one
-- that was configured. A variance of two on ten thousand and a variance of two
-- on two are different events and one threshold cannot say so." That last
-- sentence is true and is the argument for HAVING two thresholds. It is not an
-- argument for ANDing them: under AND the second threshold never decides
-- anything the first has not already decided more tightly. Under OR both are
-- live — the absolute forgives a small variance on a small quantity, the
-- percentage forgives a proportionate one on a large quantity — which is what
-- the sentence describes.
--
-- ── THE CLAUSE THAT HAD TO INVERT WITH THE CONNECTOR ─────────────────────────
--
-- `v_expect = 0 or …` is a guard against dividing by zero, not a tolerance.
-- Under AND it correctly lets the percentage test stand aside when there is
-- nothing to take a percentage of, leaving the absolute to decide alone.
--
-- Flipping the connector and leaving that clause is a defect, not a
-- simplification: `abs_ok or (v_expect = 0 or pct_ok)` is TRUE for every count
-- of a location the records say is empty, however much was found there. Fifty
-- units where none were expected would be recorded as within tolerance and
-- approved without a person. The clause inverts with the connector, so that a
-- percentage of nothing decides nothing:
--
--   or (v_expect <> 0 and …)
--
-- Case 4 below is that count, and it fails against the naive flip.
--
-- ── WHAT IS DELIBERATELY NOT CHANGED ─────────────────────────────────────────
--
-- The plan also asks for STOCKTAKE to be given non-zero defaults. It is not
-- touched. Its zero is a decision with its reason written beside it in the base
-- pack — "Zero tolerance: an annual count is the number" — and overriding that
-- is the owner's call, not this node's. It is also load-bearing:
-- erp_test.controls_finish_suite() counts 45 against an expected 50 under
-- STOCKTAKE and depends on that reaching approval. Under the new rule it still
-- does: 5 <= 0 is false, and 10 per cent <= 0 is false. Case 5 holds that.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. Either tolerance, not both
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Patched into the deployed body by counted replacement. erp.record_count() is
-- created once, by 20260829240000, and nothing since has replaced it, so the
-- needle is that file's text; it is asserted to occur exactly once. The comment
-- goes with the expression, because a comment that argues for the old rule is
-- worse than none.

do $tolerance$
declare
  v_sig constant text := 'erp.record_count(uuid,numeric)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
       E'  -- Inside both tolerances, or inside the only one that was configured. A\n'
    || E'  -- variance of two on ten thousand and a variance of two on two are different\n'
    || E'  -- events and one threshold cannot say so.\n'
    || E'  v_ok := abs(v_var) <= pg.tolerance_absolute\n'
    || E'          and (v_expect = 0 or\n'
    || E'               abs(v_var) * 100.0 / abs(v_expect) <= pg.tolerance_pct);\n';
  v_new constant text :=
       E'  -- Inside either tolerance. Two thresholds joined by AND are one threshold:\n'
    || E'  -- the tighter decides and the other never widens anything, so a percentage\n'
    || E'  -- band written for a large quantity could not forgive a proportionate\n'
    || E'  -- variance on one (20260922120000). The absolute forgives a small variance\n'
    || E'  -- on a small quantity; the percentage forgives a proportionate one on a\n'
    || E'  -- large quantity; a programme that configures only one is decided by it.\n'
    || E'  --\n'
    || E'  -- v_expect <> 0 and not v_expect = 0: the percentage is a guard against\n'
    || E'  -- dividing by nothing, never a tolerance. Under OR, a clause that passed\n'
    || E'  -- when there was nothing to take a percentage of would pass every count of\n'
    || E'  -- a location the records call empty, whatever was found in it.\n'
    || E'  v_ok := abs(v_var) <= pg.tolerance_absolute\n'
    || E'          or (v_expect <> 0 and\n'
    || E'              abs(v_var) * 100.0 / abs(v_expect) <= pg.tolerance_pct);\n';
  v_hits integer;
begin
  if position('v_expect <> 0 and' in v_def) > 0 then
    raise exception
      'CLOVEERP_RECORD_COUNT_UNRECOGNISED: % already reads either tolerance; this migration '
      'would patch it twice', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_RECORD_COUNT_UNRECOGNISED: % joins its tolerances % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  execute replace(v_def, v_old, v_new);
end
$tolerance$;

comment on function erp.record_count(uuid, numeric) is
  'Records a counted quantity against an open count task and says where it '
  'left the task. A variance inside either the programme''s absolute tolerance '
  'or its percentage one is within tolerance; outside both it goes to the '
  'programme''s approval chain, or stops at counted where it has none.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Proved on the bands the base pack ships
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The fixture is an organisation with one counted item and ten thousand of it,
-- and the base pack's own CYCLE_A (1 and 1) and STOCKTAKE (0 and 0) promoted
-- through a change set, so the suite tests the bands a customer gets rather
-- than bands it invented for itself.

create or replace function erp_test.count_tolerance_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases  integer := 0;
  v_hex    text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1       uuid := gen_random_uuid();
  r        record;
  it       record;
  v_uom    uuid; v_site uuid; v_recv uuid; v_sup uuid; v_item uuid; v_item2 uuid;
  v_cs     uuid; v_grn uuid;
  v_task   uuid; v_zero uuid;
  v_status text; v_status_big text; v_status_zero text; v_status_stock text;
  v_abs    numeric; v_pct numeric;
  v_within boolean; v_within_zero boolean;
  v_fixture text;
begin
  begin
  select * into r from erp.provision_tenant(
    'zz-tol-' || v_hex, 'Count tolerance suite',
    'admin@zz-tol-' || v_hex || '.test', 'Tolerance Admin');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);

  -- Finance first: inventory valuation reconciles to a chart of accounts, and
  -- erp.configure_inventory() refuses an organisation that has none.
  v_cs := erp.configure_finance();
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  v_cs := erp.configure_inventory('average');
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  -- Procurement, because the stock the count counts arrives on a goods receipt
  -- and the document type comes with the module.
  v_cs := erp.configure_procurement(1000000);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);

  insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
  values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
  insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
  values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'warehouse', 'active') returning id into v_site;
  insert into erp.location (tenant_id, site_id, code, name, location_type, status)
  values (r.tenant_id, v_site, 'RECV', 'Goods in', 'receiving', 'active') returning id into v_recv;
  insert into erp.party (tenant_id, code, name, status)
  values (r.tenant_id, 'SUP', 'Supplier', 'active') returning id into v_sup;
  insert into erp.party_role (tenant_id, party_id, role_kind, status)
  values (r.tenant_id, v_sup, 'supplier', 'active');
  insert into erp.item (tenant_id, code, name, stock_uom_id, status)
  values (r.tenant_id, 'CNT', 'Counted widget', v_uom, 'active') returning id into v_item;
  -- A second item, so the stocktake case counts stock the cycle-count cases
  -- have not already raised and closed a task against.
  insert into erp.item (tenant_id, code, name, stock_uom_id, status)
  values (r.tenant_id, 'STK', 'Stocktaken widget', v_uom, 'active') returning id into v_item2;

  -- The bands as the base pack ships them, promoted the way a customer's own
  -- configuration change is promoted.
  v_cs := erp.create_change_set('zztol-bands-' || v_hex, 'Counting bands from the base pack',
                                'CYCLE_A and STOCKTAKE as the base pack plans them.');
  -- Read from erp_ref.pack_item rather than erp.plan_content_pack(): the
  -- planner offers CYCLE_A only to an organisation that has cycle counting,
  -- and this suite is about how a band is read, not about which bands an
  -- organisation is offered. The payloads are the pack's own, so the tolerances
  -- under test are the ones a customer gets.
  for it in
    select pi.object_kind, pi.object_key, pi.payload
      from erp_ref.pack_item pi
     where pi.pack_code = 'base' and pi.object_kind = 'count_programme'
       and pi.object_key in ('CYCLE_A', 'STOCKTAKE')
     order by pi.object_key
  loop
    perform erp.add_change_set_item(v_cs, it.object_kind, it.object_key, it.payload,
                                    'upsert', null, 'the count tolerance suite');
  end loop;
  perform erp.submit_change_set(v_cs);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);

  -- Ten thousand on hand, which is the quantity the bands were written about.
  -- The second item's stock arrives later, after the cycle-count cases. A
  -- programme does not raise a task against a position that already carries an
  -- open one, and CYCLE_A raises for every item it can see: received now, the
  -- second item would be claimed by the first CYCLE_A raise and STOCKTAKE would
  -- find nothing left to count.
  v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
  perform erp.add_document_line(v_grn, v_item, 10000, 100, 'stock to count');
  perform erp.transition_document(v_grn, 'post', 'count tolerance suite');

  -- ── 1. The fixture is the shape this suite is about ────────────────────────
  v_cases := v_cases + 1;
  select pg.tolerance_absolute, pg.tolerance_pct into v_abs, v_pct
    from erp.count_programme pg
   where pg.tenant_id = r.tenant_id and pg.code = 'CYCLE_A';
  select coalesce(sum(b.quantity), 0) into v_status_stock
    from erp.stock_balance b
   where b.tenant_id = r.tenant_id and b.item_id = v_item;
  case_name := 'the fixture holds ten thousand of one item, and CYCLE_A bands it at one unit and one per cent';
  passed := v_abs = 1 and v_pct = 1 and v_status_stock::numeric = 10000;
  detail := format('CYCLE_A absolute %s, percentage %s; %s on hand', v_abs, v_pct, v_status_stock);
  return next;

  -- ── 2. Five on ten thousand passes ─────────────────────────────────────────
  -- The node's own acceptance: inside the percentage, outside the absolute.
  v_cases := v_cases + 1;
  perform erp.raise_count_tasks('CYCLE_A');
  select t.id into v_task
    from erp.count_task t
    join erp.count_programme pg on pg.id = t.count_programme_id
   where t.tenant_id = r.tenant_id and t.item_id = v_item
     and t.status = 'open' and pg.code = 'CYCLE_A'
   limit 1;
  v_status := erp.record_count(v_task, 9995)::text;
  select t.within_tolerance into v_within
    from erp.count_task t where t.tenant_id = r.tenant_id and t.id = v_task;
  case_name := 'five units short on ten thousand is inside CYCLE_A''s percentage and passes, though it is outside its absolute';
  passed := v_status = 'approved' and v_within;
  detail := format('counted 9995 of 10000 under CYCLE_A: %s, within_tolerance %s', v_status, v_within);
  return next;

  -- ── 3. Outside both is outside ─────────────────────────────────────────────
  v_cases := v_cases + 1;
  -- Planted rather than raised. A programme does not raise against a position
  -- that already carries an open or undecided task, and whether case 2's task
  -- is still one of those is the very thing case 2 is asking about: raising
  -- here would turn a failure of case 2 into a missing task in case 3, and the
  -- build would report the cascade instead of the cause.
  insert into erp.count_task (
    tenant_id, count_programme_id, site_id, location_id, item_id,
    expected_quantity, movement_during, committed_quantity, status)
  select r.tenant_id, pg.id, v_site, v_recv, v_item, 10000, 0, 0, 'open'
    from erp.count_programme pg
   where pg.tenant_id = r.tenant_id and pg.code = 'CYCLE_A'
  returning id into v_task;
  v_status_big := erp.record_count(v_task, 9000)::text;
  select t.within_tolerance into v_within
    from erp.count_task t where t.tenant_id = r.tenant_id and t.id = v_task;
  case_name := 'a thousand short is outside both of CYCLE_A''s tolerances and is not within tolerance';
  passed := not coalesce(v_within, true);
  detail := format('counted 9000 of 10000 under CYCLE_A: %s, within_tolerance %s',
                   v_status_big, v_within);
  return next;

  -- ── 4. A percentage of nothing decides nothing ─────────────────────────────
  -- The case the naive flip fails. Expected nothing, found fifty: the absolute
  -- refuses it, and the percentage must not rescue it by dividing by zero.
  v_cases := v_cases + 1;
  insert into erp.count_task (
    tenant_id, count_programme_id, site_id, location_id, item_id,
    expected_quantity, movement_during, committed_quantity, status)
  select r.tenant_id, pg.id, v_site, v_recv, v_item, 0, 0, 0, 'open'
    from erp.count_programme pg
   where pg.tenant_id = r.tenant_id and pg.code = 'CYCLE_A'
  returning id into v_zero;
  v_status_zero := erp.record_count(v_zero, 50)::text;
  select t.within_tolerance into v_within_zero
    from erp.count_task t where t.tenant_id = r.tenant_id and t.id = v_zero;
  case_name := 'fifty found where the records expected none does not pass, because a percentage of nothing is not a tolerance';
  passed := v_status_zero <> 'approved' and not coalesce(v_within_zero, true);
  detail := format('counted 50 against an expected 0 under CYCLE_A: %s, within_tolerance %s',
                   v_status_zero, v_within_zero);
  return next;

  -- ── 5. STOCKTAKE still means the number ────────────────────────────────────
  -- Left at zero and zero deliberately. erp_test.controls_finish_suite() counts
  -- five short under it and depends on that being asked about.
  v_cases := v_cases + 1;
  v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
  perform erp.add_document_line(v_grn, v_item2, 10000, 100, 'stock to stocktake');
  perform erp.transition_document(v_grn, 'post', 'count tolerance suite');
  perform erp.raise_count_tasks('STOCKTAKE');
  -- Joined to the programme, not merely to the item: CYCLE_A was raised twice
  -- above and raises a task for every item, so "the first open task for this
  -- item" is a CYCLE_A task and this case would read STOCKTAKE's tolerances
  -- while exercising CYCLE_A's.
  select t.id into v_task
    from erp.count_task t
    join erp.count_programme pg on pg.id = t.count_programme_id
   where t.tenant_id = r.tenant_id and t.item_id = v_item2
     and t.status = 'open' and pg.code = 'STOCKTAKE'
   limit 1;
  if v_task is null then
    raise exception 'CLOVEERP_SUITE_FIXTURE: STOCKTAKE raised no open task for the second item';
  end if;
  v_status := erp.record_count(v_task, 9995)::text;
  select pg.tolerance_absolute, pg.tolerance_pct into v_abs, v_pct
    from erp.count_programme pg
   where pg.tenant_id = r.tenant_id and pg.code = 'STOCKTAKE';
  select t.within_tolerance into v_within
    from erp.count_task t where t.tenant_id = r.tenant_id and t.id = v_task;
  -- within_tolerance, not the status: the status after a variance is the
  -- approval chain's answer, and STOCKTAKE names count_variance, which a
  -- fixture with nobody to ask approves as it is raised (20260914070000).
  case_name := 'the annual stocktake is still the number: zero and zero, and five short is not within tolerance under it';
  passed := v_abs = 0 and v_pct = 0 and not coalesce(v_within, true);
  detail := format('STOCKTAKE absolute %s, percentage %s; counted 9995 of 10000: %s, within_tolerance %s',
                   v_abs, v_pct, v_status, v_within);
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_fixture := left(sqlerrm, 300);
    end if;
  end;

  -- ── 6. Undone ──────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone, and nothing in it stopped early';
  passed := not exists (select 1 from erp.tenant where code = 'zz-tol-' || v_hex)
        and v_fixture is null;
  detail := coalesce('the fixture stopped early: ' || v_fixture,
                     'the organisation rolled back with its stock and its count tasks');
  return next;

  if v_cases <> 6 then
    raise exception
      'CLOVEERP_SUITE_SHRANK: count_tolerance_suite ran % cases, expected 6%',
      v_cases, coalesce(' — the fixture stopped early: ' || v_fixture, '');
  end if;
end;
$$;

revoke all on function erp_test.count_tolerance_suite() from public, anon;

create or replace function erp_test.assert_count_tolerance_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_all  integer := 0;
  v_bad  integer := 0;
  v_msg  text := '';
  c      record;
begin
  for c in select * from erp_test.count_tolerance_suite() loop
    v_all := v_all + 1;
    if not c.passed then
      v_bad := v_bad + 1;
      v_msg := v_msg || E'\n  ' || c.case_name || ' — ' || coalesce(c.detail, '');
    end if;
  end loop;

  if v_all <> 6 then
    raise exception 'CLOVEERP_SUITE_SHRANK: count_tolerance_suite ran % cases, expected 6', v_all;
  end if;
  if v_bad > 0 then
    raise exception 'CLOVEERP_COUNT_TOLERANCE_SUITE_FAILED: %/% case(s) failed%', v_bad, v_all, v_msg;
  end if;
  return format('a count inside either tolerance passes: %s/%s cases passed', v_all, v_all);
end;
$$;

revoke all on function erp_test.assert_count_tolerance_suite() from public, anon;

-- CLOVEERP_COUNT_TOLERANCE_SUITE_FAILED is deliberately not registered. None of
-- the hundred and fifty-five suite-failure codes is: erp.register_refusal() is
-- for what the product says to a person using it, and a suite's verdict is said
-- to a build. Registering one makes erp.assert_refusals_name_next_action()
-- refuse it as a registered refusal nothing raises, because the register is read
-- against erp and public and a suite lives in erp_test.

-- The generators, which are idempotent and run at the end of every migration.
-- This file changes one expression in one routine and adds a suite; it creates
-- no table, no door and no policy.

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
