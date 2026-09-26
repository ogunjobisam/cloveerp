-- =============================================================================
-- 20260929  What is on goods received not invoiced that no open receipt explains
-- -----------------------------------------------------------------------------
-- The operator's half of 20260929000000 (PR12 M1, decisions D1 and D2). From
-- that migration the close's "Goods received not invoiced reviewed" runs
-- erp.assert_grni_reconciles(), which refuses when the receipts still open at
-- order price, the ledger balance on the account and the balance sheet as at
-- today disagree. It is waivable with a reason, and it is not in the deploy's
-- gate, so an organisation carrying a residue meets it at its next close and
-- nowhere else. This file says, before that close, which organisations will,
-- and what their residue is made of.
--
-- Run it by hand, from a session that bypasses row security (the project's
-- postgres role), in psql. It is not part of the build and nothing runs it.
--
--   Part 1 reads only, and needs nothing the migration adds, so it runs the
--          same before the deploy as after it. It is the same arithmetic as
--          erp.grni_reconciliation(), in plain SQL, for every organisation.
--   Part 2 breaks each organisation's account down by what posted it, the
--          posting rule and its version, so the four causes the check's hint
--          names can be read off: purchase_invoice lines before
--          procurement-controls v4, consignment_consumption, manual journals,
--          and anything dated after today.
--   Part 3 is the check itself, per organisation, after the deploy.
--          Commented out, because the function does not exist before.
--
-- Nothing is repaired here. A residue is cleared by a journal an accountant
-- posts, or waived at the close with a reason that says which cause it is.
-- =============================================================================

\set ON_ERROR_STOP on

begin read only;

-- ─────────────────────────────────────────────────────────────────────────────
-- Part 1. Ledger against open receipts, every organisation. Read only.
-- ─────────────────────────────────────────────────────────────────────────────

with acct as (
  -- The account by name first, as erp.tenant_account_code() finds it: GRNI
  -- controls nothing, and §8.1 numbers it 3200.
  select distinct on (a.tenant_id) a.tenant_id, a.code
    from erp.account a
    join erp_ref.chart_account_purpose cap on cap.purpose = 'goods_received_not_invoiced'
   where a.status = 'active' and a.is_postable and lower(a.name) = lower(cap.name)
   order by a.tenant_id, a.code
),
ledger as (
  select ac.tenant_id, ac.code,
         coalesce(sum(case when j.status = 'posted' then l.credit_minor - l.debit_minor end), 0)::bigint as ledger_minor,
         coalesce(sum(case when j.status = 'posted' and j.posting_date > current_date
                           then l.credit_minor - l.debit_minor end), 0)::bigint as after_today_minor
    from acct ac
    join erp.account a on a.tenant_id = ac.tenant_id and a.code = ac.code
    left join erp.journal_line l on l.tenant_id = a.tenant_id and l.account_id = a.id
    left join erp.journal j on j.id = l.journal_id
   group by ac.tenant_id, ac.code
),
open_receipts as (
  -- erp.grni_report() without its tenant filter: received, less returned on a
  -- committed credit note, less invoiced, at the order line's price.
  select ol.tenant_id,
         sum(round(((coalesce(ol.quantity_fulfilled, 0)
                     - coalesce((select sum(rr.quantity)
                                   from erp.document_relation rr
                                   join erp.document_relation fr
                                     on fr.tenant_id = rr.tenant_id and fr.from_line_id = rr.to_line_id
                                    and fr.relation_kind = 'fulfils' and fr.to_line_id = ol.id
                                   join erp.document cn on cn.tenant_id = rr.tenant_id and cn.id = rr.from_document_id
                                   join erp.object_state os
                                     on os.tenant_id = cn.tenant_id and os.object_type = 'document' and os.object_id = cn.id
                                   join erp.state st on st.id = os.current_state_id
                                  where rr.tenant_id = ol.tenant_id and rr.relation_kind = 'returns'
                                    and rr.to_line_id is not null and st.is_committed
                                    and not coalesce(cn.is_cancelled, false)), 0))
                    - coalesce(ol.quantity_invoiced, 0)) * ol.unit_price_minor))::bigint as open_minor
    from erp.document_line ol
    join erp.document d on d.id = ol.document_id
    join erp.document_type dt on dt.id = d.document_type_id
   where dt.base_type_code = 'purchase_order'
     and not ol.is_cancelled
     and coalesce(ol.quantity_fulfilled, 0) > coalesce(ol.quantity_invoiced, 0)
   group by ol.tenant_id
)
select tn.code as tenant, lg.code as account,
       coalesce(o.open_minor, 0) as open_receipts_minor,
       lg.ledger_minor,
       lg.ledger_minor - coalesce(o.open_minor, 0) as difference_minor,
       lg.after_today_minor
  from erp.tenant tn
  join ledger lg on lg.tenant_id = tn.id
  left join open_receipts o on o.tenant_id = tn.id
 where tn.deleted_at is null
 order by abs(lg.ledger_minor - coalesce(o.open_minor, 0)) desc, tn.code;

-- Part 1 counts a line only while more was received than billed, and nets the
-- returns inside it, as the report does. A line billed for more than was
-- received is not open and is not in the figure; its excess is on the ledger.

-- ─────────────────────────────────────────────────────────────────────────────
-- Part 2. What posted to the account, by source, rule and version. Read only.
-- ─────────────────────────────────────────────────────────────────────────────

select tn.code as tenant, a.code as account,
       coalesce(pr.code, j.source_code, 'unnamed') as posted_by,
       l.posting_rule_version as rule_version,
       (j.posting_date > current_date) as after_today,
       count(*) as lines,
       sum(l.credit_minor - l.debit_minor)::bigint as net_credit_minor,
       min(j.posting_date) as first_posted, max(j.posting_date) as last_posted
  from erp.tenant tn
  join erp.account a on a.tenant_id = tn.id
  join erp_ref.chart_account_purpose cap on cap.purpose = 'goods_received_not_invoiced'
  join erp.journal_line l on l.tenant_id = a.tenant_id and l.account_id = a.id
  join erp.journal j on j.id = l.journal_id and j.status = 'posted'
  left join erp.posting_rule pr on pr.id = l.posting_rule_id
 where tn.deleted_at is null
   and a.status = 'active' and lower(a.name) = lower(cap.name)
 group by 1, 2, 3, 4, 5
 order by 1, 2, 3, 4, 5;

rollback;

-- ─────────────────────────────────────────────────────────────────────────────
-- Part 3. After the deploy: the check, inside each organisation. Read only.
-- ─────────────────────────────────────────────────────────────────────────────
--
-- begin read only;
-- do $grni$
-- declare
--   r record;
-- begin
--   for r in select id, code from erp.tenant where deleted_at is null order by code loop
--     perform erp_meta.act_in_tenant(r.id);
--     begin
--       raise notice '%: %', r.code, erp.assert_grni_reconciles();
--     exception when others then
--       raise notice '%: %', r.code, sqlerrm;
--     end;
--   end loop;
--   perform erp_meta.stop_acting_in_tenant();
-- end
-- $grni$;
-- rollback;
