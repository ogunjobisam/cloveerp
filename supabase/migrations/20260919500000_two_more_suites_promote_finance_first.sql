-- Two more suites promote finance first.
--
-- 20260916610000 fixed one instance of a coin flip that can redden a build which
-- changed nothing. A fixture calls seven module installers inside one
-- transaction; every change set they write takes created_at = now(), which is
-- the transaction's timestamp, so all seven carry the same value. The fixture
-- then promotes them "order by cs.created_at" — a sort with nothing to decide,
-- which hands back rows in whatever order the scan found them in erp.change_set's
-- heap. That moved between runs, and it reddened run 35152683802 on PR 163:
--
--   CLOVEERP_PROMOTION_BREAKS_DETERMINATION: sales-lifecycle introduces a way
--   for a posting to fail
--
-- The promoter's determination check is a delta. finance-posting carries the
-- posting rules; sales-lifecycle, procurement-lifecycle and inventory-operations
-- carry document types that reach the ledger and name those rules. Promoted
-- before finance-posting, any of the three adds findings
-- erp.determination_coverage_report() did not return a moment earlier — a
-- document type naming a posting rule with no version in force — and the whole
-- promotion is refused. Promoted after it, none of them adds a finding.
--
-- 20260916610000 fixed erp_test.warehouse_and_finance_jobs_suite and named the
-- other sites it had seen without establishing what they were. They have now
-- been established. `git grep "order by cs.created_at"` over supabase/ finds
-- twelve promotion loops in migrations. Eight belong to superseded definitions of
-- erp_test.starter_pack_acceptance_suite (20260903180000, 20260904130000,
-- 20260904140000, 20260904170000, 20260904430000 twice, 20260904850000 twice) —
-- the live body is the one 20260904920000 wrote, so those eight are text in files
-- that no longer describe anything. One is the warehouse suite's own source,
-- already replaced in the live body by 20260916610000. Three are live:
--
--   erp_test.starter_pack_acceptance_suite, twice. Its first loop promotes the
--   same seven installers as the warehouse suite, on an organisation that
--   erp.provision_tenant() marks live immediately, and can therefore fail in
--   exactly the same way for exactly the same reason. Its second loop promotes
--   receivables, procurement-controls, planning and production, added after the
--   first seven are in force; none of those four carries a document type, so the
--   determination delta cannot break between them today — but they share a
--   created_at like the rest, and an order the heap decides is not an order.
--
--   erp_test.document_spine_suite, once. It installs finance inside the
--   bootstrap window, where erp.install_module_config() approves and promotes in
--   the same call, and procurement after erp_test.close_bootstrap_window() — so
--   exactly one change set is ever ready when that loop runs and the sort decides
--   nothing today. It is named from the same list anyway, because the next
--   installer added to that fixture would otherwise land wherever the scan found
--   it, and because the three fixtures reading the same order is the point.
--
-- Two further uses of cs.created_at are not promotion loops and are left alone:
-- public.erp_administrator_approval() (20260914098000) and the approval-chain
-- reader (20260916300000) both take "order by cs.created_at desc limit 1" to name
-- the change still waiting on a screen. They read one row rather than promoting
-- many, and a tie there picks between two pending edits to the same setting,
-- which is a display question and not a determination one.
--
-- Three counted replacements, each anchored on the live body rather than on the
-- file that first wrote it. The acceptance suite has been patched four times
-- since 20260904920000 — 20260914061500, 20260914070000, 20260915011000 and
-- 20260917130000, all of them moving the count of items the base pack plans — so
-- this migration asserts afterwards that all four are still there.
--
-- No case is added or removed in either suite: twenty-seven in the acceptance
-- suite and eleven in the spine suite, as before, so neither assert wrapper's
-- expected total moves. Nothing else in the build counts a promotion loop.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The acceptance suite, both loops
-- ═════════════════════════════════════════════════════════════════════════════

do $starter$
declare
  v_sig   text := 'erp_test.starter_pack_acceptance_suite()';
  v_def   text := pg_get_functiondef('erp_test.starter_pack_acceptance_suite()'::regprocedure);
  v_after text;

  -- The two loops are byte-identical, so each needle carries the line above it
  -- that tells them apart. Both of those lines occur once in the body.
  v_first_old text := $n$  perform erp.claim_invitation(v_tok);
  for c in select cs.id from erp.change_set cs
            where cs.tenant_id = r.tenant_id and cs.status = 'ready'
            order by cs.created_at loop
$n$;
  v_first_new text := $r$  perform erp.claim_invitation(v_tok);
  -- The installers' own order, named (20260919500000). The seven share one
  -- created_at, so the sort had nothing to decide and the heap decided it, and a
  -- module promoted before finance-posting names posting rules with no version
  -- in force. Same list in the same order as
  -- erp_test.warehouse_and_finance_jobs_suite (20260916610000). A change set the
  -- list does not name goes after the named ones, by code, so the order is
  -- decided either way.
  for c in select cs.id from erp.change_set cs
            where cs.tenant_id = r.tenant_id and cs.status = 'ready'
            order by array_position(array['finance-posting', 'procurement-lifecycle', 'sales-lifecycle',
                                          'inventory-operations', 'quality', 'logistics', 'period-close'],
                                    cs.code) nulls last,
                     cs.code loop
