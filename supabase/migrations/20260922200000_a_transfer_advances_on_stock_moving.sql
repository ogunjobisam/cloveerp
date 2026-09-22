set lock_timeout = '30s';

-- =============================================================================
-- 20260922200000  A transfer advances on stock moving, not on somebody clicking
-- -----------------------------------------------------------------------------
-- C3 of the simplification plan, in the half that can be done without changing
-- anybody's promoted configuration. What is and is not here is set out at the
-- bottom of this comment, because the difference matters more than usual.
--
-- erp.transfer_order's lifecycle (20260917130000:1192-1218) declares `issued`,
-- `in_transit` and `received` with no required_permission. Every transition of
-- the current state is drawn by the generic document screen — that is what the
-- driver register means by `screen` — so anybody who can open a transfer order
-- can click "Received" on goods still sitting on a lorry, or still sitting in
-- the despatching warehouse. The state is then what every stock screen, every
-- report and the receiving site's own people read.
--
-- Nothing moves stock when they do. That is the point: the document says the
-- goods arrived and the stock says they did not, and the two are read by
-- different people.
--
-- ── WHY A GUARD AND NOT A PERMISSION ─────────────────────────────────────────
--
-- A permission would say who may click it. It would not say that clicking it is
-- the wrong way to find out whether something arrived. erp.despatch_transfer()
-- and erp.receive_transfer() move the stock and then move the document; the
-- document state is a consequence, and the guard makes it one.
--
-- It is also the half that reaches organisations that already exist. A
-- required_permission lives in a promoted state machine, and changing that for
-- an organisation already running is a reseed — see below.
--
-- ── WHAT THE GUARD ASKS ──────────────────────────────────────────────────────
--
--   in_transit  at least one stock movement against the document. There is
--               exactly one thing that writes those, and it writes them before
--               it asks for this move (20260917130000:797).
--   received    at least one movement against the document AT THE DESTINATION
--               SITE. The despatch legs are written at the despatching site and
--               the arrival legs at the receiving one, so this distinguishes
--               "it left" from "it got there" without naming a movement type a
--               tenant is allowed to configure.
--
-- `issued` is deliberately not guarded. erp.despatch_transfer() takes it before
-- it writes anything — it means "we are loading", and a guard asking for a
-- movement would refuse the one routine that legitimately takes it. What
-- `issued` needs is a permission, which is in the half below.
--
-- ── WHAT IS NOT HERE, AND WHY ────────────────────────────────────────────────
--
-- C3 also says: remove the discrepancy state and its six transitions, remove
-- the unreachable cancellations, and give every remaining transition a
-- permission. All three are changes to the state machine, and they cannot be
-- made in this pull request without breaking the build or the deploy. The
-- interlock, checked rather than assumed:
--
--   * erp.undriven_transition_report() refuses, as its fifth finding, "a
--     register row for a transition its lifecycle does not declare", and as its
--     second, "a declared transition the register does not name".
--   * All sixteen transfer_order transitions are in erp.transition_driver_
--     register() today, as `screen`.
--   * Change the pack and not the register, and the build — which stands one
--     organisation up from the pack — has six register rows naming transitions
--     no lifecycle declares. Finding 5.
--   * Change the register and not the organisations already running, and every
--     one of them declares six transitions the register does not name.
--     Finding 2, on the deploy rather than the build.
--
-- So the two have to move together, which means reseeding a promoted machine in
-- an organisation that is live. No migration in this repository has ever done
-- that, and the plan schedules it: X2 lands reporting and becomes blocking "in
-- PR9 once the reseeds have landed", and P1 reseeds the procurement machines in
-- the procurement track. Inventing that mechanism inside a correctness pull
-- request, against live configuration, for one lifecycle, is the wrong place
-- for it.
--
-- The guard closes the hole those three would close, for every organisation,
-- today. The tidying waits for the pull request that can do it properly.
-- =============================================================================

do $guard$
declare
  v_sig constant text := 'erp.transition_document(uuid, text, text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
    E'  v_ctx := erp.document_transition_context(p_document_id, p_transition_code);\n';
  v_new constant text :=
       E'  -- A transfer advances on stock moving, not on somebody clicking\n'
    || E'  -- (20260922200000). The generic document screen draws every transition of\n'
    || E'  -- the current state, so "Received" was clickable on goods still on the\n'
    || E'  -- lorry — and the receiving site''s own people read that state.\n'
    || E'  --\n'
    || E'  -- The despatch legs are written at the despatching site and the arrival\n'
    || E'  -- legs at the destination, so asking where the movement happened tells\n'
    || E'  -- "it left" from "it got there" without naming a movement type an\n'
    || E'  -- organisation is free to configure. `issued` is not asked about: it means\n'
    || E'  -- the warehouse is loading, and erp.despatch_transfer() takes it before it\n'
    || E'  -- writes anything.\n'
    || E'  if p_transition_code in (''in_transit'', ''received'')\n'
    || E'     and dt.base_type_code = ''transfer_order''\n'
    || E'     and not exists (\n'
    || E'       select 1 from erp.stock_movement m\n'
    || E'        where m.tenant_id = v_tenant and m.document_id = p_document_id\n'
    || E'          and (p_transition_code = ''in_transit''\n'
    || E'               or m.site_id = d.destination_site_id))\n'
    || E'  then\n'
    || E'    raise exception\n'
    || E'      ''CLOVEERP_TRANSFER_HAS_NOT_MOVED: % cannot be %: no stock has %'',\n'
    || E'      coalesce(d.document_number, p_document_id::text), p_transition_code,\n'
    || E'      case when p_transition_code = ''in_transit''\n'
    || E'           then ''left the despatching site'' else ''arrived at the receiving site'' end\n'
    || E'      using errcode = ''23514'',\n'
    || E'            hint = ''Despatch it from the warehouse that holds it, and receive it '' ||\n'
    || E'                   ''at the one expecting it. A transfer order follows the stock; '' ||\n'
    || E'                   ''it is not how the stock is told where it went.'';\n'
    || E'  end if;\n'
    || E'\n'
    || E'  v_ctx := erp.document_transition_context(p_document_id, p_transition_code);\n';
  v_hits integer;
