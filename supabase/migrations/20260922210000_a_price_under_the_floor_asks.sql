set lock_timeout = '30s';

-- =============================================================================
-- 20260922210000  A price under the floor asks the chain the policy names
-- -----------------------------------------------------------------------------
-- W2 of the simplification plan. erp.price_document_line() prices a sales line
-- from the price list, asks erp.check_margin() what that price does to the
-- margin, assigns the answer into `m` — and never reads it
-- (20260829280000_sales_depth.sql:239).
--
-- Everything the answer would be used for exists and is configured:
--
--   * erp.pricing_policy carries min_margin_pct, allow_below_cost and
--     approval_chain, and erp.configure_sales_controls() seeds the default
--     policy naming the margin_exception chain;
--   * the margin_exception chain is installed by the same function, on
--     object_type document_line, with unit_price_minor as its material field
--     and one step at the commercial role;
--   * erp.check_margin() works, and is careful in the way that matters — an
--     item with no cost at the site is NOT a pass, because "a margin check that
--     silently succeeds when it cannot be answered is worse than no margin
--     check, because somebody will believe it".
--
-- So the floor is configured, the chain is installed, the check runs, and the
-- result is dropped on the floor. A customer can be quoted below cost and
-- nobody is asked.
--
-- ── WHERE THE REQUEST GOES ───────────────────────────────────────────────────
--
-- After the line is written, not before. The chain's material field is
-- unit_price_minor, and erp.check_reapproval_required() fingerprints the
-- context against it — so the context has to carry the price that was actually
-- written, or an approval would stand against a figure the line does not hold.
--
-- On the line, not the document. The chain says object_type document_line, and
-- it is the line that is under the floor: a document can carry twenty lines of
-- which one is the problem, and asking about the document would tell the
-- approver the wrong thing.
--
-- ── WHAT IS DELIBERATELY NOT SOFTENED ────────────────────────────────────────
--
-- An item with no cost at the site raises the exception, like any other line
-- the policy cannot vouch for. That is erp.check_margin()'s own decision and
-- this node does not overturn it: an organisation that has not costed an item
-- is told so by being asked, which is the only signal that reaches anybody.
--
-- The purchase branch asks nothing, because there is no margin on a price we
-- pay. The guard is on v_base rather than on `m`: erp.check_margin() is not
-- called on that branch, and a plpgsql record that has never been selected into
-- RAISES when a field is read — it does not come back null. The first version
-- of this node guarded on `m.within_policy is not null` and fell over on the
-- first purchase line, which erp_test.margin_floor_suite()'s fifth case found
-- within a minute of being written. On the sales branch `m` is always assigned,
-- because the select into it is unconditional once the price is resolved.
-- =============================================================================

do $wire$
declare
  v_sig constant text := 'erp.price_document_line(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_tail_old constant text :=
       E'   where id = p_line_id;\n'
    || E'\n'
    || E'  return pr.amount_minor;\n';
  v_tail_new constant text :=
       E'   where id = p_line_id;\n'
    || E'\n'
    || E'  -- The margin answer, which was computed and thrown away until\n'
    || E'  -- 20260922210000. Asked after the line is written, because the chain''s\n'
    || E'  -- material field is unit_price_minor and an approval has to stand against\n'
    || E'  -- the figure the line actually holds.\n'
    || E'  --\n'
    || E'  -- Guarded on v_base, not on m. erp.check_margin() is not called on the\n'
    || E'  -- purchase branch, and a record that was never selected into raises when a\n'
    || E'  -- field is read rather than reading as null. There is no margin on a price\n'
    || E'  -- we pay.\n'
    || E'  if v_base not in (''purchase_order'', ''requisition'', ''return_to_supplier'')\n'
    || E'     and not m.within_policy then\n'
    || E'    perform erp.request_approval(\n'
    || E'      ''document_line'', p_line_id,\n'
    || E'      jsonb_build_object(\n'
    || E'        ''unit_price_minor'', pr.amount_minor,\n'
    || E'        ''cost_minor'', m.cost_minor,\n'
    || E'        ''margin_pct'', m.margin_pct,\n'
    || E'        ''policy_code'', m.policy_code,\n'
    || E'        ''reason'', m.message,\n'
    || E'        ''document_id'', l.document_id,\n'
    || E'        ''item_id'', l.item_id,\n'
    || E'        ''party_id'', d.party_id,\n'
    || E'        ''entity_id'', d.entity_id,\n'
    || E'        ''site_id'', d.site_id),\n'
    || E'      1, d.entity_id, d.site_id);\n'
    || E'  end if;\n'
    || E'\n'
    || E'  return pr.amount_minor;\n';
  v_hits integer;
begin
  if position('20260922210000' in v_def) > 0 then
    raise exception
      'CLOVEERP_PRICING_UNRECOGNISED: % already asks when a price is under the floor', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;

  if position('not m.within_policy' in v_def) > 0 then
    raise exception
      'CLOVEERP_PRICING_UNRECOGNISED: % already reads the margin answer', v_sig
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_tail_old, ''))) / length(v_tail_old);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_PRICING_UNRECOGNISED: % writes the line and returns % time(s), not once',
      v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  execute replace(v_def, v_tail_old, v_tail_new);
