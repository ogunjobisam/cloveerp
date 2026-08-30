-- The internal functions stop being a callable surface; the public entry
-- points become the single audited door, and each still authorises inside.
revoke all on function erp.raise_putaway_tasks(uuid) from public, anon, authenticated;
revoke all on function erp.raise_replenishment_tasks(uuid) from public, anon, authenticated;
revoke all on function erp.complete_warehouse_task(uuid, numeric) from public, anon, authenticated;
revoke all on function erp.merge_batches(uuid, uuid, text) from public, anon, authenticated;
revoke all on function erp.seed_demo_operations() from public, anon, authenticated;

create or replace function public.erp_raise_putaway_tasks(p_site_id uuid)
returns integer language sql volatile security definer set search_path to ''
as $$ select erp.raise_putaway_tasks(p_site_id); $$;

create or replace function public.erp_raise_replenishment_tasks(p_site_id uuid)
returns integer language sql volatile security definer set search_path to ''
as $$ select erp.raise_replenishment_tasks(p_site_id); $$;

create or replace function public.erp_complete_warehouse_task(p_task_id uuid, p_quantity numeric default null)
returns jsonb language sql volatile security definer set search_path to ''
as $$ select erp.complete_warehouse_task(p_task_id, p_quantity); $$;

create or replace function public.erp_merge_batches(p_target_batch_id uuid, p_source_batch_id uuid, p_reason text)
returns jsonb language sql volatile security definer set search_path to ''
as $$ select erp.merge_batches(p_target_batch_id, p_source_batch_id, p_reason); $$;

create or replace function public.erp_seed_demo_operations()
returns jsonb language sql volatile security definer set search_path to ''
as $$ select erp.seed_demo_operations(); $$;

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure::text as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('erp_raise_putaway_tasks', 'erp_raise_replenishment_tasks',
         'erp_complete_warehouse_task', 'erp_merge_batches', 'erp_seed_demo_operations')
  loop
    execute format('revoke all on function %s from public', r.sig);
    execute format('revoke all on function %s from anon', r.sig);
    execute format('grant execute on function %s to authenticated', r.sig);
    execute format('grant execute on function %s to service_role', r.sig);
  end loop;
end $$;