$r$;

  v_second_old text := $n$  perform erp.configure_production();
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  for c in select cs.id from erp.change_set cs
            where cs.tenant_id = r.tenant_id and cs.status = 'ready'
            order by cs.created_at loop
$n$;
  v_second_new text := $r$  perform erp.configure_production();
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  -- The four later installers, in the order they were just run (20260919500000).
  -- They share a created_at with each other exactly as the first seven do. None
  -- of them carries a document type, so nothing here can break determination
  -- today; the order is named so that it is decided by the fixture rather than
  -- by where the rows happen to sit.
  for c in select cs.id from erp.change_set cs
            where cs.tenant_id = r.tenant_id and cs.status = 'ready'
            order by array_position(array['receivables', 'procurement-controls',
                                          'planning', 'production'],
                                    cs.code) nulls last,
                     cs.code loop
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_first_old, ''))) / length(v_first_old) <> 1
     or (length(v_def) - length(replace(v_def, v_second_old, ''))) / length(v_second_old) <> 1
     or position('array_position(' in v_def) > 0 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % is not the body this migration patches', v_sig
      using hint = 'Each needle must occur exactly once and the body must not already name an order. A later migration changed the suite: read its body with pg_get_functiondef and patch that.';
  end if;

  execute replace(replace(v_def, v_first_old, v_first_new), v_second_old, v_second_new);

  v_after := pg_get_functiondef(v_sig::regprocedure);
  if position(v_first_old in v_after) > 0
     or position(v_second_old in v_after) > 0
     or (length(v_after) - length(replace(v_after, 'order by array_position(', '')))
          / length('order by array_position(') <> 2 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % was re-emitted without both named orders', v_sig
      using hint = 'The replacement did not land; compare the patched body with the needles above.';
  end if;

  -- The four counts this suite has been given since its last full definition are
  -- still in it. A replacement that quietly dropped one would leave the suite
  -- measuring a pack it no longer has.
  if position($c$(res ->> 'items')::integer = 346$c$ in v_after) = 0
     or position('20260914061500' in v_after) = 0
     or position('20260914070000' in v_after) = 0
     or position('20260915011000' in v_after) = 0
     or position('20260917130000' in v_after) = 0 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % lost a count an earlier migration gave it', v_sig
      using hint = 'The body should still plan 346 items and still carry the four notes that moved that number.';
  end if;
end
$starter$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The document spine suite
-- ═════════════════════════════════════════════════════════════════════════════

do $spine$
declare
  v_sig   text := 'erp_test.document_spine_suite()';
  v_def   text := pg_get_functiondef('erp_test.document_spine_suite()'::regprocedure);
  v_after text;

  v_loop_old text := $n$  for c in select cs.id from erp.change_set cs
            where cs.tenant_id = v_t and cs.status = 'ready' order by cs.created_at
  loop
$n$;
  v_loop_new text := $r$  -- Named (20260919500000), from the list
  -- erp_test.warehouse_and_finance_jobs_suite and
  -- erp_test.starter_pack_acceptance_suite read. This fixture installs finance
  -- inside the bootstrap window, which promotes in the same call, and
  -- procurement after go-live — so one change set is ready here and the order
  -- decides nothing today. It is named so that it stays decided when a second
  -- installer is added, and so that a module promoted before finance-posting is
  -- impossible here as it is there.
  for c in select cs.id from erp.change_set cs
            where cs.tenant_id = v_t and cs.status = 'ready'
            order by array_position(array['finance-posting', 'procurement-lifecycle', 'sales-lifecycle',
                                          'inventory-operations', 'quality', 'logistics', 'period-close'],
                                    cs.code) nulls last,
                     cs.code
  loop
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_loop_old, ''))) / length(v_loop_old) <> 1
     or position('array_position(' in v_def) > 0 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % is not the body this migration patches', v_sig
      using hint = 'The needle must occur exactly once and the body must not already name an order. A later migration changed the suite: read its body with pg_get_functiondef and patch that.';
  end if;

  execute replace(v_def, v_loop_old, v_loop_new);

  v_after := pg_get_functiondef(v_sig::regprocedure);
  if position(v_loop_old in v_after) > 0
     or (length(v_after) - length(replace(v_after, 'order by array_position(', '')))
          / length('order by array_position(') <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % was re-emitted without its named order', v_sig
      using hint = 'The replacement did not land; compare the patched body with the needle above.';
  end if;

  -- 20260904980000 rewrote this body's refusal codes to the current prefix and
  -- 20260912201000 kept them there. Both live-configuration cases still match
  -- the code the guard raises, so the sweep's work survived this replacement.
  if (length(v_after) - length(replace(v_after, 'CLOVEERP_LIVE_CONFIG_EDIT', '')))
       / length('CLOVEERP_LIVE_CONFIG_EDIT') <> 2 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % no longer matches the live-configuration refusal twice', v_sig
      using hint = 'The two guard cases read the refusal code by name. Read the patched body and compare.';
  end if;
end
$spine$;

-- ═════════════════════════════════════════════════════════════════════════════
-- Generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

-- The two suites this migration patched, and nothing else: each builds and
-- purges its own organisation and neither needs to be the only one of anything,
-- so both are answerable on a live database as well as on an empty one.
select erp_test.assert_starter_pack_acceptance();
select erp_test.assert_document_spine_suite();

select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_session_context_hygiene();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_isolation();
