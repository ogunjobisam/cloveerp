-- =============================================================================
-- 20260928  Counts whose difference went to available stock
-- -----------------------------------------------------------------------------
-- The operator's half of 20260928100000 (PR11 M2, decisions D2 and D3).
-- Until that migration a count task had no stock status, and every count
-- posted its difference to AVAILABLE stock. A place that held nothing
-- available and a hundred in quarantine, counted at 99, was left reading
-- available -1, quarantine 100; counted at 101, available +1, quarantine 100.
-- From the migration on, a count posts to the status it counted. What was
-- posted before stays as it is: the shelves then are for a person to say, so
-- nothing here repairs anything.
--
-- What is found: every count posted with a difference before a count knew its
-- status whose expectation, when it was raised, was the quantity of another
-- status at its place, owner and handling unit, and not the quantity
-- available. The raise took each expectation from exactly one such position,
-- so the count was of that status; where available held as much too, which
-- it was cannot be told, and it is not listed. The place as it stood is
-- rebuilt backwards from today's balance, taking away every movement
-- recorded since the count was raised.
--
-- Run it by hand, from a session that bypasses row security (the project's
-- postgres role), in psql. It is not part of the build and nothing runs it.
--
--   Part 1 reads only, and needs nothing the migration adds, so it runs the
--          same before the deploy that carries 20260928100000 as after it.
--          Run it both times and keep both outputs with the release.
--   Part 2 is the same reading through
--          erp.count_posts_past_their_status_report(), which exists only once
--          the migration has applied: a check that the two agree, after the
--          deploy.
--   Part 3 lists the counts the migration's backfill held (decision D2),
--          after the deploy: each is for a person to cancel and raise again.
--
-- A finding is corrected on the desk, not here: once somebody has checked the
-- place and agrees, by a status change that moves the difference between
-- available and the status the count was of.
-- =============================================================================

\set ON_ERROR_STOP on

-- ─────────────────────────────────────────────────────────────────────────────
-- Part 1. Every organisation, in plain SQL over the tables. Read only.
-- ─────────────────────────────────────────────────────────────────────────────

begin read only;

with posted as (
  select c.*, erp.entity_party_for_site(c.site_id) as custody
    from erp.count_task c
    join erp.tenant tn on tn.id = c.tenant_id and tn.deleted_at is null
   where c.status = 'posted'
     and coalesce(c.variance, 0) <> 0
     -- Posted before a count knew its status: before the migration there
     -- is no such column, and after it these have none.
     and to_jsonb(c) ->> 'stock_status' is null
),
pos as (
  -- The place when the count was raised: the balance now, less what
  -- arrived since, plus what left since, for the count's owner and unit.
  select p.id, x.stock_status, sum(x.quantity) as quantity
    from posted p
    cross join lateral (
      select b.stock_status, b.owner_party_id, b.container_id, b.quantity
        from erp.stock_balance b
       where b.tenant_id = p.tenant_id and b.item_id = p.item_id and b.site_id = p.site_id
         and (p.location_id is null or b.location_id = p.location_id)
         and b.batch_id is not distinct from p.batch_id
         and b.custody_party_id = p.custody
      union all
      select m.to_status, coalesce(m.to_owner_party_id, m.owner_party_id), m.container_id, -m.quantity
        from erp.stock_movement m
       where m.tenant_id = p.tenant_id and m.item_id = p.item_id and m.recorded_at > p.created_at
         and m.batch_id is not distinct from p.batch_id and m.to_location_id is not null
         and coalesce(m.to_custody_party_id, m.custody_party_id) = p.custody
         and (m.to_location_id = p.location_id
              or (p.location_id is null and exists (select 1 from erp.location l
                    where l.tenant_id = m.tenant_id and l.id = m.to_location_id and l.site_id = p.site_id)))
      union all
      select m.from_status, m.owner_party_id, m.container_id, m.quantity
        from erp.stock_movement m
       where m.tenant_id = p.tenant_id and m.item_id = p.item_id and m.recorded_at > p.created_at
         and m.batch_id is not distinct from p.batch_id and m.from_location_id is not null
         and m.custody_party_id = p.custody
         and (m.from_location_id = p.location_id
              or (p.location_id is null and exists (select 1 from erp.location l
                    where l.tenant_id = m.tenant_id and l.id = m.from_location_id and l.site_id = p.site_id)))
    ) x
   where x.owner_party_id is not distinct from p.owner_party_id
     and (p.container_id is null or x.container_id = p.container_id)
   group by p.id, x.stock_status
),
judged as (
  select p.*,
         coalesce((select x.quantity from pos x
                    where x.id = p.id and x.stock_status = 'available'), 0) as available_then,
         (select string_agg(replace(x.stock_status::text, '_', ' '), ' or ' order by x.stock_status)
            from pos x
           where x.id = p.id and x.stock_status <> 'available'
             and x.quantity = p.expected_quantity) as counted_status
    from posted p
)
select tn.code as organisation, j.id as count_task_id, j.posted_at, i.code as item,
       l.code as location, b.batch_number as batch, d.document_number as adjustment,
       trim_scale(j.expected_quantity) as expected, trim_scale(j.variance) as variance,
       j.counted_status, trim_scale(j.available_then) as available_then
  from judged j
  join erp.tenant tn on tn.id = j.tenant_id
  join erp.item i on i.tenant_id = j.tenant_id and i.id = j.item_id
  left join erp.location l on l.tenant_id = j.tenant_id and l.id = j.location_id
  left join erp.batch b on b.tenant_id = j.tenant_id and b.id = j.batch_id
  left join erp.document d on d.tenant_id = j.tenant_id and d.id = j.adjustment_document_id
 where j.counted_status is not null
   and j.available_then <> j.expected_quantity
 order by tn.code, j.posted_at, j.id;

rollback;

-- ─────────────────────────────────────────────────────────────────────────────
-- Part 2. After the deploy only: the same, through the migration's report,
-- with the count each post was and what to do.
-- ─────────────────────────────────────────────────────────────────────────────

-- begin;
-- create temp table count_posts_past_their_status on commit drop as
--   select null::text as organisation, f.* from erp.count_posts_past_their_status_report() f where false;
-- do $report$
-- declare t record;
-- begin
--   for t in select tn.id, tn.code from erp.tenant tn where tn.deleted_at is null order by tn.code loop
--     perform erp_meta.act_in_tenant(t.id);
--     insert into count_posts_past_their_status
--       select t.code, f.* from erp.count_posts_past_their_status_report() f;
--   end loop;
-- end
-- $report$;
-- select * from count_posts_past_their_status order by organisation, posted_at, count_task_id;
-- rollback;

-- ─────────────────────────────────────────────────────────────────────────────
-- Part 3. After the deploy only: the counts the backfill held (D2). Read only.
-- ─────────────────────────────────────────────────────────────────────────────

-- begin read only;
-- select tn.code as organisation, t.id as count_task_id, t.status, i.code as item,
--        l.code as location, t.expected_quantity, t.counted_quantity, t.variance,
--        t.post_held_reason
--   from erp.count_task t
--   join erp.tenant tn on tn.id = t.tenant_id
--   join erp.item i on i.tenant_id = t.tenant_id and i.id = t.item_id
--   left join erp.location l on l.tenant_id = t.tenant_id and l.id = t.location_id
--  where t.stock_status is null
--    and t.status in ('open', 'counted', 'pending_approval', 'approved', 'rejected')
--    and t.post_held_reason like 'status_unknown:%'
--  order by tn.code, t.status, i.code;
-- rollback;
