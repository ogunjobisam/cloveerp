set lock_timeout = '30s';

-- =============================================================================
-- 20260922330000  A line is priced where no margin chain is installed
-- -----------------------------------------------------------------------------
-- A review of PR3 after it was green found that W2 (20260922210000) broke the
-- Price button for most organisations. Reproduced on a built database: an
-- organisation with finance, inventory and sales configured, an item with a
-- list price and no cost at the site, a sales order line — and
-- erp.price_document_line() refused with
--
--   CLOVEERP_NO_APPROVAL_CHAIN: nothing routes document_line under these
--   conditions
--
-- W2 asked erp.request_approval() whenever erp.check_margin() said a price was
-- outside policy, and check_margin() says so for any item with no cost at the
-- site and for any price below cost where no pricing policy exists. But the
-- margin_exception chain and the default pricing policy are installed only by
-- erp.configure_sales_controls(), which runs from one optional button on the
-- configuration screen and from two suites — no pack, no onboarding step and no
-- seeder calls it. The demonstration has no document_line chain and no pricing
-- policy. So a line that priced before PR3 was refused after it, and the one
-- suite that proved W2 always configured the controls first, so it could not
-- see this.
--
-- The rule the product already applies to documents is the right one here: a
-- type with no chain approves on its permission. A margin that nobody has been
-- given the job of approving is not a question anybody can be asked. So the
-- request is made only where erp.select_approval_chain() finds a chain for it,
-- with the same context the request itself would carry.
--
-- ── AND THE COMMENT IS CORRECTED ─────────────────────────────────────────────
--
-- 20260922300000 wrote into this function that "PL/pgSQL does not short-circuit
-- AND — the whole condition is one SQL expression and m.within_policy is read to
-- bind it before any of it runs". That is not why it raised. PL/pgSQL plans an
-- IF the first time it is reached in a connection, and planning needs the type
-- of every record field the condition names; an unassigned RECORD has no type,
-- so it raises then. Once the plan exists — built on an earlier call where the
-- record held a row — the cached plan fetches its parameters lazily and AND does
-- short-circuit. Proved with a pg_temp function: first call with the record
-- unassigned raises; a call that assigns it and then one that does not, both
-- succeed. It is also why margin_floor_suite's purchase case passed against the
-- broken guard (it priced four sales lines first) while purchase_pricing_suite
-- failed (its first line was a purchase line), and why in production the broken
-- guard's behaviour depended on what kind of line a pooled connection happened
-- to price first. The nested IF was the right fix for the right reason; the
-- comment gave the wrong one.
--
-- ── WHAT THIS DOES NOT DO ────────────────────────────────────────────────────
--
-- The same review found that nothing consumes a document_line approval request:
-- no transition, line or document is held by a pending or refused margin
-- exception, and erp.add_document_line() — the ordinary way a line is entered —
-- prices from erp.resolve_price() without asking erp.check_margin() at all, so
-- the request is raised only when somebody presses Price. W2's own specification
-- is "below the floor, request the margin_exception chain", which is what it
-- does; holding the order on the answer is a decision about what the product
-- enforces, and it is not taken here.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. Asked only where something routes the question
-- ═════════════════════════════════════════════════════════════════════════════

do $price$
declare
  v_sig constant text := 'erp.price_document_line(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old_dec constant text := E'  m        record;\n';
  v_new_dec constant text := E'  m        record;\n  v_margin_ctx jsonb;\n';
  v_old constant text :=
       E'  -- Nested, not conjoined (20260922300000). erp.check_margin() is called only\n'
    || E'  -- in the sales arm, so on a purchase line m was never selected into, and a\n'
    || E'  -- record in that state raises when a field is read. PL/pgSQL does not\n'
    || E'  -- short-circuit AND — the whole condition is one SQL expression and\n'
    || E'  -- m.within_policy is read to bind it before any of it runs — so the outer\n'
    || E'  -- test has to be its own IF. There is no margin on a price we pay.\n'
    || E'  if v_base not in (''purchase_order'', ''requisition'', ''return_to_supplier'') then\n'
    || E'  if not m.within_policy then\n'
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
    || E'  end if;\n';
  v_new constant text :=
       E'  -- Nested, not conjoined (20260922300000; the reason corrected at\n'
    || E'  -- 20260922330000). erp.check_margin() is called only in the sales arm, so\n'
    || E'  -- on a purchase line m was never selected into. PL/pgSQL plans an IF the\n'
    || E'  -- first time it is reached in a connection, and planning needs the type of\n'
    || E'  -- every record field the condition names, so an unassigned record raises\n'
    || E'  -- at planning, before any AND can short-circuit. The outer test is its own\n'
    || E'  -- IF so the inner one is only ever planned where m holds a row. There is no\n'
    || E'  -- margin on a price we pay.\n'
    || E'  if v_base not in (''purchase_order'', ''requisition'', ''return_to_supplier'') then\n'
    || E'  if not m.within_policy then\n'
    || E'    v_margin_ctx := jsonb_build_object(\n'
    || E'      ''unit_price_minor'', pr.amount_minor,\n'
    || E'      ''cost_minor'', m.cost_minor,\n'
    || E'      ''margin_pct'', m.margin_pct,\n'
    || E'      ''policy_code'', m.policy_code,\n'
    || E'      ''reason'', m.message,\n'
    || E'      ''document_id'', l.document_id,\n'
    || E'      ''item_id'', l.item_id,\n'
    || E'      ''party_id'', d.party_id,\n'
    || E'      ''entity_id'', d.entity_id,\n'
    || E'      ''site_id'', d.site_id);\n'
    || E'    -- Asked only where a chain routes the question (20260922330000). A\n'
    || E'    -- margin nobody has been given the job of approving is not a question\n'
    || E'    -- anybody can be asked, and the rule the product applies to documents —\n'
    || E'    -- a type with no chain approves on its permission — applies here too.\n'
    || E'    if erp.select_approval_chain(''document_line'', v_margin_ctx, d.entity_id, d.site_id) is not null then\n'
    || E'      perform erp.request_approval(''document_line'', p_line_id, v_margin_ctx, 1,\n'
    || E'                                   d.entity_id, d.site_id);\n'
    || E'    end if;\n'
    || E'  end if;\n'
    || E'  end if;\n';
  v_hits integer;