begin
  if position('CLOVEERP_TRANSFER_HAS_NOT_MOVED' in v_def) > 0 then
    raise exception
      'CLOVEERP_TRANSITION_UNRECOGNISED: % already holds a transfer to its movements', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_TRANSITION_UNRECOGNISED: % builds its guard context % time(s), not once',
      v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  execute replace(v_def, v_old, v_new);
end
$guard$;

select erp.register_refusal('CLOVEERP_TRANSFER_HAS_NOT_MOVED',
  'Moving a transfer order on to in transit or received when the stock has not gone anywhere.',
  'A transfer order records where stock is. The state saying goods are in transit, or that they have arrived, is what the receiving warehouse, the stock reports and the valuation all read — so a transfer marked received while the pallets are still in the despatching bay tells everybody the goods are somewhere they are not, and the count that eventually finds them looks like a loss at one site and a windfall at the other.',
  'Despatch the transfer from the warehouse holding the stock, and receive it at the warehouse expecting it. Each moves the stock and then moves the order. If goods have gone missing between the two, receive what arrived and count the difference where it was lost.');

-- ═════════════════════════════════════════════════════════════════════════════
-- And the suite says so, where the transfer already stands approved
-- ═════════════════════════════════════════════════════════════════════════════
--
-- erp_test.site_transfer_suite() already approves a transfer and asserts that
-- approving moved no stock. That is exactly the moment the clicks this node
-- refuses would have been made, so the cases go there rather than into a
-- fixture of their own.
--
-- The third of them is the sharp one: after a real despatch, with the goods
-- genuinely on the road, the receiving end still cannot say they arrived. A
-- guard that only asked "has anything moved at all" would pass the first two
-- and fail that one.

do $suite$
declare
  v_sig constant text := 'erp_test.site_transfer_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
    E'  -- ── 4. Despatched: off the shelf, into transit, still at site A ──────────\n';
  v_new constant text :=
       E'  -- ── 3a. Issued by hand is allowed, and moves nothing ────────────────────\n'
    || E'  -- (20260922200000). `issued` means the warehouse is loading, and\n'
    || E'  -- erp.despatch_transfer() takes it before it writes anything, so it is\n'
    || E'  -- deliberately not guarded. Taken by hand here because that is the state\n'
    || E'  -- the next case has to start from: the real hole is not this click, it is\n'
    || E'  -- the one after it.\n'
    || E'  v_cases := v_cases + 1;\n'
    || E'  perform erp.transition_document(v_doc, ''issued'', ''clicked'');\n'
    || E'  case_name := ''a transfer clicked to issued says the warehouse is loading, and moves no stock'';\n'
    || E'  passed := erp.document_state_code(v_doc) = ''issued''\n'
    || E'        and not exists (select 1 from erp.stock_movement m\n'
    || E'                         where m.tenant_id = v_tenant and m.document_id = v_doc);\n'
    || E'  detail := format(''the order is %s with %s movement(s) against it'',\n'
    || E'                   erp.document_state_code(v_doc),\n'
    || E'                   (select count(*) from erp.stock_movement m\n'
    || E'                     where m.tenant_id = v_tenant and m.document_id = v_doc));\n'
    || E'  return next;\n'
    || E'\n'
    || E'  -- ── 3b. And from there it cannot be clicked onto the road ───────────────\n'
    || E'  -- The hole itself. in_transit IS declared out of issued, carries no\n'
    || E'  -- required_permission, and the generic document screen draws every\n'
    || E'  -- transition of the current state — so before this node anybody who could\n'
    || E'  -- open the order could put the goods on a lorry that was still empty.\n'
    || E'  v_cases := v_cases + 1;\n'
    || E'  v_moved_err := null;\n'
    || E'  begin\n'
    || E'    perform erp.transition_document(v_doc, ''in_transit'', ''clicked'');\n'
    || E'    -- It went through. Raised so the subtransaction rolls the document back:\n'
    || E'    -- a click that works would otherwise drag the fixture to a state the real\n'
    || E'    -- despatch refuses, and the suite would abort instead of naming the case\n'
    || E'    -- that failed.\n'
    || E'    raise exception ''CLOVEERP_SUITE_CLICK_WENT_THROUGH'';\n'
    || E'  exception when others then v_moved_err := sqlerrm; end;\n'
    || E'  case_name := ''but it cannot be clicked onto the road with nothing loaded onto it'';\n'
    || E'  passed := v_moved_err like ''CLOVEERP_TRANSFER_HAS_NOT_MOVED%''\n'
    || E'        and erp.document_state_code(v_doc) = ''issued'';\n'
    || E'  detail := case when v_moved_err like ''CLOVEERP_SUITE_CLICK_WENT_THROUGH%''\n'
    || E'                 then ''it was clicked onto the road and the click worked''\n'
    || E'                 else coalesce(left(v_moved_err, 110), ''nothing was raised at all'') end;\n'
    || E'  return next;\n'
    || E'\n'
    || E'  -- ── 4. Despatched: off the shelf, into transit, still at site A ──────────\n';
  v_hits integer;
