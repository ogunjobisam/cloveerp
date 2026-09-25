-- =============================================================================
-- 20260928  Stock documents whose state their stock did not make
-- -----------------------------------------------------------------------------
-- The operator's half of 20260928000000 (PR11 M1, decision D1). That
-- migration refuses, from the moment it applies, every transfer order and
-- stock adjustment move the stock did not make. It changes no existing row.
-- Documents already moved that way before it stay as they are until somebody
-- decides about them, and this file is how that is done.
--
-- Run it by hand, from a session that bypasses row security (the project's
-- postgres role), in psql. It is not part of the build and nothing runs it.
--
--   Part 1 reads only, and needs nothing the migration adds, so it runs the
--          same before the deploy that carries 20260928000000 as after it.
--          Run it both times and keep both outputs with the release.
--   Part 2 is the same reading through erp.stock_state_mismatch_report(),
--          which exists only once the migration has applied: a check that
--          the two agree, after the deploy.
--   Part 3 writes. It returns stock stranded in transit to the shelf it left,
--          one transfer at a time, for the transfers the report lists and the
--          owner has agreed to repair. It is commented out on purpose.
-- =============================================================================

\set ON_ERROR_STOP on

-- ─────────────────────────────────────────────────────────────────────────────
-- Part 1. Every organisation, in plain SQL over the tables. Read only.
-- ─────────────────────────────────────────────────────────────────────────────

begin read only;

with docs as (
  select tn.code as tenant_code, d.id, d.document_number, dt.code as type_code,
         dt.base_type_code as base, s.code as state, s.is_terminal, s.is_committed,
         (select count(*) from erp.stock_movement m
           where m.tenant_id = d.tenant_id and m.document_id = d.id)::integer as movements,
         (select coalesce(sum(case when m.to_status = 'in_transit' then m.quantity else 0 end), 0)
               - coalesce(sum(case when m.from_status = 'in_transit' then m.quantity else 0 end), 0)
            from erp.stock_movement m
           where m.tenant_id = d.tenant_id and m.document_id = d.id) as in_transit,
         exists (select 1 from erp.stock_movement m
                  where m.tenant_id = d.tenant_id and m.document_id = d.id
                    and m.site_id = d.destination_site_id) as arrived,
         exists (select 1 from erp.stock_movement m
                  where m.tenant_id = d.tenant_id and m.document_id = d.id
                    and m.from_status = 'in_transit' and not m.is_reversal) as part_arrived,
         exists (select 1 from erp.stock_movement m
                  where m.tenant_id = d.tenant_id and m.document_id = d.id and m.is_reversal) as part_returned,
         exists (select 1 from erp.stock_movement m
                  where m.tenant_id = d.tenant_id and m.document_id = d.id and not m.is_reversal
                    and not exists (select 1 from erp.stock_movement r
                                     where r.tenant_id = m.tenant_id
                                       and r.reverses_movement_id = m.id)) as stands
    from erp.tenant tn
    join erp.document d on d.tenant_id = tn.id
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
    join erp.object_state os
      on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
    join erp.state s on s.tenant_id = os.tenant_id and s.id = os.current_state_id
   where tn.deleted_at is null
     and dt.base_type_code in ('transfer_order', 'adjustment')
),
found as (
  select x.tenant_code, 'a transfer in discrepancy' as finding, x.document_number, x.state,
         x.movements, x.in_transit, x.part_arrived, x.part_returned
    from docs x where x.base = 'transfer_order' and x.state = 'discrepancy'
  union all
  select x.tenant_code, 'a transfer cancelled with stock still in transit', x.document_number, x.state,
         x.movements, x.in_transit, x.part_arrived, x.part_returned
    from docs x
   where x.base = 'transfer_order' and x.is_terminal and x.state not in ('received', 'closed')
     and x.in_transit > 0
  union all
  select x.tenant_code, 'a transfer cancelled after its stock moved', x.document_number, x.state,
         x.movements, x.in_transit, x.part_arrived, x.part_returned
    from docs x
   where x.base = 'transfer_order' and x.is_terminal and x.state not in ('received', 'closed')
     and x.in_transit <= 0 and x.stands
  union all
  select x.tenant_code, 'a transfer whose state says stock moved that its movements do not',
         x.document_number, x.state, x.movements, x.in_transit, x.part_arrived, x.part_returned
    from docs x
   where x.base = 'transfer_order'
     and ((x.state = 'in_transit' and x.movements = 0)
          or (x.state in ('received', 'closed') and (not x.arrived or x.in_transit <> 0)))
  union all
  select x.tenant_code, 'a stock adjustment posted with no movement', x.document_number, x.state,
         x.movements, null, null, null
    from docs x
   where x.base = 'adjustment' and x.is_terminal and x.is_committed and x.movements = 0
)
select tenant_code, finding, document_number, state, movements, in_transit,
       -- Repairable by Part 3: stranded in transit, none of it arrived.
       coalesce(in_transit > 0 and not part_arrived
                and finding in ('a transfer in discrepancy', 'a transfer cancelled with stock still in transit'),
                false) as repairable,
       part_returned
  from found
 order by tenant_code, finding, document_number;

rollback;

-- ─────────────────────────────────────────────────────────────────────────────
-- Part 2. After the deploy only: the same, through the migration's report.
-- ─────────────────────────────────────────────────────────────────────────────

-- begin;
-- create temp table stock_state_mismatches on commit drop as
--   select null::text as tenant_code, f.* from erp.stock_state_mismatch_report() f where false;
-- do $report$
-- declare t record;
-- begin
--   for t in select tn.id, tn.code from erp.tenant tn where tn.deleted_at is null order by tn.code loop
--     perform erp_meta.act_in_tenant(t.id);
--     insert into stock_state_mismatches select t.code, f.* from erp.stock_state_mismatch_report() f;
--   end loop;
-- end
-- $report$;
-- select * from stock_state_mismatches order by tenant_code, finding, document_number;
-- rollback;

-- ─────────────────────────────────────────────────────────────────────────────
-- Part 3. The repair, one transfer at a time. After the deploy. Uncomment,
-- fill in, run.
--
-- Only a transfer Part 1 marks repairable can be repaired;
-- erp.return_stranded_transit_stock() refuses any other with
-- CLOVEERP_TRANSFER_NOT_STRANDED. It reverses each despatch leg not yet
-- returned, so the goods go back to the place they left at the despatching
-- site, and no value moves. The document's state is not touched: a cancelled
-- transfer stays cancelled, and one in discrepancy stays there, now with
-- nothing in transit. The audit trail records the database role that ran it
-- and the reason; the reason is also written on each returned movement.
-- Say who decided and where that is recorded.
-- ─────────────────────────────────────────────────────────────────────────────

-- begin;
-- select erp_meta.act_in_tenant((select id from erp.tenant where code = '<organisation code>'));
-- select erp.return_stranded_transit_stock('<document id>'::uuid,
--          'Stranded in transit by a cancel after despatch; returned on <date> as agreed by <owner>, <ticket>');
-- select * from erp.stock_state_mismatch_report() where document_id = '<document id>'::uuid;
-- select erp.assert_stock_reconciles();
-- commit;   -- or rollback, if the report or the reconciliation says otherwise