begin
  if position('20260922330000' in v_def) > 0 then
    raise exception 'CLOVEERP_MARGIN_GUARD_UNRECOGNISED: % already asks only where a chain routes the question', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old_dec, ''))) / length(v_old_dec);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_MARGIN_GUARD_UNRECOGNISED: % declares its margin record % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_MARGIN_GUARD_UNRECOGNISED: % asks for a margin approval % time(s) in the shape 20260922300000 left, not once', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  execute replace(replace(v_def, v_old_dec, v_new_dec), v_old, v_new);
end
$price$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The case the suite could not see
-- ═════════════════════════════════════════════════════════════════════════════
--
-- erp_test.margin_floor_suite() always installed the sales controls first, so it
-- could only ever look at an organisation that has the chain. The new case is a
-- second organisation that does not — the reviewers' reproduction, as a case.

do $suite$
declare
  v_sig constant text := 'erp_test.margin_floor_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old_pin constant text := E'  c_expected constant integer := 6;\n';
  v_new_pin constant text := E'  c_expected constant integer := 7;\n';
  v_old_dec constant text := E'  v_fixture text;\n';
  v_new_dec constant text :=
       E'  v_fixture text;\n'
    || E'  -- The organisation with no margin chain (20260922330000).\n'
    || E'  a2 uuid := gen_random_uuid(); r2 record; v_cs2 uuid;\n'
    || E'  v_uom2 uuid; v_site2 uuid; v_cust2 uuid; v_nc uuid; v_so2 uuid; v_l2 uuid;\n'
    || E'  v_n2 integer; v_refused2 text;\n';
  v_old_case constant text := E'\n  raise exception ''CLOVEERP_SUITE_UNDO'';\n';
  v_new_case constant text :=
       E'\n'
    || E'  -- ── An organisation that installed no margin chain (20260922330000) ───\n'
    || E'  -- W2 refused the Price button here: check_margin() says an item with no\n'
    || E'  -- cost is outside policy, and nothing routes a document_line approval\n'
    || E'  -- because erp.configure_sales_controls() was never run. Most\n'
    || E'  -- organisations are this one.\n'
    || E'  select * into r2 from erp.provision_tenant(\n'
    || E'    ''zz-mgn2-'' || v_hex, ''Margin floor suite, no controls'',\n'
    || E'    ''admin@zz-mgn2-'' || v_hex || ''.test'', ''Margin Floor Admin'');\n'
    || E'  perform set_config(''request.jwt.claims'', json_build_object(''sub'', a2)::text, true);\n'
    || E'  perform erp.claim_invitation(r2.admin_token);\n'
    || E'  v_cs2 := erp.configure_finance();            perform erp_test.promote_if_pending(v_cs2);\n'
    || E'  v_cs2 := erp.configure_inventory(''average''); perform erp_test.promote_if_pending(v_cs2);\n'
    || E'  v_cs2 := erp.configure_sales();              perform erp_test.promote_if_pending(v_cs2);\n'
    || E'  insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)\n'
    || E'  values (r2.tenant_id, ''EA'', ''Each'', ''quantity'', 0, true, ''active'') returning id into v_uom2;\n'
    || E'  insert into erp.site (tenant_id, entity_id, code, name, site_type, status)\n'
    || E'  values (r2.tenant_id, r2.entity_id, ''MAIN'', ''Main'', ''warehouse'', ''active'') returning id into v_site2;\n'
    || E'  insert into erp.party (tenant_id, code, name, status)\n'
    || E'  values (r2.tenant_id, ''CUST'', ''Customer'', ''active'') returning id into v_cust2;\n'
    || E'  insert into erp.party_role (tenant_id, party_id, role_kind, status)\n'
    || E'  values (r2.tenant_id, v_cust2, ''customer'', ''active'');\n'
    || E'  insert into erp.item (tenant_id, code, name, stock_uom_id, status)\n'
    || E'  values (r2.tenant_id, ''NOCOST'', ''An item nobody has costed'', v_uom2, ''active'') returning id into v_nc;\n'
    || E'  insert into erp.item_price (tenant_id, item_id, price_kind, amount_minor, currency, per_quantity, valid_from)\n'
    || E'  values (r2.tenant_id, v_nc, ''sales_list'', 2000, ''GBP'', 1, current_date - 1);\n'
    || E'  v_so2 := erp.open_document(''sales_order'', v_cust2, r2.entity_id, v_site2);\n'
    || E'  v_l2 := erp.add_document_line(v_so2, v_nc, 10, null, ''an item nobody has costed'');\n'
    || E'  v_refused2 := null;\n'
    || E'  begin\n'
    || E'    perform erp.price_document_line(v_l2);\n'
    || E'  exception when others then\n'
    || E'    v_refused2 := sqlerrm;\n'
    || E'  end;\n'
    || E'  select count(*) into v_n2 from erp.approval_request ar\n'
    || E'   where ar.tenant_id = r2.tenant_id and ar.object_type = ''document_line'' and ar.object_id = v_l2;\n'
    || E'\n'
    || E'  v_cases := v_cases + 1;\n'
    || E'  case_name := ''an organisation that installed no margin chain prices the line as it always did, and asks nobody'';\n'
    || E'  passed := v_refused2 is null and v_n2 = 0\n'
    || E'        and not exists (select 1 from erp.approval_chain c\n'
    || E'                         where c.tenant_id = r2.tenant_id and c.object_type = ''document_line'');\n'
    || E'  detail := coalesce(''pricing was refused: '' || left(v_refused2, 90),\n'
    || E'                     format(''priced, with %s request(s) and no document_line chain installed'', v_n2));\n'
    || E'  return next;\n'
    || E'\n'
    || E'  raise exception ''CLOVEERP_SUITE_UNDO'';\n';
  v_old_undo constant text :=
    E'  passed := not exists (select 1 from erp.tenant where code = ''zz-mgn-'' || v_hex)\n';
  v_new_undo constant text :=
    E'  passed := not exists (select 1 from erp.tenant where code in (''zz-mgn-'' || v_hex, ''zz-mgn2-'' || v_hex))\n';
  v_hits integer;