end
$wire$;

-- ═════════════════════════════════════════════════════════════════════════════
-- The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Its own fixture. Every sales suite in the build passes with this node in and
-- passed without it, because none of them prices a line under the floor — which
-- is exactly why the result could be thrown away for a year without anything
-- noticing.

create or replace function erp_test.margin_floor_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_expected constant integer := 6;
  v_cases  integer := 0;
  v_hex    text := replace(gen_random_uuid()::text, '-', '');
  a1       uuid := gen_random_uuid();
  r        record; q record;
  v_cs     uuid;
  v_uom uuid; v_site uuid; v_cust uuid; v_sup uuid;
  v_under uuid; v_over uuid; v_uncosted uuid; v_bought uuid;
  v_so uuid; v_po uuid;
  v_l_under uuid; v_l_over uuid; v_l_uncosted uuid; v_l_buy uuid;
  v_status text; v_ctx jsonb;
  v_n_over integer; v_n_uncosted integer; v_n_buy integer;
  v_fixture text;
begin
  begin
  select * into r from erp.provision_tenant(
    'zz-mgn-' || v_hex, 'Margin floor suite',
    'admin@zz-mgn-' || v_hex || '.test', 'Margin Admin');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);

  v_cs := erp.configure_finance();            perform erp_test.promote_if_pending(v_cs);
  v_cs := erp.configure_inventory('average'); perform erp_test.promote_if_pending(v_cs);
  v_cs := erp.configure_sales();              perform erp_test.promote_if_pending(v_cs);
  -- The floor and the chain it names.
  v_cs := erp.configure_sales_controls();     perform erp_test.promote_if_pending(v_cs);
  v_cs := erp.configure_procurement(1000000); perform erp_test.promote_if_pending(v_cs);

  insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
  values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
  insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
  values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'warehouse', 'active') returning id into v_site;
  insert into erp.party (tenant_id, code, name, status)
  values (r.tenant_id, 'CUST', 'Customer', 'active') returning id into v_cust;
  insert into erp.party_role (tenant_id, party_id, role_kind, status)
  values (r.tenant_id, v_cust, 'customer', 'active');
  insert into erp.party (tenant_id, code, name, status)
  values (r.tenant_id, 'SUP', 'Supplier', 'active') returning id into v_sup;
  insert into erp.party_role (tenant_id, party_id, role_kind, status)
  values (r.tenant_id, v_sup, 'supplier', 'active');

  -- Three items: one sold under its cost, one sold well over it, one with no
  -- cost at this site at all.
  insert into erp.item (tenant_id, code, name, stock_uom_id, status)
  values (r.tenant_id, 'UNDER', 'Sold under cost', v_uom, 'active') returning id into v_under;
  insert into erp.item (tenant_id, code, name, stock_uom_id, status)
  values (r.tenant_id, 'OVER', 'Sold over cost', v_uom, 'active') returning id into v_over;
  insert into erp.item (tenant_id, code, name, stock_uom_id, status)
  values (r.tenant_id, 'NOCOST', 'Never costed here', v_uom, 'active') returning id into v_uncosted;
  insert into erp.item (tenant_id, code, name, stock_uom_id, status)
  values (r.tenant_id, 'BUY', 'Bought in', v_uom, 'active') returning id into v_bought;

  insert into erp.item_cost (tenant_id, item_id, site_id, method, unit_cost_minor,
                             currency, quantity_on_hand, effective_from, value_minor)
  values (r.tenant_id, v_under, v_site, 'average', 1000, 'GBP', 0, current_date - 1, 0),
         (r.tenant_id, v_over,  v_site, 'average', 1000, 'GBP', 0, current_date - 1, 0);

  insert into erp.item_price (tenant_id, item_id, price_kind, amount_minor, currency,
                              per_quantity, valid_from)
  values (r.tenant_id, v_under,    'sales_list',    500, 'GBP', 1, current_date - 1),
         (r.tenant_id, v_over,     'sales_list',   5000, 'GBP', 1, current_date - 1),
         (r.tenant_id, v_uncosted, 'sales_list',   2000, 'GBP', 1, current_date - 1),
         (r.tenant_id, v_bought,   'purchase_list', 800, 'GBP', 1, current_date - 1);

  v_so := erp.open_document('sales_order', v_cust, r.entity_id, v_site);

  -- ── 1. A price under the floor asks ───────────────────────────────────────
  v_cases := v_cases + 1;
  v_l_under := erp.add_document_line(v_so, v_under, 10, null, 'sold under cost');
  perform erp.price_document_line(v_l_under);
  select ar.status::text, ar.context into v_status, v_ctx
    from erp.approval_request ar
   where ar.tenant_id = r.tenant_id and ar.object_type = 'document_line'
     and ar.object_id = v_l_under
   limit 1;
  case_name := 'a line priced under the floor asks the chain the pricing policy names';
  passed := v_status is not null
        and (v_ctx ->> 'unit_price_minor')::bigint = 500
        and (v_ctx ->> 'cost_minor')::bigint = 1000
        and v_ctx ->> 'policy_code' = 'default';
  detail := coalesce(format('%s request carrying %s', v_status, v_ctx ->> 'reason'),
                     'nothing was asked');
  return next;

  -- ── 2. And somebody is actually asked ─────────────────────────────────────
  -- A request that approves itself as raised would satisfy case 1 and mean
  -- nothing: the point of a floor is that a person agrees to go under it.
  v_cases := v_cases + 1;
  case_name := 'and the request waits on somebody: a floor nobody is asked about is not a floor';
  passed := v_status = 'pending'
        and exists (select 1 from erp.approval_task t
                     join erp.approval_request ar on ar.id = t.approval_request_id
                    where ar.tenant_id = r.tenant_id and ar.object_id = v_l_under
                      and t.status = 'pending');
  detail := format('the request is %s with %s task(s) waiting', v_status,
                   (select count(*) from erp.approval_task t
                      join erp.approval_request ar on ar.id = t.approval_request_id
                     where ar.tenant_id = r.tenant_id and ar.object_id = v_l_under
                       and t.status = 'pending'));
  return next;

  -- ── 3. A price above the floor asks nothing ───────────────────────────────
  -- The other half. A wiring that asked on every line would pass cases 1 and 2
  -- and be worse than no wiring at all.
  v_cases := v_cases + 1;
  v_l_over := erp.add_document_line(v_so, v_over, 10, null, 'sold well over cost');
  perform erp.price_document_line(v_l_over);
  select count(*) into v_n_over from erp.approval_request ar
   where ar.tenant_id = r.tenant_id and ar.object_type = 'document_line'
     and ar.object_id = v_l_over;
  case_name := 'a line priced well above the floor asks nobody';
  passed := v_n_over = 0;
  detail := format('%s request(s) on a line at 5000 against a cost of 1000', v_n_over);
  return next;

  -- ── 4. A margin that cannot be worked out is not a pass ───────────────────
  -- erp.check_margin() decided this, in those words, long before anything read
  -- its answer. Held here so that reading the answer does not quietly reverse it.
  v_cases := v_cases + 1;
  v_l_uncosted := erp.add_document_line(v_so, v_uncosted, 10, null, 'never costed here');
  perform erp.price_document_line(v_l_uncosted);
  select count(*) into v_n_uncosted from erp.approval_request ar
   where ar.tenant_id = r.tenant_id and ar.object_type = 'document_line'
     and ar.object_id = v_l_uncosted;
  case_name := 'an item with no cost at the site is asked about too: a margin that cannot be checked is not within policy';
  passed := v_n_uncosted = 1;
  detail := format('%s request(s) on an item nobody has costed here', v_n_uncosted);
  return next;

  -- ── 5. A purchase line asks nothing ───────────────────────────────────────
  -- There is no margin on a price we pay, and erp.check_margin() is not called
  -- on that branch, so the guard has to read as null rather than as false.
  v_cases := v_cases + 1;
  v_po := erp.open_document('purchase_order', v_sup, r.entity_id, v_site);
  v_l_buy := erp.add_document_line(v_po, v_bought, 10, null, 'bought in');
  perform erp.price_document_line(v_l_buy);
  select count(*) into v_n_buy from erp.approval_request ar
   where ar.tenant_id = r.tenant_id and ar.object_type = 'document_line'
     and ar.object_id = v_l_buy;
  case_name := 'a purchase line asks nobody about margin, because there is none on a price we pay';
  passed := v_n_buy = 0;
  detail := format('%s request(s) on a purchase line', v_n_buy);
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_fixture := left(sqlerrm, 300);
    end if;
  end;

  -- ── 6. Undone ─────────────────────────────────────────────────────────────
  perform set_config('request.jwt.claims', '', true);
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone, and nothing in it stopped early';
  passed := not exists (select 1 from erp.tenant where code = 'zz-mgn-' || v_hex)
        and v_fixture is null;
  detail := coalesce('the fixture stopped early: ' || v_fixture,
                     'the organisation rolled back with its orders and its price lists');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_MARGIN_FLOOR_SUITE_SHRANK: % case(s), expected % — %',
      v_cases, c_expected, coalesce(v_fixture, 'a case was added or lost');
  end if;
end;
$$;

create or replace function erp_test.assert_margin_floor_suite()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_failed integer; v_total integer; v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)), count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ')
           filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.margin_floor_suite() s;

  if v_total <> 6 then
    raise exception 'CLOVEERP_MARGIN_FLOOR_SUITE_SHRANK: % case(s), expected 6', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;

  if v_failed > 0 then
    raise exception 'CLOVEERP_MARGIN_FLOOR_SUITE_FAILED: %/% case(s) failed%',
      v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A price under the floor that nobody is asked about is a discount the company did not agree to give.';
  end if;
end;
$$;

comment on function erp_test.margin_floor_suite() is
  'A price under the margin floor asks the chain the pricing policy names, and a price above it asks nobody.';

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
