-- The procurement suite keeps its second person.
--
-- 20260914098000 lets an administrator approve their own requests where the
-- organisation allows it, which every organisation does by default, and
-- switched the setting off in the six suites found proving that an
-- administrator's own approval is refused. The build's catalogue found a
-- seventh: erp_test.procurement_suite (20260829220000) has its first
-- administrator install procurement on a live organisation and expects their
-- own approval of the change to be refused, matching the refusal by its
-- SQLSTATE rather than its token, which is why the search by token missed it.
-- With the setting on, the approval went through, and the second
-- administrator's approval of the same change then met a change already
-- approved.
--
-- The suite proves two-person approval, so it keeps proving it: the setting is
-- switched off in its organisation straight after the first administrator
-- joins, through erp_test.administrator_approval_off(). A counted replacement
-- of the suite's body, asserted once.

do $suite$
declare
  v_sig text := 'erp_test.procurement_suite()';
  v_def text := pg_get_functiondef('erp_test.procurement_suite()'::regprocedure);
  v_old text := $n$  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);
$n$;
  v_new text := $r$  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);
  -- Two-person approval is what this organisation proves (20260914098500).
  perform erp_test.administrator_approval_off(r.tenant_id);
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1
     or position('administrator_approval_off' in v_def) > 0 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % is not the body this migration patches', v_sig
      using hint = 'A later migration changed the suite. Read its body with pg_get_functiondef and patch that.';
  end if;
  execute replace(v_def, v_old, v_new);
  if position('administrator_approval_off' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % was re-emitted without the setting switched off', v_sig
      using hint = 'The replacement did not land; compare the patched body with the needle above.';
  end if;
end
$suite$;

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_procurement_suite();

select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_session_context_hygiene();
select erp.assert_suite_verdicts_strict();
