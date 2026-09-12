-- "the administrator role holds every permission — 145 of 58"
--
-- The case never asked that. It counted every row in erp.role_permission for
-- the organisation and compared it with the number of permission codes, which
-- is only the same question while provisioning creates exactly one role. It
-- does not: the starter roles have carried their own permissions for some
-- time, and 20260911090027 granted document.issue and document.reprint to the
-- roles that raise sales invoices. The total went past the number of codes and
-- the case failed — correctly, for the wrong reason, having been wrong and
-- green the whole way here.
--
-- Ask the question the case name asks: does the administrator hold all of them.

do $prov$
declare
  v_def text;
  v_new text;
begin
  v_def := pg_get_functiondef('erp_test.provisioning_suite()'::regprocedure);

  v_new := replace(v_def,
$old$    (select count(*) from erp.role_permission rp where rp.tenant_id = r.tenant_id)
      = (select count(*) from erp_ref.permission),
    format('%s of %s',
      (select count(*) from erp.role_permission rp where rp.tenant_id = r.tenant_id),
      (select count(*) from erp_ref.permission));$old$,
$new$    (select count(*) from erp.role_permission rp
       join erp.role ro on ro.id = rp.role_id and ro.tenant_id = rp.tenant_id
      where rp.tenant_id = r.tenant_id and ro.code = 'administrator')
      = (select count(*) from erp_ref.permission),
    format('%s of %s',
      (select count(*) from erp.role_permission rp
         join erp.role ro on ro.id = rp.role_id and ro.tenant_id = rp.tenant_id
        where rp.tenant_id = r.tenant_id and ro.code = 'administrator'),
      (select count(*) from erp_ref.permission));$new$);

  if v_new = v_def then
    raise exception 'CLOVEERP_PROVISIONING_CASE_UNRECOGNISED: erp_test.provisioning_suite() does not count role_permission across every role, so this migration is patching a body that has already moved on';
  end if;

  execute v_new;
end
$prov$;
