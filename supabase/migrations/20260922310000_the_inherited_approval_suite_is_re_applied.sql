set lock_timeout = '30s';

-- =============================================================================
-- 20260922310000  The inherited approval suite is re-applied
-- -----------------------------------------------------------------------------
-- supabase/ci/preflight.sh refused this branch on rule E:
--
--   20260922240000_an_approval_that_still_holds_is_not_asked_for_again.sql is
--   touched by 2 commits on this branch.
--     5e41f92 W3 piece 3: the ladder stops where the door stops
--     29e3099 W1: an approval that still holds is not asked for again
--
-- It was right to. 29e3099 committed W1 with a suite that read
--
--   select count(*), max(ar.id) into v_n, v_first
--
-- and there is no max(uuid) in PostgreSQL, so the suite stopped at its first
-- case. The fix was made in the file and swept into the next commit with the
-- rest of the working tree, which made it an edit to a migration after the
-- commit that wrote it — the one class of change the schema build cannot see,
-- because a replay from an empty database only ever runs the edited version.
--
-- In this case no environment ran the first version: it was never pushed on
-- its own. But the rule is about commits, not about which environments
-- happened to see them, and that is the right shape for it — the moment a
-- rule starts asking "did anybody really apply this?" it stops being a rule.
-- So the repair is written the way the register requires: a NEW migration
-- that brings any database holding the first version to the second.
--
-- And the thing that made this cost a build rather than a minute is worth
-- writing down beside it. Preflight refused locally, twice, and the refusal
-- was not read, because the summary line — "N migrations checked, nothing the
-- build refuses is in them" — prints BELOW the refusal and reads as a pass
-- when only the last lines are looked at. Read the whole output, or its exit
-- status; never its tail.
--
-- ── WHAT THIS DOES ───────────────────────────────────────────────────────────
--
-- Where the deployed suite still reads max(ar.id), it is patched to the form
-- 20260922240000 now carries. Where it already carries that form — which is
-- every database built from an empty cluster, since a replay only ever sees
-- the file as it stands — there is nothing to do and it says so by doing
-- nothing. Anything else refuses, because a third shape is one this was not
-- written against.
-- =============================================================================

do $repair$
declare
  v_sig constant text := 'erp_test.inherited_approval_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
       E'  select count(*), max(ar.id) into v_n, v_first\n'
    || E'    from erp.approval_request ar\n'
    || E'   where ar.tenant_id = r.tenant_id and ar.object_type = ''document'' and ar.object_id = v_po;\n'
    || E'  select ar.status::text into v_status\n'
    || E'    from erp.approval_request ar where ar.tenant_id = r.tenant_id and ar.id = v_first;\n';
  v_new constant text :=
       E'  select count(*) into v_n\n'
    || E'    from erp.approval_request ar\n'
    || E'   where ar.tenant_id = r.tenant_id and ar.object_type = ''document'' and ar.object_id = v_po;\n'
    || E'  select ar.id, ar.status::text into v_first, v_status\n'
    || E'    from erp.approval_request ar\n'
    || E'   where ar.tenant_id = r.tenant_id and ar.object_type = ''document'' and ar.object_id = v_po\n'
    || E'   order by ar.requested_at desc, ar.id desc\n'
    || E'   limit 1;\n';
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);

  if v_hits = 0 then
    if position(v_new in v_def) > 0 then
      return;  -- already the corrected form, as every replay from an empty database has it
    end if;
    raise exception
      'CLOVEERP_SUITE_UNRECOGNISED: % carries neither the first form of its opening case nor the corrected one', v_sig
      using hint = 'Read the deployed body. A third shape is one this repair was not written against.';
  end if;

  if v_hits <> 1 then
    raise exception
      'CLOVEERP_SUITE_UNRECOGNISED: % reads max(ar.id) % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this repair on it.';
  end if;

  execute replace(v_def, v_old, v_new);
end
$repair$;

-- And what the repair is for, checked where it is claimed.

do $held$
declare
  v_def text := pg_get_functiondef('erp_test.inherited_approval_suite()'::regprocedure);
begin
  if position('max(ar.id)' in v_def) > 0 then
    raise exception 'CLOVEERP_SUITE_NOT_REPAIRED: erp_test.inherited_approval_suite() still reads max(ar.id), which PostgreSQL does not have for uuid'
      using hint = 'The repair above did not reach it. Read the deployed body.';
  end if;
end
$held$;

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
