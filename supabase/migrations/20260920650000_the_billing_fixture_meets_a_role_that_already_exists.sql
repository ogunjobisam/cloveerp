set lock_timeout = '30s';

-- =============================================================================
-- 20260920650000  The billing fixture meets a role that already exists
-- -----------------------------------------------------------------------------
-- 20260920660000 seeds Scanner operator, with the base pack's own template
-- mark and permissions, on every newly provisioned organisation. That is a
-- change to what a fresh tenant HOLDS, and one fixture built its own tenant
-- and then wrote the same role by hand, unconditionally, to test the base
-- pack's template: erp_test.billing_matches_the_list_suite(), which provisions
-- an organisation and inserts a role literally named 'scanner_operator' to
-- check that permission's seat and door behaviour.
--
-- 20260920660000 gave that fixture's tenant a 'scanner_operator' role of its
-- own, seconds before the fixture's own insert ran — the unique constraint
-- on (tenant_id, code) refused the second one by name: duplicate key value
-- violates "role_tenant_id_code_key". The fixture's own comment already says
-- what it was testing: the Scanner operator role, as the base pack writes it
-- — which is now also what provisioning writes, from the very same
-- erp_ref.pack_item row. The fixture's assumption was correct until
-- 20260920660000 and cannot be made correct again by changing the number it
-- expects; the role it is testing is not a count.
--
-- Made idempotent rather than removed: the fixture still names exactly what
-- it means to prove — that the role holds the template's permissions and
-- carries its mark — and that is no less true when provisioning already
-- built the role than when the fixture built it. On conflict, take what the
-- template gives rather than fail: the same rule 20260914061500 gave every
-- content-pack promotion meeting a role it did not make.
--
-- The scanner_operator template's own code, name and permission set are not
-- touched — nothing here is the reconciliation §the pack templates and the
-- module roles both defer.
--
-- Proof: erp_test.billing_matches_the_list_suite() still runs its own twelve
-- cases; the count is unchanged because nothing about what it PROVES moved,
-- only how it gets a role already there.
-- =============================================================================

do $fixture$
declare
  v_sig constant text := 'erp_test.billing_matches_the_list_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_n   constant text := $n$    perform erp_test.reopen_bootstrap_window(v_s);
    insert into erp.role (tenant_id, code, name, from_template, status)
    values (v_s, 'scanner_operator', 'Scanner operator', 'base-1.0.0', 'active');
    insert into erp.role_permission (tenant_id, role_id, permission_code)
    select v_s, ro.id, x.perm
      from unnest(v_template) as x(perm)
      join erp.role ro on ro.tenant_id = v_s and ro.code = 'scanner_operator';
    perform erp_test.close_bootstrap_window(v_s);
$n$;
  v_r   constant text := $r$    perform erp_test.reopen_bootstrap_window(v_s);
    -- Provisioning seeds this exact role from this exact template row
    -- (20260920660000), so the fixture's tenant already has it by the time
    -- this runs. On conflict, take what the template gives — the same rule a
    -- content-pack promotion already follows meeting a role it did not make
    -- (20260914061500) — rather than fail on a role this suite no longer
    -- needs to build from nothing.
    insert into erp.role (tenant_id, code, name, from_template, status)
    values (v_s, 'scanner_operator', 'Scanner operator', 'base-1.0.0', 'active')
    on conflict (tenant_id, code) do update
      set name = excluded.name, from_template = excluded.from_template,
          status = excluded.status;
    insert into erp.role_permission (tenant_id, role_id, permission_code)
    select v_s, ro.id, x.perm
      from unnest(v_template) as x(perm)
      join erp.role ro on ro.tenant_id = v_s and ro.code = 'scanner_operator'
    on conflict (tenant_id, role_id, permission_code) do nothing;
    perform erp_test.close_bootstrap_window(v_s);
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_FIXTURE_UNRECOGNISED: % does not write the Scanner operator role the way this migration patches', v_sig
      using hint = 'A later migration changed the fixture. Read the definition the database carries and write the needle against that.';
  end if;
  execute replace(v_def, v_n, v_r);

  if position('on conflict (tenant_id, code) do update' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_FIXTURE_UNRECOGNISED: % did not take the idempotent role write', v_sig
      using hint = 'The replacement did not land. Compare the needle with the definition the database carries.';
  end if;
end
$fixture$;

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_billing_matches_the_list_suite();