begin
  if position('20260922330000' in v_def) > 0 then
    raise exception 'CLOVEERP_SUITE_UNRECOGNISED: % already holds the no-chain case', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old_pin, ''))) / length(v_old_pin);
  if v_hits <> 1 then raise exception 'CLOVEERP_SUITE_UNRECOGNISED: % pins six cases % time(s)', v_sig, v_hits; end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old_dec, ''))) / length(v_old_dec);
  if v_hits <> 1 then raise exception 'CLOVEERP_SUITE_UNRECOGNISED: % declares v_fixture % time(s)', v_sig, v_hits; end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old_case, ''))) / length(v_old_case);
  if v_hits <> 1 then raise exception 'CLOVEERP_SUITE_UNRECOGNISED: % raises its undo % time(s)', v_sig, v_hits; end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old_undo, ''))) / length(v_old_undo);
  if v_hits <> 1 then raise exception 'CLOVEERP_SUITE_UNRECOGNISED: % checks its undo % time(s)', v_sig, v_hits; end if;

  execute replace(replace(replace(replace(v_def, v_old_pin, v_new_pin), v_old_dec, v_new_dec),
                          v_old_case, v_new_case), v_old_undo, v_new_undo);
end
$suite$;

do $pin$
declare
  v_sig constant text := 'erp_test.assert_margin_floor_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
       E'  if v_total <> 6 then\n'
    || E'    raise exception ''CLOVEERP_MARGIN_FLOOR_SUITE_SHRANK: % case(s), expected 6'', v_total\n';
  v_new constant text :=
       E'  if v_total <> 7 then\n'
    || E'    raise exception ''CLOVEERP_MARGIN_FLOOR_SUITE_SHRANK: % case(s), expected 7'', v_total\n';
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_WRAPPER_UNRECOGNISED: % pins six cases % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body. If the count has moved since, re-anchor on what it is now.';
  end if;
  execute replace(v_def, v_old, v_new);
end
$pin$;

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
