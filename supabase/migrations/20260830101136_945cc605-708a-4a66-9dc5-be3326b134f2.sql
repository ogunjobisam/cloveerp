create or replace function public.erp_close_tasks(p_limit integer default 200)
returns jsonb language sql stable security invoker set search_path to '' as $$
  select coalesce(jsonb_agg(x order by x->>'period', (x->>'seq')::int), '[]'::jsonb) from (
    select jsonb_build_object(
             'task_id', ct.id, 'code', ct.code, 'name', ct.name, 'seq', ct.seq,
             'status', ct.status, 'period', fp.code) as x
      from erp.close_task ct
      join erp.fiscal_period fp on fp.tenant_id = ct.tenant_id and fp.id = ct.fiscal_period_id
     where ct.tenant_id = erp.current_tenant_id()
     order by fp.code desc, ct.seq
     limit greatest(p_limit, 1)) t;
$$;

revoke all on function public.erp_close_tasks(integer) from public, anon;
grant execute on function public.erp_close_tasks(integer) to authenticated, service_role;
