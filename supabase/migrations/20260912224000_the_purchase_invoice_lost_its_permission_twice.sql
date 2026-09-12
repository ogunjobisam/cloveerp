-- A fix that was written once and rewritten away twice.
--
-- 20260831130000 found that purchase_invoice inherited sales.invoice from its
-- base type while every transition on its lifecycle wanted procurement.match —
-- "a document type may be raised by nobody who can then move it" — and fixed
-- it in the one place that matters: erp.configure_procurement_controls(),
-- which creates the tenant's purchase_invoice document type. It set
-- create_permission to procurement.match, with the reasoning in a comment
-- beside it.
--
-- 20260909212619 rewrote that function whole and dropped the column from the
-- insert. 20260910094351 rewrote it again and dropped it again. Neither
-- mentions it; both were doing something else. So every organisation
-- provisioned since carries a purchase invoice that only a sales invoicer can
-- raise and only a purchase matcher can move, which is to say one nobody can
-- put through, and the check that exists to catch precisely this came back the
-- moment the build got far enough to run it:
--
--   [ci-demo.purchase_invoice] raising it needs sales.invoice, but every
--   transition out of its initial state needs one of: procurement.match
--
-- Restored in the function so new organisations get it, and backfilled for
-- the ones that have already been provisioned without it.
--
-- What this does not fix, and what is now written down rather than discovered
-- again: erp.configure_procurement_controls() writes erp.numbering_rule and
-- erp.document_type directly, while everything else it configures goes through
-- erp.install_module_config() and its change set. The live-config guard blocks
-- the numbering-rule write, so the routine — and public.erp_configure_procurement_controls(),
-- which is a door a real organisation can call — cannot run after go-live.
-- Moving the numbering rule into the change set is easy; the document type has
-- no change-set item kind at all, and the numbering rule it depends on would
-- not exist until the set was promoted. That is a piece of work, not a patch.

do $ctrl$
declare
  v_def text;
  v_new text;
begin
  v_def := pg_get_functiondef('erp.configure_procurement_controls(text,numeric,numeric,bigint)'::regprocedure);

  v_new := replace(v_def,
$old$    state_machine_code, numbering_rule_id, posting_rule_code)
  select v_tenant, 'purchase_invoice', 'invoice_reference', 'Purchase invoice',
         n.entity_id, 'purchase_invoice', n.id, 'purchase_invoice'
    from erp.numbering_rule n
   where n.tenant_id = v_tenant and n.code = 'purchase_invoice'
  on conflict (tenant_id, code) do update
    set state_machine_code = excluded.state_machine_code,
        numbering_rule_id = excluded.numbering_rule_id,
        posting_rule_code = excluded.posting_rule_code;$old$,
$new$    state_machine_code, numbering_rule_id, posting_rule_code, create_permission)
  select v_tenant, 'purchase_invoice', 'invoice_reference', 'Purchase invoice',
         n.entity_id, 'purchase_invoice', n.id, 'purchase_invoice',
         -- Base invoice_reference carries sales.invoice, which is right for
         -- sales_invoice and wrong here: every transition on this lifecycle
         -- wants procurement.match, so raising one must too. Dropped by two
         -- whole-function rewrites; see 20260912224000 before dropping it a
         -- third time.
         'procurement.match'
    from erp.numbering_rule n
   where n.tenant_id = v_tenant and n.code = 'purchase_invoice'
  on conflict (tenant_id, code) do update
    set state_machine_code = excluded.state_machine_code,
        numbering_rule_id = excluded.numbering_rule_id,
        posting_rule_code = excluded.posting_rule_code,
        create_permission = excluded.create_permission;$new$);

  if v_new = v_def then
    raise exception 'CLOVEERP_PROCUREMENT_CONTROLS_UNRECOGNISED: erp.configure_procurement_controls() does not hold the purchase_invoice document type insert this migration patches';
  end if;

  execute v_new;
end
$ctrl$;

-- The organisations already provisioned without it.
update erp.document_type
   set create_permission = 'procurement.match'
 where base_type_code = 'invoice_reference'
   and code = 'purchase_invoice'
   and create_permission is distinct from 'procurement.match';

select erp.assert_document_create_permissions();
