-- Repair execute grants after adding invoker routines without reapplying reach.

select erp.apply_execute_grants();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
