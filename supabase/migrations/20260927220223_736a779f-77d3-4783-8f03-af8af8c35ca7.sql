-- =============================================================================
-- 20260929500000 — Open counts come first in the count-task door
--
-- public.erp_count_tasks ordered its rows by status name, so 'approved',
-- 'cancelled' and 'counted' sorted before 'open'. The Stock audit worklist
-- reads the first 500 and filters to open work on the screen, so enough
-- finished history pushed every open count past the cap and the worklist
-- showed "Nothing is waiting to be counted" with counters still holding
-- sheets. The door's own comment already promised "open work first"; this
-- makes it true. No signature, grant or scope change.
-- =============================================================================

-- The door as 20260928100000 left it, or stop: a restatement over a body that
-- has moved since would drop whatever moved it.
do $door_anchor$
declare
  v_sig constant text := 'public.erp_count_tasks(integer)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_needles constant text[] := array[
    $o$'stock_status', c.stock_status,$o$,
    $o$     where c.tenant_id = erp.current_tenant_id()
     order by c.status, c.created_at desc limit greatest(p_limit, 1)) t$o$,
    $o$ STABLE
$o$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_needles, 1) loop
    v_hits := (length(v_def) - length(replace(v_def, v_needles[v_i], ''))) / length(v_needles[v_i]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
  end loop;
  if (select p.prosecdef or p.prolang <> (select l.oid from pg_language l where l.lanname = 'sql')
             or p.proconfig is distinct from array['search_path=""']
        from pg_proc p where p.oid = v_sig::regprocedure) then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is no longer a plain sql door with an empty search path', v_sig;
  end if;
end
$door_anchor$;

create or replace function public.erp_count_tasks(p_limit integer default 200)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- Every count task of the organisation, open work first (20260927400000,
  -- ordered so in fact from 20260929500000): where it stands, the sheet and
  -- line it is on, the adjustment its post wrote, whether the system posted
  -- it, why an approved one waits, and whether the reader counted it. It
  -- authorises nothing; the tenant filter and row security scope it, and
  -- every join is inside the task's own organisation. Open counts lead so
  -- the limit bites history before work.
  select coalesce(jsonb_agg(x order by (x->>'status' = 'open') desc, x->>'status'), '[]'::jsonb) from (
    select jsonb_build_object('task_id', c.id, 'item', i.code, 'site', s.code,
      'location', l.code, 'expected', c.expected_quantity, 'counted', c.counted_quantity,
      'variance', c.variance, 'within_tolerance', c.within_tolerance, 'status', c.status,
      'counted_at', c.counted_at, 'posted_at', c.posted_at,
      'item_name', i.name, 'batch', b.batch_number, 'site_id', c.site_id,
      'programme', pg.code,
      'document_id', c.document_id, 'document_number', sh.document_number,
      'sheet_line_no', sl.line_no,
      'adjustment_document_id', c.adjustment_document_id,
      'adjustment_number', adj.document_number,
      'posted_by_system', c.posted_by_system,
      -- The status the count is of, and why a count held because it is
      -- not known waits while it is still to be counted (20260928100000).
      'stock_status', c.stock_status,
      'post_held_reason', case when c.status = 'approved'
                                 or (c.stock_status is null
                                     and c.status in ('open', 'counted', 'pending_approval', 'rejected')
                                     and c.post_held_reason like 'status_unknown:%')
                               then c.post_held_reason end,
      'counted_by_me', coalesce(c.counted_by = erp.current_principal_id(), false),
      -- erp.post_count() refuses a person's post of their own count with a
      -- variance once the organisation is live (CLOVEERP_COUNT_SELF_POSTING).
      'post_refused_to_me', coalesce(c.counted_by = erp.current_principal_id()
                                     and c.variance <> 0
                                     and erp.tenant_is_live(c.tenant_id), false)) as x
      from erp.count_task c
      join erp.item i on i.tenant_id = c.tenant_id and i.id = c.item_id
      left join erp.site s on s.tenant_id = c.tenant_id and s.id = c.site_id
      left join erp.location l on l.tenant_id = c.tenant_id and l.id = c.location_id
      left join erp.batch b on b.tenant_id = c.tenant_id and b.id = c.batch_id
      left join erp.count_programme pg on pg.tenant_id = c.tenant_id and pg.id = c.count_programme_id
      left join erp.document sh on sh.tenant_id = c.tenant_id and sh.id = c.document_id
      left join erp.document_line sl on sl.tenant_id = c.tenant_id and sl.id = c.document_line_id
      left join erp.document adj on adj.tenant_id = c.tenant_id and adj.id = c.adjustment_document_id
     where c.tenant_id = erp.current_tenant_id()
     order by (c.status = 'open') desc, c.created_at desc limit greatest(p_limit, 1)) t
$$;

revoke all on function public.erp_count_tasks(integer) from public, anon;
grant execute on function public.erp_count_tasks(integer) to authenticated, service_role;

comment on function public.erp_count_tasks(integer) is
  'The organisation''s count tasks, open work first, up to p_limit: the place, the figures and where '
  'each stands, the count sheet and line it is on (null when raised with no sheet), the stock '
  'adjustment its post wrote, whether the system posted it as it was recorded, why an approved count '
  'waits for somebody to post it, and whether the reader counted it (20260927400000; open-first '
  'ordering made true in 20260929500000). Authorises nothing; the tenant filter and row security scope it.';