begin
  if position('CLOVEERP_TRANSFER_HAS_NOT_MOVED' in v_def) > 0 then
    raise exception 'CLOVEERP_SUITE_UNRECOGNISED: % already holds the clicked cases', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_SUITE_UNRECOGNISED: % despatches % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  v_def := replace(v_def, v_old, v_new);

  -- The sharp one, after a real despatch: the goods are genuinely on the road
  -- and the receiving end still cannot say they arrived.
  v_def := replace(v_def,
    E'  -- ── 6. Received: both sites'' quantities are right ────────────────────────\n',
       E'  -- ── 4a. On the road is not arrived ──────────────────────────────────────\n'
    || E'  -- The case a guard asking only "has anything moved at all" would fail: the\n'
    || E'  -- despatch legs exist, and they were written at the site the goods left.\n'
    || E'  v_cases := v_cases + 1;\n'
    || E'  v_moved_err := null;\n'
    || E'  begin\n'
    || E'    perform erp.transition_document(v_doc, ''received'', ''clicked'');\n'
    || E'    -- It went through. Raised so the subtransaction rolls the document\n'
    || E'    -- back: a click that works would otherwise drag the fixture to a state\n'
    || E'    -- the real despatch refuses, and the suite would abort instead of\n'
    || E'    -- naming the case that failed.\n'
    || E'    raise exception ''CLOVEERP_SUITE_CLICK_WENT_THROUGH'';\n'
    || E'  exception when others then v_moved_err := sqlerrm; end;\n'
    || E'  case_name := ''goods on the road are not goods that arrived, however far they have got'';\n'
    || E'  passed := v_moved_err like ''CLOVEERP_TRANSFER_HAS_NOT_MOVED%''\n'
    || E'        and erp.document_state_code(v_doc) = ''in_transit'';\n'
    || E'  detail := case when v_moved_err like ''CLOVEERP_SUITE_CLICK_WENT_THROUGH%''\n'
    || E'                 then ''it was clicked to received while on the road, and the click worked''\n'
    || E'                 else coalesce(left(v_moved_err, 110), ''nothing was raised at all'') end;\n'
    || E'  return next;\n'
    || E'\n'
    || E'  -- ── 6. Received: both sites'' quantities are right ────────────────────────\n');

  if position('4a. On the road is not arrived' in v_def) = 0 then
    raise exception
      'CLOVEERP_SUITE_UNRECOGNISED: % does not mark its fifth case where this expects', v_sig
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  -- The variable the three cases catch into, declared beside the others.
  v_def := replace(v_def,
    E'  v_ok      boolean; v_msg text;\n',
    E'  v_ok      boolean; v_msg text;\n  v_moved_err text;\n');
  if position('v_moved_err text;' in v_def) = 0 then
    raise exception
      'CLOVEERP_SUITE_UNRECOGNISED: % does not declare its scratch variables where this expects', v_sig
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  -- The suite pins its own count in its own body as well, and three cases were
  -- added. Two guards that disagree are one guard.
  v_def := replace(v_def, 'v_cases <> 12', 'v_cases <> 15');
  v_def := replace(v_def,
    'site_transfer_suite ran % cases, expected 12',
    'site_transfer_suite ran % cases, expected 15');
  if position('v_cases <> 15' in v_def) = 0
     or position('expected 15' in v_def) = 0 then
    raise exception
      'CLOVEERP_SUITE_UNRECOGNISED: % does not pin 12 cases in its own body', v_sig
      using hint = 'Read the deployed body. If the count has moved since, re-anchor on what it is now.';
  end if;

  execute v_def;
end
$suite$;

-- The wrapper pins the count from outside, and three cases were added.

do $pin$
declare
  v_sig constant text := 'erp_test.assert_site_transfer_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := 'expected 12';
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_WRAPPER_UNRECOGNISED: % names 12 cases % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body. If the count has moved since, re-anchor on what it is now.';
  end if;

  v_def := replace(v_def, 'v_all <> 12', 'v_all <> 15');
  v_def := replace(v_def, 'expected 12', 'expected 15');
  execute v_def;
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
