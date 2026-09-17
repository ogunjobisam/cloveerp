-- An ageing agrees with the ledger.
--
-- The v1 Definition of Done has a master gate of four ties. Three are inside
-- erp.assert_whole_database_reconciles(). This is the fourth, which the
-- Definition of Done states as two sentences:
--
--     AR ageing total equals the debtors control account.
--     AP ageing total equals the creditors control account.
--
-- 20260918400000 said the subledger reconciliation carried both. It does not,
-- quite. erp.assert_subledger_reconciles() compares the control account with
-- erp.subledger_item, and the posting bridge writes both of those from the same
-- journal line in the same loop, so the comparison is true by construction and
-- has never caught anything. The ageing a person reads is a third thing, and
-- nothing compared it with either.
--
-- ── Two reports, two answers about the same debt ──────────────────────────────
--
-- A customer is invoiced £1,000 and pays £500.
--
--   erp.receivables_ageing(), behind the Receivables ageing screen, sums the
--   subledger: the invoice's £1,000 and the receipt's £500 credit. It says the
--   customer owes £500 — the invoice at £1,000 in its overdue band and the
--   receipt at minus £500 in the band of the day it arrived, because each
--   subledger row was banded on its own.
--
--   erp.ageing, behind the Receivables and payables ageing report the base pack
--   ships, lists documents at their gross and drops one only when its state is
--   terminal. Paid is terminal; part paid is still issued. It says the customer
--   owes £1,000.
--
-- The ledger says £500. So the report was wrong on its face, the screen was
-- right in total and wrong in its bands, and nothing said so. The seeded
-- demonstration part-pays roughly one invoice in seven, so every demonstration
-- carries this.
--
-- And there was a way for both to disagree with the ledger. The screen joined
-- erp.party with an inner join, and the payables screen filtered party_id is
-- not null, so a posting on a debtors or creditors control account that named
-- nobody sat in the control account and was on neither screen.
--
-- ── The decision: one ageing, and it is what is owed ──────────────────────────
--
-- The control account is net of cash. An ageing that is to equal it has to be
-- net as well, and a report that shows a half-paid invoice at its full amount is
-- wrong whatever the ledger says. So the net ageing is the truth, and there is
-- now exactly one computation of it:
--
--   erp.ageing_balance   one row per company, control account, currency,
--                        party and document — what is still owed on each
--                        document, and what sits on account against the party
--                        without a document — read from the subledger and
--                        nothing else.
--
--   erp.ageing           the report. The same rows, with the document's
--                        number, type, dates and face value beside them, and a
--                        new column, outstanding_minor, which is what is owed.
--
--   erp.receivables_ageing(), erp.payables_ageing()
--                        the two screens. The same rows, totalled by party and
--                        banded by each document's due date.
--
-- The gross figure is not removed; it is named. gross_minor was always the
-- document's face value and still is, and signed_minor is still that value
-- signed for a credit. Neither is what is owed and the report no longer shows
-- either in that place: the base pack's version of the report now puts
-- outstanding_minor where signed_minor was. Nothing in the product reads gross
-- from erp.ageing as an amount owed — the one other reader,
-- erp_test.document_side_suite(), reads direction — so nothing needs gross
-- under a new name.
--
-- An organisation that already promoted the old report version keeps it until
-- its base pack is re-applied, because erp.report_version is promotable
-- configuration a migration may not write on a live organisation; the columns
-- it names are still on the view and still mean what they are called.
--
-- ── What is owed on a document, when cash did not say which document ──────────
--
-- Three routes settle an item, and they record it differently:
--
--   erp.apply_cash()          a settling row naming the party and NO document,
--                             and settled_minor on the item it settled;
--   erp.apply_cash_to_item()  a settling row naming the party AND the document,
--   the payment run           and settled_minor on the item as well.
--
-- Summing a document's own rows is right for the second and third and leaves the
-- first at gross. Subtracting settled_minor is right for the first and counts
-- the second and third twice. So, per document:
--
--     owed = its rows' net − greatest(0, settled − what its own settling rows
--                                               already took off)
--
-- which is exact for all three, for any mixture of them, and for a credit note,
-- whose own row runs the other way and has settled nothing. The part of a settlement
-- that is attributed to a document this way is taken back out of the party's
-- on-account row, so for every company, control account, currency and party
-- the rows of erp.ageing_balance total exactly what the subledger holds. That
-- is arithmetic, not a hope; and it is what lets the demonstration's own
-- history — every part payment it made through erp.apply_cash() — show the
-- amount still owed on each invoice without one posted row being touched.
--
-- ── A control posting with no party ───────────────────────────────────────────
--
-- Surfaced, not refused. It appears on the report and on both screens as
-- Unallocated, in the company and currency it was posted in, aged from when it
-- was posted. Refusing it where it is written would have meant a new check on
-- every writer of erp.subledger_item — the bridge, three settlement routes, the
-- cutover loader and every suite fixture — and a refusal that arrives in the
-- middle of a month-end posting loses the posting rather than showing it. A row
-- a person can see and chase is the honest answer.
--
-- The tax control is untouched. Its detail names no party by design, and
-- nothing here reads a control kind other than receivable and payable: no tax
-- row reaches the ageing, the tie does not compare the tax account, and the
-- subledger reconciliation goes on holding tax detail to its account exactly as
-- before.
--
-- ── The tie ───────────────────────────────────────────────────────────────────
--
-- erp.assert_ageing_equals_control(), registered at tenant scope, so the
-- whole-database reconciliation drives it for every organisation. For every
-- company, direction and currency, the report's outstanding total equals the
-- control accounts' balance in posted journals — the general ledger, not the
-- subledger — to the penny. And the two screens total, per currency, what the
-- report totals. The report side is read through erp.ageing itself, so a report
-- that goes back to dropping rows — a party join, a state filter, a gross figure
-- — fails the gate the day it lands.
--
-- The live line goes from 51 checks to 54: one more tenant assertion, three
-- organisations.
--
-- It is not waived. The close gains a sixth task, ageing_agrees, carrying the
-- tie; erp.close_tie_check() and erp.close_check_is_a_tie() name it, so
-- erp.set_close_task_tie() stamps it unwaivable on the template and on every
-- raised task, and the organisations that already hold the checklist are swept
-- the way 20260918400000 swept them, because erp.configuration_manifest() does
-- not carry close_task. Four tasks now carry the four ties: the subledger
-- reconciliation and the ageing are the debtors and creditors ties seen from
-- their two ends, the detail and the report.
--
-- ── History ───────────────────────────────────────────────────────────────────
--
-- Nothing posted is restated. The view reads what was written. The existing
-- subledger reconciliation already holds on every organisation, and the report
-- totals the subledger by arithmetic, so the demonstration's existing month has
-- no difference to find in total. What changes on it is presentation: a
-- part-paid invoice now shows what is left on it.
--
-- ── Collateral counts, restated with the reason ──────────────────────────────
--
--   erp_test.finance_depth_suite()      five close tasks → six; four with a
--                                       check → five; three unwaivable → four.
--   erp_test.trial_balance_tie_suite()  five raised → six; three unwaivable →
--                                       four; ten tenant assertions → eleven;
--                                       and it completes the new tie before it
--                                       closes the period, as a person would.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. What is owed, once
-- ═════════════════════════════════════════════════════════════════════════════

-- The grouped-by-document subquery is written out in both branches rather than
-- shared in a CTE: a CTE read twice is materialised, and the organisation a
-- caller filters on could then not reach the scan of erp.subledger_item.
create view erp.ageing_balance with (security_invoker = true) as
select o.tenant_id, o.entity_id, o.control_account_id, o.control_kind,
       case o.control_kind when 'receivable' then 'receivable' else 'payable' end as direction,
       o.currency, o.party_id, o.document_id,
       o.outstanding_minor, o.due_on
  from (
    -- What is still owed on each document.
    select g.tenant_id, g.entity_id, g.control_account_id, g.control_kind,
           g.currency, g.party_id, g.document_id,
           (g.amount_minor - g.attributed_minor)::bigint as outstanding_minor,
           coalesce(g.owed_due_on, g.any_due_on) as due_on
      from (
        select si.tenant_id, si.entity_id, si.control_account_id, si.control_kind,
               si.currency, si.party_id, si.document_id,
               sum(case si.control_kind when 'receivable' then si.debit_minor - si.credit_minor
                                        else si.credit_minor - si.debit_minor end) as amount_minor,
               -- Settled against this document by cash that did not name it:
               -- what settled_minor records beyond what this document's own
               -- settling rows already took off.
               greatest(0::numeric,
                 sum(coalesce(si.settled_minor, 0))
                 - sum(case si.control_kind
                         when 'receivable' then greatest(0::bigint, si.credit_minor - si.debit_minor)
                         else greatest(0::bigint, si.debit_minor - si.credit_minor) end)) as attributed_minor,
               min(coalesce(si.due_date, si.posting_date))
                 filter (where case si.control_kind when 'receivable' then si.debit_minor - si.credit_minor
                                                    else si.credit_minor - si.debit_minor end > 0) as owed_due_on,
               min(coalesce(si.due_date, si.posting_date)) as any_due_on
          from erp.subledger_item si
         where si.control_kind in ('receivable', 'payable')
         group by si.tenant_id, si.entity_id, si.control_account_id, si.control_kind,
                  si.currency, si.party_id, si.document_id
      ) g
     where g.document_id is not null

    union all

    -- What sits on account against the party: detail that names no document,
    -- less what of it was attributed to a document above. Party null is a
    -- posting that named nobody, and is shown rather than dropped.
    select g.tenant_id, g.entity_id, g.control_account_id, g.control_kind,
           g.currency, g.party_id, null::uuid,
           sum(case when g.document_id is null then g.amount_minor
                    else g.attributed_minor end)::bigint,
           coalesce(min(coalesce(g.owed_due_on, g.any_due_on)) filter (where g.document_id is null),
                    current_date)
      from (
        select si.tenant_id, si.entity_id, si.control_account_id, si.control_kind,
               si.currency, si.party_id, si.document_id,
               sum(case si.control_kind when 'receivable' then si.debit_minor - si.credit_minor
                                        else si.credit_minor - si.debit_minor end) as amount_minor,
               greatest(0::numeric,
                 sum(coalesce(si.settled_minor, 0))
                 - sum(case si.control_kind
                         when 'receivable' then greatest(0::bigint, si.credit_minor - si.debit_minor)
                         else greatest(0::bigint, si.debit_minor - si.credit_minor) end)) as attributed_minor,
               min(coalesce(si.due_date, si.posting_date))
                 filter (where case si.control_kind when 'receivable' then si.debit_minor - si.credit_minor
                                                    else si.credit_minor - si.debit_minor end > 0) as owed_due_on,
               min(coalesce(si.due_date, si.posting_date)) as any_due_on
          from erp.subledger_item si
         where si.control_kind in ('receivable', 'payable')
         group by si.tenant_id, si.entity_id, si.control_account_id, si.control_kind,
                  si.currency, si.party_id, si.document_id
      ) g
     group by g.tenant_id, g.entity_id, g.control_account_id, g.control_kind,
              g.currency, g.party_id
  ) o
 where o.outstanding_minor <> 0;

comment on view erp.ageing_balance is
  'What is owed, once: one row per company, control account, currency, party '
  'and document of the receivable and payable subledger, with what is still '
  'owed on it and the date it ages from. A document''s row is net of every '
  'settlement against it, whichever route recorded it; detail that names no '
  'document is one on-account row per party, and a posting that named no party '
  'is a row with no party rather than no row. For every company, control '
  'account, currency and party the rows total exactly what the subledger holds. '
  'erp.ageing and both ageing screens read this and nothing else (20260918500000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The report
-- ═════════════════════════════════════════════════════════════════════════════

-- A view cannot change shape through create or replace. It is dropped and made
-- again, after saying what depends on it: nothing in the repository does, and a
-- dependent that exists only on some database is named here rather than taken
-- away by a cascade.
do $dependents$
declare
  v_names text;
begin
  select string_agg(distinct dep.relnamespace::regnamespace::text || '.' || dep.relname, ', ')
    into v_names
    from pg_catalog.pg_depend d
    join pg_catalog.pg_rewrite rw on rw.oid = d.objid
    join pg_catalog.pg_class dep on dep.oid = rw.ev_class
   where d.refobjid = 'erp.ageing'::regclass
     and dep.oid <> 'erp.ageing'::regclass;
  if v_names is not null then
    raise exception 'CLOVEERP_AGEING_HAS_DEPENDENTS: % read erp.ageing, which this migration re-creates', v_names
      using hint = 'Re-create the dependents after the view in a new migration version, rather than dropping them with a cascade.';
  end if;
end
$dependents$;

drop view erp.ageing;

create view erp.ageing with (security_invoker = true) as
-- In the ledger: what is owed, document by document and on account.
select b.tenant_id, d.id, b.entity_id, d.site_id, d.document_number,
       d.document_type, d.base_type,
       b.direction,
       b.party_id, p.code as party_code,
       coalesce(p.name, 'Unallocated') as party_name,
       d.document_date, b.due_on as due_date, b.currency, d.gross_minor,
       case when d.base_type = 'credit_reference' then -d.gross_minor
            else d.gross_minor end                    as signed_minor,
       greatest(0, current_date - b.due_on)           as days_overdue,
       case
         when current_date <= b.due_on then 'current'
         when current_date - b.due_on <= 30 then '1-30'
         when current_date - b.due_on <= 60 then '31-60'
         when current_date - b.due_on <= 90 then '61-90'
         else '90+' end                               as bucket,
       b.outstanding_minor
  from erp.ageing_balance b
  left join erp.document_view d on d.tenant_id = b.tenant_id and d.id = b.document_id
  left join erp.party p on p.tenant_id = b.tenant_id and p.id = b.party_id

union all

-- Raised and open, and not in the ledger yet: listed at its face value, owing
-- nothing on the control account until it posts. Direction from the role the
-- document was raised against, as it has been since 20260916042000.
select d.tenant_id, d.id, d.entity_id, d.site_id, d.document_number,
       d.document_type, d.base_type,
       case pr.role_kind
         when 'customer' then 'receivable'
         when 'supplier' then 'payable'
         else 'other' end,
       d.party_id, d.party_code, d.party_name, d.document_date, d.due_date,
       d.currency, d.gross_minor,
       case when d.base_type = 'credit_reference' then -d.gross_minor
            else d.gross_minor end,
       greatest(0, current_date - coalesce(d.due_date, d.document_date)),
       case
         when current_date <= coalesce(d.due_date, d.document_date) then 'current'
         when current_date - coalesce(d.due_date, d.document_date) <= 30 then '1-30'
         when current_date - coalesce(d.due_date, d.document_date) <= 60 then '31-60'
         when current_date - coalesce(d.due_date, d.document_date) <= 90 then '61-90'
         else '90+' end,
       null::bigint
  from erp.document_view d
  join erp.document doc on doc.tenant_id = d.tenant_id and doc.id = d.id
  left join erp.party_role pr
    on pr.tenant_id = d.tenant_id and pr.id = doc.party_role_id
 where d.base_type in ('invoice_reference', 'credit_reference')
   and not coalesce(d.is_cancelled, false)
   and not coalesce(d.state_is_terminal, false)
   and not exists (select 1 from erp.subledger_item si
                    where si.tenant_id = d.tenant_id and si.document_id = d.id
                      and si.control_kind in ('receivable', 'payable'));

comment on view erp.ageing is
  'Behind the Receivables and payables ageing report. What is owed on every '
  'invoice and credit in the ledger (outstanding_minor), net of the cash and '
  'credits settled against it, and what sits on account against a party with no '
  'document — Unallocated where the posting named no party — by direction and '
  'age bucket. gross_minor and signed_minor are the document''s face value, not '
  'what is owed. A document raised and not yet posted is listed with '
  'outstanding_minor null. Per company, direction and currency, outstanding_minor '
  'totals the debtors and creditors control accounts, and '
  'erp.assert_ageing_equals_control() refuses a penny of difference '
  '(20260918500000).';

-- The version of the report the base pack ships shows what is owed where it
-- showed the signed face value.
do $report$
declare
  v_n integer;
begin
  update erp_ref.pack_item pi
     set payload = jsonb_set(pi.payload, '{version,columns}',
           '["document_number","document_type","direction","party_code","party_name","document_date","due_date","currency","gross_minor","outstanding_minor","days_overdue","bucket"]'::jsonb)
   where pi.pack_code = 'base'
     and pi.object_kind = 'report'
     and pi.object_key = 'ageing'
     and pi.payload -> 'version' ->> 'view' = 'ageing';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'CLOVEERP_AGEING_REPORT_UNRECOGNISED: % base pack report(s) named ageing over the ageing view, expected 1', v_n;
  end if;
end
$report$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The two screens read the same rows
-- ═════════════════════════════════════════════════════════════════════════════

-- The live bodies are the ones the files hold: erp.receivables_ageing() was last
-- written whole in 20260914076000 and erp.payables_ageing() in 20260909212619,
-- and no migration since has patched either. Said here, before they are
-- replaced, rather than assumed.
do $screens$
declare
  v_ar text := pg_catalog.pg_get_functiondef('erp.receivables_ageing(date)'::regprocedure);
  v_ap text := pg_catalog.pg_get_functiondef('erp.payables_ageing(date)'::regprocedure);
begin
  if (length(v_ar) - length(replace(v_ar, 'join erp.party p on p.id = o.party_id', ''))) / length('join erp.party p on p.id = o.party_id') <> 1
     or position('from erp.subledger_item si' in v_ar) = 0 then
    raise exception 'CLOVEERP_AGEING_SCREEN_UNRECOGNISED: erp.receivables_ageing() is not the body this migration replaces'
      using hint = 'Read the live body with pg_get_functiondef and write the replacement against it under a new migration version.';
  end if;
  if (length(v_ap) - length(replace(v_ap, 'and si.party_id is not null', ''))) / length('and si.party_id is not null') <> 1
     or position('join erp.party p on p.id = o.party_id' in v_ap) = 0 then
    raise exception 'CLOVEERP_AGEING_SCREEN_UNRECOGNISED: erp.payables_ageing() is not the body this migration replaces'
      using hint = 'Read the live body with pg_get_functiondef and write the replacement against it under a new migration version.';
  end if;
end
$screens$;

-- Same signature and the same columns, so the doors over them and their grants
-- stay as they are, and every key a screen reads is still there.
create or replace function erp.receivables_ageing(p_as_at date default null)
returns table (party_id uuid, party_name text, currency char(3),
               current_minor bigint, days_1_30 bigint, days_31_60 bigint,
               days_61_90 bigint, days_over_90 bigint, total_minor bigint)
language sql
stable
security invoker
set search_path = ''
as $$
  select b.party_id, coalesce(p.name, 'Unallocated'), b.currency,
         coalesce(sum(b.outstanding_minor) filter (where b.due_on >= coalesce(p_as_at, current_date)), 0)::bigint,
         coalesce(sum(b.outstanding_minor) filter (where coalesce(p_as_at, current_date) - b.due_on between 1 and 30), 0)::bigint,
         coalesce(sum(b.outstanding_minor) filter (where coalesce(p_as_at, current_date) - b.due_on between 31 and 60), 0)::bigint,
         coalesce(sum(b.outstanding_minor) filter (where coalesce(p_as_at, current_date) - b.due_on between 61 and 90), 0)::bigint,
         coalesce(sum(b.outstanding_minor) filter (where coalesce(p_as_at, current_date) - b.due_on > 90), 0)::bigint,
         sum(b.outstanding_minor)::bigint
    from erp.ageing_balance b
    left join erp.party p on p.tenant_id = b.tenant_id and p.id = b.party_id
   where b.tenant_id = erp.current_tenant_id()
     and b.control_kind = 'receivable'
   group by b.party_id, p.name, b.currency
  having sum(b.outstanding_minor) <> 0
   order by 9 desc
$$;

comment on function erp.receivables_ageing(date) is
  'What each customer owes, by currency, in bands of how overdue each document '
  'is — read from erp.ageing_balance, so a part-paid invoice sits in its own '
  'band at what is left on it rather than at its face value with the receipt '
  'in another band. A receivable posted with no customer is shown as '
  'Unallocated rather than left out (20260918500000).';

create or replace function erp.payables_ageing(p_as_at date default null)
returns table (
  party_id uuid, party_name text, currency char(3),
  not_due_minor bigint, days_1_30_minor bigint, days_31_60_minor bigint,
  days_61_90_minor bigint, days_90_plus_minor bigint, total_minor bigint)
language sql
stable
security invoker
set search_path = ''
as $$
  select b.party_id, coalesce(p.name, 'Unallocated'), b.currency,
         coalesce(sum(b.outstanding_minor) filter (where b.due_on >= coalesce(p_as_at, current_date)), 0)::bigint,
         coalesce(sum(b.outstanding_minor) filter (where coalesce(p_as_at, current_date) - b.due_on between 1 and 30), 0)::bigint,
         coalesce(sum(b.outstanding_minor) filter (where coalesce(p_as_at, current_date) - b.due_on between 31 and 60), 0)::bigint,
         coalesce(sum(b.outstanding_minor) filter (where coalesce(p_as_at, current_date) - b.due_on between 61 and 90), 0)::bigint,
         coalesce(sum(b.outstanding_minor) filter (where coalesce(p_as_at, current_date) - b.due_on > 90), 0)::bigint,
         sum(b.outstanding_minor)::bigint
    from erp.ageing_balance b
    left join erp.party p on p.tenant_id = b.tenant_id and p.id = b.party_id
   where b.tenant_id = erp.current_tenant_id()
     and b.control_kind = 'payable'
   group by b.party_id, p.name, b.currency
  having sum(b.outstanding_minor) <> 0
   order by 9 desc
$$;

comment on function erp.payables_ageing(date) is
  'What is owed to each supplier, by currency, in bands of how close or far '
  'past each bill''s due date it is — read from erp.ageing_balance, so a '
  'part-paid bill sits at what is left on it. A payable posted with no supplier '
  'is shown as Unallocated rather than filtered out (20260918500000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The tie
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.assert_ageing_equals_control()
returns text
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant    uuid := erp.require_tenant_id();
  v_count     integer;
  v_detail    text;
  v_screens   integer;
  v_screen_detail text;
  v_companies integer;
begin
  -- The report against the ledger, per company, direction and currency. The
  -- ledger side is posted journal lines on the control accounts themselves, not
  -- the subledger, so this proves the whole road from the ageing a person reads
  -- to the balance the trial balance carries.
  with report as (
    select a.entity_id, a.direction, a.currency::text as currency,
           sum(a.outstanding_minor)::bigint as minor
      from erp.ageing a
     where a.tenant_id = v_tenant
       and a.outstanding_minor is not null
     group by a.entity_id, a.direction, a.currency
  ),
  control as (
    select acc.entity_id,
           case acc.control_kind when 'receivable' then 'receivable' else 'payable' end as direction,
           l.currency::text as currency,
           sum(case acc.control_kind when 'receivable' then l.debit_minor - l.credit_minor
                                     else l.credit_minor - l.debit_minor end)::bigint as minor
      from erp.journal_line l
      join erp.journal j on j.tenant_id = l.tenant_id and j.id = l.journal_id
      join erp.account acc on acc.tenant_id = l.tenant_id and acc.id = l.account_id
     where l.tenant_id = v_tenant
       and j.status = 'posted'
       and acc.control_kind in ('receivable', 'payable')
     group by acc.entity_id, acc.control_kind, l.currency
  ),
  compared as (
    select coalesce(r.entity_id, c.entity_id) as entity_id,
           coalesce(r.direction, c.direction) as direction,
           coalesce(r.currency, c.currency) as currency,
           coalesce(r.minor, 0) as report_minor,
           coalesce(c.minor, 0) as control_minor
      from report r
      full join control c
        on c.entity_id = r.entity_id and c.direction = r.direction and c.currency = r.currency
  )
  select count(*),
         string_agg(format('  %s, %s (%s): the ageing says %s, the control account says %s, out by %s',
                           coalesce(en.code, x.entity_id::text), x.direction, x.currency,
                           x.report_minor, x.control_minor, x.report_minor - x.control_minor),
                    E'\n' order by en.code, x.direction, x.currency)
    into v_count, v_detail
    from compared x
    left join erp.entity en on en.tenant_id = v_tenant and en.id = x.entity_id
   where x.report_minor <> x.control_minor;

  -- The two screens against the report, per currency. They have no company, so
  -- they are held to the report's total across companies, and the report is
  -- held to each company's control account above.
  with screens as (
    select 'receivable'::text as direction, s.currency::text as currency,
           sum(s.total_minor)::bigint as minor
      from erp.receivables_ageing() s
     group by s.currency
    union all
    select 'payable', s.currency::text, sum(s.total_minor)::bigint
      from erp.payables_ageing() s
     group by s.currency
  ),
  report as (
    select a.direction, a.currency::text as currency, sum(a.outstanding_minor)::bigint as minor
      from erp.ageing a
     where a.tenant_id = v_tenant
       and a.outstanding_minor is not null
       and a.direction in ('receivable', 'payable')
     group by a.direction, a.currency
  )
  select count(*),
         string_agg(format('  the %s ageing screen (%s) totals %s, the report %s',
                           coalesce(s.direction, r.direction), coalesce(s.currency, r.currency),
                           coalesce(s.minor, 0), coalesce(r.minor, 0)),
                    E'\n' order by coalesce(s.direction, r.direction), coalesce(s.currency, r.currency))
    into v_screens, v_screen_detail
    from screens s
    full join report r on r.direction = s.direction and r.currency = s.currency
   where coalesce(s.minor, 0) <> coalesce(r.minor, 0);

  if v_count > 0 or v_screens > 0 then
    raise exception E'CLOVEERP_AGEING_DOES_NOT_EQUAL_CONTROL: the ageing and the ledger disagree in % place(s)\n%',
      v_count + v_screens, concat_ws(E'\n', v_detail, v_screen_detail)
      using errcode = '23514',
            hint = 'Open the ageing and the trial balance for the company named. Money on a debtors or '
                   'creditors control account that no invoice, bill, credit or payment put there is money '
                   'the ageing cannot see: put it through the sales or purchase ledger, or reverse it.';
  end if;

  select count(*) into v_companies
    from erp.entity e where e.tenant_id = v_tenant;

  return format('ageing: equals the debtors and creditors control accounts for %s company(ies)',
                v_companies);
end;
$$;

comment on function erp.assert_ageing_equals_control is
  'The fourth tie of the v1 Definition of Done: for every company, direction and '
  'currency, what erp.ageing says is owed equals the balance of the debtors and '
  'creditors control accounts in posted journals, to the penny; and the '
  'receivables and payables ageing screens total, per currency, what the report '
  'totals. Reads the report rather than the subledger, so a report that starts '
  'dropping rows fails it. Per organisation; the whole-database reconciliation '
  'drives it for every one, and the close task ageing_agrees carries it '
  'unwaivably (20260918500000).';

revoke all on function erp.assert_ageing_equals_control() from public, anon;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('ageing_equals_control', 'The ageing equals the control accounts', 'assertion', 'tenant', 'erp',
   'assert_ageing_equals_control', '', null, '',
   'For every company, what the receivables and payables ageing says is owed equals the debtors and creditors control accounts in the ledger to the penny, and the two ageing screens total what the report totals. A posting that named nobody, or a report that leaves something out, shows here.',
   true, 97)
on conflict (code) do update set
  title = excluded.title, kind = excluded.kind, scope = excluded.scope,
  schema_name = excluded.schema_name, function_name = excluded.function_name,
  arguments = excluded.arguments, detail_function = excluded.detail_function,
  detail_arguments = excluded.detail_arguments, blurb = excluded.blurb,
  runs_in_ci = excluded.runs_in_ci, seq = excluded.seq;

select erp.register_refusal('CLOVEERP_AGEING_DOES_NOT_EQUAL_CONTROL',
  'Saying the books tie while the receivables or payables ageing and its control account in the ledger show different totals.',
  'The ageing is the list of who owes the company money and whom the company owes; the control account is the same money in the ledger. If the two differ by a penny, either something reached the account without saying whose money it is, or the ageing leaves something out, and a period closed over that difference reports debts nobody can chase or pay.',
  'Open the ageing and the trial balance for the company named, find the amount on the control account that no invoice, bill, credit or payment explains, and put it through the sales or purchase ledger or reverse it. Then run the check again.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The close carries it, and it is not waived
-- ═════════════════════════════════════════════════════════════════════════════

-- The three routines this extends were written whole by 20260918400000 and
-- nothing has touched them since. Said before they are replaced.
do $anchors$
declare
  v_tie  text := pg_catalog.pg_get_functiondef('erp.close_tie_check(text)'::regprocedure);
  v_is   text := pg_catalog.pg_get_functiondef('erp.close_check_is_a_tie(text)'::regprocedure);
  v_cfg  text := pg_catalog.pg_get_functiondef('erp.configure_period_close()'::regprocedure);
begin
  if position('when ''subledgers_reconcile'' then ''erp.assert_subledger_reconciles()''' in v_tie) = 0
     or position('ageing' in v_tie) > 0 then
    raise exception 'CLOVEERP_CLOSE_BODY_UNRECOGNISED: erp.close_tie_check() is not the body this migration extends';
  end if;
  if position('''erp.assert_subledger_reconciles()''' in v_is) = 0
     or position('ageing' in v_is) > 0 then
    raise exception 'CLOVEERP_CLOSE_BODY_UNRECOGNISED: erp.close_check_is_a_tie() is not the body this migration extends';
  end if;
  if position('''blocking_check'',''erp.assert_trial_balance_balances()''' in v_cfg) = 0
     or position('''period-close''' in v_cfg) = 0
     or position('ageing' in v_cfg) > 0 then
    raise exception 'CLOVEERP_CLOSE_BODY_UNRECOGNISED: erp.configure_period_close() is not the body this migration extends';
  end if;
end
$anchors$;

create or replace function erp.close_tie_check(p_task_code text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case lower(btrim(coalesce(p_task_code, '')))
           when 'trial_balance'        then 'erp.assert_trial_balance_balances()'
           when 'inventory_valued'     then 'erp.assert_inventory_reconciles()'
           when 'subledgers_reconcile' then 'erp.assert_subledger_reconciles()'
           when 'ageing_agrees'        then 'erp.assert_ageing_equals_control()'
         end
$$;

comment on function erp.close_tie_check(text) is
  'The blocking check a close task of this code carries because it is one of '
  'the four v1 ties, or null where the task is not one. Four tasks for four '
  'ties: the subledger reconciliation and the ageing (20260918500000) both carry '
  'the debtors and creditors ties, one from the detail and one from the report.';

create or replace function erp.close_check_is_a_tie(p_blocking_check text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select lower(regexp_replace(coalesce(p_blocking_check, ''), '\s', '', 'g')) in (
           'erp.assert_trial_balance_balances()',
           'erp.assert_inventory_reconciles()',
           'erp.assert_subledger_reconciles()',
           'erp.assert_ageing_equals_control()')
$$;

comment on function erp.close_check_is_a_tie(text) is
  'Whether a close task''s blocking check is one of the four v1 ties, whatever '
  'the task is called. Whitespace and case are ignored, so a check written with '
  'a space in it is still a tie.';

create or replace function erp.configure_period_close()
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_cs     uuid;
begin
  v_cs := erp.install_module_config(
    'period-close', 'Period close',
    'What has to be true before a period is closed, in the order it has to '
    'become true, with the checks that cannot be ticked past.',
    jsonb_build_array(
      jsonb_build_object('kind','close_task','key','stock_reconciles','payload',
        jsonb_build_object(
          'code','stock_reconciles','name','Stock ledger reconciles',
          'seq',10, 'blocking_check','erp.assert_stock_reconciles()')),
      jsonb_build_object('kind','close_task','key','inventory_valued','payload',
        jsonb_build_object(
          'code','inventory_valued','name','Inventory valuation agrees with the ledger',
          'seq',20, 'depends_on', jsonb_build_array('stock_reconciles'),
          'blocking_check','erp.assert_inventory_reconciles()')),
      jsonb_build_object('kind','close_task','key','subledgers_reconcile','payload',
        jsonb_build_object(
          'code','subledgers_reconcile','name','Subledgers agree with their control accounts',
          'seq',30, 'blocking_check','erp.assert_subledger_reconciles()')),
      jsonb_build_object('kind','close_task','key','ageing_agrees','payload',
        jsonb_build_object(
          'code','ageing_agrees','name','The ageing agrees with the debtors and creditors accounts',
          'seq',35, 'depends_on', jsonb_build_array('subledgers_reconcile'),
          'blocking_check','erp.assert_ageing_equals_control()')),
      jsonb_build_object('kind','close_task','key','grni_reviewed','payload',
        jsonb_build_object(
          'code','grni_reviewed','name','Goods received not invoiced reviewed',
          'seq',40, 'depends_on', jsonb_build_array('subledgers_reconcile'))),
      jsonb_build_object('kind','close_task','key','trial_balance','payload',
        jsonb_build_object(
          'code','trial_balance','name','Trial balance reviewed and signed',
          'seq',90,
          'depends_on', jsonb_build_array('inventory_valued','subledgers_reconcile','grni_reviewed'),
          'blocking_check','erp.assert_trial_balance_balances()'))));

  return v_cs;
end;
$$;

comment on function erp.configure_period_close() is
  'The six close tasks the product ships, as one promoted change set. Four of '
  'them carry the four v1 ties and are stamped unwaivable as they land: the '
  'trial balance (20260918400000), the inventory valuation against its control '
  'account, the subledgers against theirs, and the ageing against the debtors '
  'and creditors accounts (20260918500000).';

do $survived$
declare
  v_cfg text := pg_catalog.pg_get_functiondef('erp.configure_period_close()'::regprocedure);
begin
  if position('''erp.assert_stock_reconciles()''' in v_cfg) = 0
     or position('''erp.assert_inventory_reconciles()''' in v_cfg) = 0
     or position('''erp.assert_subledger_reconciles()''' in v_cfg) = 0
     or position('''erp.assert_ageing_equals_control()''' in v_cfg) = 0
     or position('''erp.assert_trial_balance_balances()''' in v_cfg) = 0
     or position('''grni_reviewed''' in v_cfg) = 0
     or erp.close_tie_check('trial_balance') is distinct from 'erp.assert_trial_balance_balances()'
     or erp.close_tie_check('inventory_valued') is distinct from 'erp.assert_inventory_reconciles()'
     or erp.close_tie_check('subledgers_reconcile') is distinct from 'erp.assert_subledger_reconciles()'
     or not erp.close_check_is_a_tie('erp.assert_trial_balance_balances()')
     or not erp.close_check_is_a_tie('erp.assert_ageing_equals_control()') then
    raise exception 'CLOVEERP_CLOSE_BODY_LOST: the replacement dropped a task or a tie the close carried'
      using hint = 'Compare the needles above with pg_get_functiondef() of the three routines.';
  end if;
end
$survived$;

-- ── The organisations already configured ─────────────────────────────────────
--
-- As 20260918400000: the manifest does not carry close_task, so an upgrade item
-- would plan for ever. The register records the version and the sweep does the
-- work once, for every organisation holding the checklist.

update erp_ref.module_installer
   set current_version = 3,
       description = 'Close tasks and the calendar. Version 2 (20260918400000) '
                     'gives the trial balance task the assertion that proves it, '
                     'and makes the tasks carrying the v1 ties unwaivable. '
                     'Version 3 (20260918500000) adds the fourth tie: the ageing '
                     'agrees with the debtors and creditors accounts.'
 where install_code = 'period-close';

-- The template, beside the subledger reconciliation it follows.
-- erp.set_close_task_tie() stamps it unwaivable as it lands.
insert into erp.close_task_template
  (tenant_id, code, name, seq, depends_on, blocking_check, status)
select t.tenant_id, 'ageing_agrees',
       'The ageing agrees with the debtors and creditors accounts', 35,
       array['subledgers_reconcile'], 'erp.assert_ageing_equals_control()', 'active'
  from erp.close_task_template t
 where t.code = 'subledgers_reconcile'
   and t.status = 'active'
on conflict (tenant_id, code) do nothing;

-- And the checklists already raised into a period that has not shut. A period
-- closed, or closed for good, is history and is left alone.
insert into erp.close_task
  (tenant_id, fiscal_period_id, code, name, seq, depends_on, blocking_check, is_waivable)
select ct.tenant_id, ct.fiscal_period_id, tt.code, tt.name, tt.seq, tt.depends_on,
       tt.blocking_check, tt.is_waivable
  from erp.close_task ct
  join erp.fiscal_period fp
    on fp.tenant_id = ct.tenant_id and fp.id = ct.fiscal_period_id
  join erp.close_task_template tt
    on tt.tenant_id = ct.tenant_id and tt.code = 'ageing_agrees' and tt.status = 'active'
 where ct.code = 'subledgers_reconcile'
   and fp.status in ('future', 'open', 'closing')
on conflict (tenant_id, fiscal_period_id, code) do nothing;

update erp.module_installation i
   set installer_version = 3,
       upgraded_at       = now(),
       updated_at        = now()
 where i.install_code = 'period-close'
   and i.installer_version < 3;

do $swept$
declare
  v_left integer;
begin
  select count(*) into v_left
    from erp.close_task_template t
   where t.code = 'subledgers_reconcile' and t.status = 'active'
     and not exists (select 1 from erp.close_task_template a
                      where a.tenant_id = t.tenant_id and a.code = 'ageing_agrees'
                        and a.status = 'active' and not a.is_waivable
                        and a.blocking_check = 'erp.assert_ageing_equals_control()');
  if v_left > 0 then
    raise exception 'CLOVEERP_AGEING_TIE_NOT_SWEPT: % organisation(s) hold the close checklist without an unwaivable ageing tie', v_left;
  end if;
end
$swept$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The suites that counted the close
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Live bodies, needles counted exactly once. erp_test.finance_depth_suite() was
-- written in 20260829300000 and patched in 20260914062000 and 20260918400000;
-- erp_test.trial_balance_tie_suite() was written in 20260918400000 and not
-- patched since. Each needle below is the text those left.

do $patch$
declare
  v_def  text := pg_get_functiondef('erp_test.finance_depth_suite()'::regprocedure);
  v_old1 text := $p$    (select count(*) from erp.close_task_template t
      where t.tenant_id = r.tenant_id and t.status='active') = 5,$p$;
  v_new1 text := $q$    (select count(*) from erp.close_task_template t
      where t.tenant_id = r.tenant_id and t.status='active') = 6,$q$;
  v_old2 text := $p$    v_n = 5
    and (select p.status::text from erp.fiscal_period p where p.id = v_period) = 'closing',
    'five tasks, four of them with a check that cannot be ticked past, and three of those a tie that is not waived at all';$p$;
  v_new2 text := $q$    v_n = 6
    and (select p.status::text from erp.fiscal_period p where p.id = v_period) = 'closing',
    'six tasks, five of them with a check that cannot be ticked past, and four of those a tie that is not waived at all — the ageing against the control accounts since 20260918500000';$q$;
  v_old3 text := $p$      where cs.check_passes is not null) = 4,
    'every task shows whether its check would pass right now, the trial balance among them since 20260918400000';$p$;
  v_new3 text := $q$      where cs.check_passes is not null) = 5,
    'every task shows whether its check would pass right now, the trial balance among them since 20260918400000 and the ageing since 20260918500000';$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1) <> 1
     or (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2) <> 1
     or (length(v_def) - length(replace(v_def, v_old3, ''))) / length(v_old3) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp_test.finance_depth_suite() does not count the close where this migration expects'
      using hint = 'Read the live body with pg_get_functiondef and write the patch against it under a new migration version.';
  end if;
  execute replace(replace(replace(v_def, v_old1, v_new1), v_old2, v_new2), v_old3, v_new3);
end
$patch$;

do $patch$
declare
  v_def  text := pg_get_functiondef('erp_test.trial_balance_tie_suite()'::regprocedure);
  v_old1 text := $p$          and v_raised = 5;$p$;
  v_new1 text := $q$          and v_raised = 6;$q$;
  v_old2 text := $p$    case_name := 'three tasks carry the four ties and are unwaivable; everything else on the close still is';
    passed := v_state is null
          and (select count(*) from erp.close_task t
                where t.fiscal_period_id = v_period and not t.is_waivable) = 3
          and (select bool_and(not t.is_waivable) from erp.close_task t
                where t.fiscal_period_id = v_period
                  and t.code in ('trial_balance', 'inventory_valued', 'subledgers_reconcile'))$p$;
  v_new2 text := $q$    case_name := 'four tasks carry the four ties and are unwaivable; everything else on the close still is';
    passed := v_state is null
          and (select count(*) from erp.close_task t
                where t.fiscal_period_id = v_period and not t.is_waivable) = 4
          and (select bool_and(not t.is_waivable) from erp.close_task t
                where t.fiscal_period_id = v_period
                  and t.code in ('trial_balance', 'inventory_valued', 'subledgers_reconcile', 'ageing_agrees'))$q$;
  v_old3 text := $p$    perform erp.complete_close_task(v_task_grni);
$p$;
  v_new3 text := $q$    perform erp.complete_close_task(v_task_grni);
    -- The ageing tie (20260918500000). Nothing in this organisation is owed, so
    -- it holds, and it is completed as a person would before closing.
    perform erp.complete_close_task((select t.id from erp.close_task t
                                      where t.fiscal_period_id = v_period and t.code = 'ageing_agrees'));
$q$;
  v_old4 text := $p$                  and d.function_name <> 'assert_whole_database_reconciles') = 10;$p$;
  v_new4 text := $q$                  and d.function_name <> 'assert_whole_database_reconciles') = 11;$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1) <> 1
     or (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2) <> 1
     or (length(v_def) - length(replace(v_def, v_old3, ''))) / length(v_old3) <> 1
     or (length(v_def) - length(replace(v_def, v_old4, ''))) / length(v_old4) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp_test.trial_balance_tie_suite() does not count the close where this migration expects'
      using hint = 'Read the live body with pg_get_functiondef and write the patch against it under a new migration version.';
  end if;
  execute replace(replace(replace(replace(v_def, v_old1, v_new1), v_old2, v_new2), v_old3, v_new3), v_old4, v_new4);
end
$patch$;

-- The patches this migration did not write are still there.
do $survived$
declare
  v_fd text := pg_get_functiondef('erp_test.finance_depth_suite()'::regprocedure);
  v_tb text := pg_get_functiondef('erp_test.trial_balance_tie_suite()'::regprocedure);
begin
  if position('perform erp_test.approve_document(v_grn, ''suite'');' in v_fd) = 0
     or position('perform erp_test.approve_document(v_po2, ''suite'');' in v_fd) = 0
     or position('the trial balance among them since 20260918400000 and the ageing since 20260918500000' in v_fd) = 0
     or position('and four of those a tie that is not waived at all' in v_fd) = 0
     or position('CLOVEERP_TRIAL_BALANCE_TIE_SUITE_SHRANK' in v_tb) = 0
     or position('t.code = ''ageing_agrees''' in v_tb) = 0
     or position('assert_whole_database_reconciles'') = 11;' in v_tb) = 0 then
    raise exception 'CLOVEERP_PATCH_LOST: a suite lost a patch it carried, or did not take this one'
      using hint = 'Compare the needles with pg_get_functiondef() of the two suites.';
  end if;
end
$survived$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The invoice and the bill are real documents, raised through the doors, and
-- their postings are written here the way the posting bridge writes them — a
-- journal naming the document and a subledger row naming the party, the
-- document and the due date — so the suite chooses the figures it reads back.
-- The bridge's own postings are proved by the demonstration month the
-- whole-database reconciliation reads. The receipt is erp.apply_cash() itself,
-- the route that names no document; the payment is written the way the payment
-- run writes one, the route that does.

create or replace function erp_test.ageing_tie_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $suite$
declare
  c_expected constant integer := 12;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_tenant uuid;
  v_entity uuid; v_entity_code text; v_ledger uuid; v_period uuid;
  v_site uuid; v_item uuid; v_ccy char(3);
  v_cust uuid; v_supp uuid;
  v_ar uuid; v_ap uuid; v_bank uuid; v_tax uuid; v_rev uuid; v_cos uuid;
  v_inv uuid; v_pinv uuid; v_draft uuid;
  v_gross bigint; v_half bigint; v_bill bigint; v_paid bigint; v_draft_gross bigint;
  v_j uuid; v_item_row uuid;
  v_tie text; v_tie2 text; v_tie3 text; v_broken text;
  v_row record; v_scr record;
  v_ar_base bigint; v_ctl bigint;
  v_rows_before integer; v_rows_after integer;
  v_raised integer;
  v_tmpl record; v_status record;
  v_task_sub uuid; v_task_age uuid;
  v_failed text; v_waive text;
  v_registered integer; v_catalogued integer; v_next text;
begin
  begin
    -- ── The fixture: the demonstration's configuration, and our own parties ──
    v_step := 'an organisation configured as the demonstration is, with the close checklist';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzage-' || v_tag, 'Ageing Tie Suite',
      'admin@zzage-' || v_tag || '.test', 'Ageing Admin');
    v_tenant := rb.tenant_id;
    update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzage-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(v_tenant, rb.admin_user_id);
    perform erp.configure_period_close();

    v_step := 'the company, its ledger, its accounts and the period';
    select l.entity_id, l.id, l.currency into v_entity, v_ledger, v_ccy
      from erp.ledger l where l.tenant_id = v_tenant and l.is_primary order by l.code limit 1;
    select e.code into v_entity_code from erp.entity e where e.id = v_entity;
    select fp.id into v_period from erp.fiscal_period fp
     where fp.tenant_id = v_tenant and fp.ledger_id = v_ledger
       and current_date between fp.starts_on and fp.ends_on;
    select s.id into v_site from erp.site s
     where s.tenant_id = v_tenant and s.entity_id = v_entity order by s.code limit 1;
    select i.id into v_item from erp.item i
     where i.tenant_id = v_tenant and i.status = 'active'::erp.record_status order by i.code limit 1;

    select a.id into strict v_ar from erp.account a
     where a.tenant_id = v_tenant and a.entity_id = v_entity and a.control_kind = 'receivable'
       and a.status = 'active' and a.is_postable order by a.code limit 1;
    select a.id into strict v_ap from erp.account a
     where a.tenant_id = v_tenant and a.entity_id = v_entity and a.control_kind = 'payable'
       and a.status = 'active' and a.is_postable order by a.code limit 1;
    select a.id into strict v_bank from erp.account a
     where a.tenant_id = v_tenant and a.entity_id = v_entity and a.control_kind = 'bank'
       and a.status = 'active' and a.is_postable order by a.code limit 1;
    select a.id into strict v_tax from erp.account a
     where a.tenant_id = v_tenant and a.entity_id = v_entity and a.control_kind = 'tax'
       and a.status = 'active' and a.is_postable order by a.code limit 1;
    select a.id into strict v_rev from erp.account a
     where a.tenant_id = v_tenant and a.entity_id = v_entity and a.code = erp.tenant_account_code('revenue');
    select a.id into strict v_cos from erp.account a
     where a.tenant_id = v_tenant and a.entity_id = v_entity and a.code = erp.tenant_account_code('cost_of_sales');

    v_step := 'a customer and a supplier of the suite''s own';
    insert into erp.party (tenant_id, code, name, status)
    values (v_tenant, 'ZZAGE-CUST', 'Ageing Suite Customer', 'active'::erp.record_status)
    returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (v_tenant, v_cust, 'customer', 'active');
    insert into erp.party (tenant_id, code, name, status)
    values (v_tenant, 'ZZAGE-SUPP', 'Ageing Suite Supplier', 'active'::erp.record_status)
    returning id into v_supp;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (v_tenant, v_supp, 'supplier', 'active');

    select coalesce(sum(l.debit_minor - l.credit_minor), 0) into v_ar_base
      from erp.journal_line l
      join erp.journal j on j.id = l.journal_id and j.status = 'posted'
     where l.tenant_id = v_tenant and l.account_id = v_ar;

    -- ── 1. An invoice in the ledger ages at what it is owed ─────────────────
    v_step := 'a sales invoice raised and posted to the debtors account';
    v_inv := erp.create_document('sales_invoice', v_entity, v_site, v_cust,
                                 current_date - 40, v_ccy, 'ZZAGE-INV', '{}'::jsonb);
    perform erp.add_document_line(v_inv, v_item, 1, 100000, 'a sale the customer will half pay');
    select dv.gross_minor::bigint into v_gross from erp.document_view dv where dv.id = v_inv;

    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, document_id, posting_date,
                             description, status, manual_reason)
    values (v_tenant, v_entity, v_ledger, 'manual', v_inv, current_date, 'ZZAGE-INV', 'draft',
            'suite: the invoice, as the bridge posts it')
    returning id into v_j;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
                                  currency, base_debit_minor, base_credit_minor, exchange_rate)
    values (v_tenant, v_j, 1, v_ar, v_gross, 0, v_ccy, v_gross, 0, 1),
           (v_tenant, v_j, 2, v_rev, 0, v_gross, v_ccy, 0, v_gross, 1);
    insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id,
                                    party_id, document_id, journal_id, currency, debit_minor, credit_minor,
                                    due_date, posting_date)
    values (v_tenant, v_entity, v_ledger, 'receivable', v_ar, v_cust, v_inv, v_j, v_ccy, v_gross, 0,
            current_date - 10, current_date);
    update erp.journal set status = 'posted', posted_at = now(),
                           posted_by = erp.current_principal_id() where id = v_j;

    v_tie := erp.assert_ageing_equals_control();
    select a.outstanding_minor, a.gross_minor, a.direction, a.bucket into v_row
      from erp.ageing a where a.tenant_id = v_tenant and a.id = v_inv;

    v_cases := v_cases + 1;
    case_name := 'an invoice in the ledger ages at what it is owed, and the ageing equals the debtors account';
    passed := v_state is null
          and v_gross > 0
          and v_row.outstanding_minor = v_gross
          and v_row.gross_minor = v_gross
          and v_row.direction = 'receivable'
          and v_row.bucket = '1-30'
          and v_tie like 'ageing: equals the debtors and creditors control accounts%';
    detail := coalesce(v_state, format('owed %s of %s, %s, %s; %s',
      v_row.outstanding_minor, v_gross, v_row.direction, v_row.bucket, v_tie), 'no answer');
    return next;

    -- ── 2. Half of it is paid ──────────────────────────────────────────────
    v_step := 'the customer pays half, through cash application';
    v_half := v_gross / 2;
    perform erp.apply_cash(v_cust, v_half, v_ccy, 'ZZAGE-RECEIPT', current_date);

    v_tie := erp.assert_ageing_equals_control();
    select a.outstanding_minor, a.gross_minor into v_row
      from erp.ageing a where a.tenant_id = v_tenant and a.id = v_inv;
    select s.total_minor, s.days_1_30, s.current_minor into v_scr
      from erp.receivables_ageing() s where s.party_id = v_cust;
    select coalesce(sum(l.debit_minor - l.credit_minor), 0) - v_ar_base into v_ctl
      from erp.journal_line l
      join erp.journal j on j.id = l.journal_id and j.status = 'posted'
     where l.tenant_id = v_tenant and l.account_id = v_ar;

    v_cases := v_cases + 1;
    case_name := 'after a part payment the report, the screen and the debtors account all say what is left, where the report said the whole invoice';
    passed := v_state is null
          and v_row.outstanding_minor = v_gross - v_half
          and v_row.gross_minor = v_gross
          and v_scr.total_minor = v_gross - v_half
          and v_scr.days_1_30 = v_gross - v_half
          and v_scr.current_minor = 0
          and v_ctl = v_gross - v_half
          and not exists (select 1 from erp.ageing a
                           where a.tenant_id = v_tenant and a.party_id = v_cust and a.id is null)
          and v_tie like 'ageing: equals%';
    detail := coalesce(v_state, format('report owes %s (face value %s), screen %s in 1-30 and %s current, debtors account moved %s; %s',
      v_row.outstanding_minor, v_row.gross_minor, v_scr.total_minor, v_scr.days_1_30,
      v_scr.current_minor, v_ctl, v_tie), 'no answer');
    return next;

    -- ── 3. A bill, part paid by a payment that names it ─────────────────────
    v_step := 'a supplier bill posted to the creditors account and part paid';
    v_pinv := erp.create_document('purchase_invoice', v_entity, v_site, v_supp,
                                  current_date - 5, v_ccy, 'ZZAGE-BILL', '{}'::jsonb);
    perform erp.add_document_line(v_pinv, v_item, 1, 30000, 'a bill paid in part');
    select dv.gross_minor::bigint into v_bill from erp.document_view dv where dv.id = v_pinv;
    v_paid := v_bill / 3;

    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, document_id, posting_date,
                             description, status, manual_reason)
    values (v_tenant, v_entity, v_ledger, 'manual', v_pinv, current_date, 'ZZAGE-BILL', 'draft',
            'suite: the bill, as the bridge posts it')
    returning id into v_j;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
                                  currency, base_debit_minor, base_credit_minor, exchange_rate)
    values (v_tenant, v_j, 1, v_cos, v_bill, 0, v_ccy, v_bill, 0, 1),
           (v_tenant, v_j, 2, v_ap, 0, v_bill, v_ccy, 0, v_bill, 1);
    insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id,
                                    party_id, document_id, journal_id, currency, debit_minor, credit_minor,
                                    due_date, posting_date)
    values (v_tenant, v_entity, v_ledger, 'payable', v_ap, v_supp, v_pinv, v_j, v_ccy, 0, v_bill,
            current_date + 25, current_date)
    returning id into v_item_row;
    update erp.journal set status = 'posted', posted_at = now(),
                           posted_by = erp.current_principal_id() where id = v_j;

    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date,
                             description, status, manual_reason)
    values (v_tenant, v_entity, v_ledger, 'manual', current_date, 'ZZAGE-PAYMENT', 'draft',
            'suite: a payment, as the payment run posts it')
    returning id into v_j;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
                                  currency, base_debit_minor, base_credit_minor, exchange_rate)
    values (v_tenant, v_j, 1, v_ap, v_paid, 0, v_ccy, v_paid, 0, 1),
           (v_tenant, v_j, 2, v_bank, 0, v_paid, v_ccy, 0, v_paid, 1);
    insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id,
                                    party_id, document_id, journal_id, currency, debit_minor, credit_minor,
                                    posting_date)
    values (v_tenant, v_entity, v_ledger, 'payable', v_ap, v_supp, v_pinv, v_j, v_ccy, v_paid, 0, current_date),
           (v_tenant, v_entity, v_ledger, 'bank', v_bank, null, null, v_j, v_ccy, 0, v_paid, current_date);
    update erp.subledger_item set settled_minor = coalesce(settled_minor, 0) + v_paid, updated_at = now()
     where id = v_item_row;
    update erp.journal set status = 'posted', posted_at = now(),
                           posted_by = erp.current_principal_id() where id = v_j;

    v_tie := erp.assert_ageing_equals_control();
    select a.outstanding_minor, a.direction, a.bucket into v_row
      from erp.ageing a where a.tenant_id = v_tenant and a.id = v_pinv;
    select s.total_minor, s.not_due_minor into v_scr
      from erp.payables_ageing() s where s.party_id = v_supp;

    v_cases := v_cases + 1;
    case_name := 'a bill paid in part by a payment that names it is owed once, not less the payment twice, and the creditors account agrees';
    passed := v_state is null
          and v_row.outstanding_minor = v_bill - v_paid
          and v_row.direction = 'payable'
          and v_row.bucket = 'current'
          and v_scr.total_minor = v_bill - v_paid
          and v_scr.not_due_minor = v_bill - v_paid
          and v_tie like 'ageing: equals%';
    detail := coalesce(v_state, format('bill %s, paid %s: report owes %s (%s, %s), screen %s; %s',
      v_bill, v_paid, v_row.outstanding_minor, v_row.direction, v_row.bucket, v_scr.total_minor, v_tie),
      'no answer');
    return next;

    -- ── 4. A receivable posted with no customer ────────────────────────────
    v_step := 'money on the debtors account that names no customer';
    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date,
                             description, status, manual_reason)
    values (v_tenant, v_entity, v_ledger, 'manual', current_date - 3, 'ZZAGE-NOBODY', 'draft',
            'suite: a receipt nobody could name')
    returning id into v_j;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
                                  currency, base_debit_minor, base_credit_minor, exchange_rate)
    values (v_tenant, v_j, 1, v_bank, 700, 0, v_ccy, 700, 0, 1),
           (v_tenant, v_j, 2, v_ar, 0, 700, v_ccy, 0, 700, 1);
    insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id,
                                    party_id, document_id, journal_id, currency, debit_minor, credit_minor,
                                    posting_date)
    values (v_tenant, v_entity, v_ledger, 'receivable', v_ar, null, null, v_j, v_ccy, 0, 700, current_date - 3),
           (v_tenant, v_entity, v_ledger, 'bank', v_bank, null, null, v_j, v_ccy, 700, 0, current_date - 3);
    update erp.journal set status = 'posted', posted_at = now(),
                           posted_by = erp.current_principal_id() where id = v_j;

    v_tie := erp.assert_ageing_equals_control();
    select a.outstanding_minor, a.party_name, a.direction, a.bucket into v_row
      from erp.ageing a where a.tenant_id = v_tenant and a.party_id is null and a.id is null;
    select s.total_minor, s.party_name into v_scr
      from erp.receivables_ageing() s where s.party_id is null;

    v_cases := v_cases + 1;
    case_name := 'a receivable posted with no customer is on the report and the screen as unallocated, where the screen used to drop it, and the tie holds';
    passed := v_state is null
          and v_row.outstanding_minor = -700
          and v_row.party_name = 'Unallocated'
          and v_row.direction = 'receivable'
          and v_row.bucket = '1-30'
          and v_scr.total_minor = -700
          and v_scr.party_name = 'Unallocated'
          and v_tie like 'ageing: equals%';
    detail := coalesce(v_state, format('report %s as %s (%s, %s); screen %s as %s; %s',
      v_row.outstanding_minor, v_row.party_name, v_row.direction, v_row.bucket,
      v_scr.total_minor, v_scr.party_name, v_tie), 'no answer');
    return next;

    -- ── 5. Tax detail names no party by design, and is not an ageing ────────
    v_step := 'tax posted to the tax control account with no party';
    select count(*) into v_rows_before from erp.ageing a where a.tenant_id = v_tenant;
    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date,
                             description, status, manual_reason)
    values (v_tenant, v_entity, v_ledger, 'manual', current_date, 'ZZAGE-TAX', 'draft',
            'suite: tax, which names nobody')
    returning id into v_j;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
                                  currency, base_debit_minor, base_credit_minor, exchange_rate)
    values (v_tenant, v_j, 1, v_cos, 300, 0, v_ccy, 300, 0, 1),
           (v_tenant, v_j, 2, v_tax, 0, 300, v_ccy, 0, 300, 1);
    insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id,
                                    party_id, document_id, journal_id, currency, debit_minor, credit_minor,
                                    posting_date)
    values (v_tenant, v_entity, v_ledger, 'tax', v_tax, null, null, v_j, v_ccy, 0, 300, current_date);
    update erp.journal set status = 'posted', posted_at = now(),
                           posted_by = erp.current_principal_id() where id = v_j;

    v_tie := erp.assert_ageing_equals_control();
    v_tie2 := erp.assert_subledger_reconciles();
    select count(*) into v_rows_after from erp.ageing a where a.tenant_id = v_tenant;

    v_cases := v_cases + 1;
    case_name := 'tax detail that names no party by design is not on the ageing, and neither the tie nor the subledger reconciliation minds it';
    passed := v_state is null
          and v_rows_after = v_rows_before
          and v_tie like 'ageing: equals%'
          and v_tie2 like 'subledger:%';
    detail := coalesce(v_state, format('%s ageing row(s) before and %s after; %s; %s',
      v_rows_before, v_rows_after, v_tie, v_tie2), 'no answer');
    return next;

    -- ── 6. An invoice raised and not yet posted ─────────────────────────────
    v_step := 'a second invoice raised and not posted';
    v_draft := erp.create_document('sales_invoice', v_entity, v_site, v_cust,
                                   current_date, v_ccy, 'ZZAGE-DRAFT', '{}'::jsonb);
    perform erp.add_document_line(v_draft, v_item, 1, 25000, 'not in the ledger yet');
    select dv.gross_minor::bigint into v_draft_gross from erp.document_view dv where dv.id = v_draft;

    v_tie := erp.assert_ageing_equals_control();
    select a.outstanding_minor, a.gross_minor, a.direction into v_row
      from erp.ageing a where a.tenant_id = v_tenant and a.id = v_draft;
    select s.total_minor into v_scr from erp.receivables_ageing() s where s.party_id = v_cust;

    v_cases := v_cases + 1;
    case_name := 'an invoice raised and not posted is listed at its face value owing nothing on the ledger, and moves neither the screen nor the tie';
    passed := v_state is null
          and v_row.outstanding_minor is null
          and v_row.gross_minor = v_draft_gross
          and v_row.direction = 'receivable'
          and v_scr.total_minor = v_gross - v_half
          and v_tie like 'ageing: equals%';
    detail := coalesce(v_state, format('listed at %s owing %s (%s); the customer still owes %s; %s',
      v_row.gross_minor, coalesce(v_row.outstanding_minor::text, 'nothing on the ledger'),
      v_row.direction, v_scr.total_minor, v_tie), 'no answer');
    return next;

    -- ── 7. The close carries the tie ────────────────────────────────────────
    v_step := 'the close checklist raised on the period';
    v_raised := erp.open_period_close(v_period);
    select ct.code, ct.blocking_check, ct.is_waivable, ct.depends_on into v_tmpl
      from erp.close_task_template ct
     where ct.tenant_id = v_tenant and ct.code = 'ageing_agrees';
    select t.id into v_task_sub from erp.close_task t
     where t.fiscal_period_id = v_period and t.code = 'subledgers_reconcile';
    select t.id into v_task_age from erp.close_task t
     where t.fiscal_period_id = v_period and t.code = 'ageing_agrees';
    perform erp.complete_close_task(v_task_sub);

    v_cases := v_cases + 1;
    case_name := 'the close the product ships carries the ageing tie, unwaivably, as the fourth of four tied tasks';
    passed := v_state is null
          and v_raised = 6
          and v_tmpl.blocking_check = 'erp.assert_ageing_equals_control()'
          and v_tmpl.is_waivable is false
          and v_tmpl.depends_on = array['subledgers_reconcile']
          and v_task_age is not null
          and (select count(*) from erp.close_task t
                where t.fiscal_period_id = v_period and not t.is_waivable) = 4
          and (select t.status from erp.close_task t where t.id = v_task_sub) = 'complete';
    detail := coalesce(v_state, format('%s tasks raised; template %s: %s, waivable %s, after %s; %s unwaivable',
      v_raised, v_tmpl.code, v_tmpl.blocking_check, v_tmpl.is_waivable,
      array_to_string(v_tmpl.depends_on, ', '),
      (select count(*) from erp.close_task t where t.fiscal_period_id = v_period and not t.is_waivable)),
      'no answer');
    return next;

    -- ── 8. The falsification ───────────────────────────────────────────────
    --
    -- Money on both control accounts that no invoice, bill or payment put
    -- there: the ledger moves and the ageing cannot see it.
    v_step := 'postings on both control accounts with no detail behind them';
    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date,
                             description, status, manual_reason)
    values (v_tenant, v_entity, v_ledger, 'manual', current_date, 'ZZAGE-BREAK', 'draft',
            'suite: the falsification')
    returning id into v_j;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
                                  currency, base_debit_minor, base_credit_minor, exchange_rate)
    values (v_tenant, v_j, 1, v_ar, 1234, 0, v_ccy, 1234, 0, 1),
           (v_tenant, v_j, 2, v_rev, 0, 1234, v_ccy, 0, 1234, 1),
           (v_tenant, v_j, 3, v_cos, 555, 0, v_ccy, 555, 0, 1),
           (v_tenant, v_j, 4, v_ap, 0, 555, v_ccy, 0, 555, 1);
    update erp.journal set status = 'posted', posted_at = now(),
                           posted_by = erp.current_principal_id() where id = v_j;

    begin
      v_broken := 'passed: ' || erp.assert_ageing_equals_control();
    exception when others then
      v_broken := sqlerrm;
    end;

    v_cases := v_cases + 1;
    case_name := 'money on the debtors and creditors accounts that the ageing cannot see is refused, naming the company, both sides and the difference';
    passed := v_state is null
          and v_broken like 'CLOVEERP_AGEING_DOES_NOT_EQUAL_CONTROL:%2 place(s)%'
          and v_broken like '%' || v_entity_code || ', receivable (' || v_ccy || ')%out by -1234%'
          and v_broken like '%' || v_entity_code || ', payable (' || v_ccy || ')%out by -555%';
    detail := coalesce(v_state, left(v_broken, 400), 'no answer');
    return next;

    -- ── 9. And the close will not let it through ────────────────────────────
    v_step := 'the ageing tie ticked and waived while it is broken';
    begin
      perform erp.complete_close_task(v_task_age);
      v_failed := 'the tie was ticked over a difference';
    exception when others then
      v_failed := sqlerrm;
    end;
    begin
      perform erp.complete_close_task(v_task_age, 'Agreed with the bank statement by hand');
      v_waive := 'the waiver went through';
    exception when others then
      v_waive := sqlerrm;
    end;
    select cs.is_waivable, cs.check_passes into v_status
      from erp.close_status(v_period) cs where cs.code = 'ageing_agrees';

    v_cases := v_cases + 1;
    case_name := 'while the ageing and the ledger disagree the tie will not be ticked or waived, and the close screen says so first';
    passed := v_state is null
          and v_failed like 'CLOVEERP_CLOSE_CHECK_FAILED: erp.assert_ageing_equals_control()%CLOVEERP_AGEING_DOES_NOT_EQUAL_CONTROL%'
          and v_waive like 'CLOVEERP_CLOSE_TIE_NOT_WAIVABLE:%'
          and v_status.is_waivable is false
          and v_status.check_passes is false
          and (select t.status from erp.close_task t where t.id = v_task_age) = 'open';
    detail := coalesce(v_state, left(format('tick: %s; waive: %s; screen: waivable %s, passes %s',
      left(v_failed, 120), left(v_waive, 80), v_status.is_waivable, v_status.check_passes), 400), 'no answer');
    return next;

    -- ── 10. The falsification undone ───────────────────────────────────────
    v_step := 'the correction posted and the tie completed';
    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date,
                             description, status, manual_reason)
    values (v_tenant, v_entity, v_ledger, 'manual', current_date, 'ZZAGE-CORRECT', 'draft',
            'suite: reversing the falsification')
    returning id into v_j;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
                                  currency, base_debit_minor, base_credit_minor, exchange_rate)
    values (v_tenant, v_j, 1, v_rev, 1234, 0, v_ccy, 1234, 0, 1),
           (v_tenant, v_j, 2, v_ar, 0, 1234, v_ccy, 0, 1234, 1),
           (v_tenant, v_j, 3, v_ap, 555, 0, v_ccy, 555, 0, 1),
           (v_tenant, v_j, 4, v_cos, 0, 555, v_ccy, 0, 555, 1);
    update erp.journal set status = 'posted', posted_at = now(),
                           posted_by = erp.current_principal_id() where id = v_j;

    v_tie3 := erp.assert_ageing_equals_control();
    perform erp.complete_close_task(v_task_age);

    v_cases := v_cases + 1;
    case_name := 'once the difference is reversed the ageing equals the ledger again and the tie completes';
    passed := v_state is null
          and v_tie3 like 'ageing: equals%'
          and (select t.status from erp.close_task t where t.id = v_task_age) = 'complete';
    detail := coalesce(v_state, format('%s; task %s', v_tie3,
      (select t.status from erp.close_task t where t.id = v_task_age)), 'no answer');
    return next;

    -- ── 11. The registers ──────────────────────────────────────────────────
    v_step := 'the registers that drive it';
    select count(*) into v_registered
      from erp_meta.diagnostic_check d
     where d.code = 'ageing_equals_control' and d.kind = 'assertion' and d.scope = 'tenant'
       and d.schema_name = 'erp' and d.function_name = 'assert_ageing_equals_control'
       and d.runs_in_ci;
    select count(*) into v_catalogued
      from erp.ci_check_catalogue() c
     where c.qualified_name = 'erp.assert_ageing_equals_control';
    select f.next_action into v_next from erp_ref.refusal f
     where f.code = 'CLOVEERP_AGEING_DOES_NOT_EQUAL_CONTROL';

    v_cases := v_cases + 1;
    case_name := 'the register drives the tie for every organisation, the structural phase does not run it without one, and its refusal says what to do';
    passed := v_state is null and v_registered = 1 and v_catalogued = 0
          and (select count(*) from erp_meta.diagnostic_check d
                where d.kind = 'assertion' and d.scope = 'tenant'
                  and d.function_name <> 'assert_whole_database_reconciles') = 11
          and v_next like '%reverse it%'
          and exists (select 1 from erp_ref.resource r
                       where r.locale = 'en'
                         and r.key = erp_ref.refusal_key('CLOVEERP_AGEING_DOES_NOT_EQUAL_CONTROL', 'next_action'));
    detail := coalesce(v_state, format('%s register row, %s catalogue rows, %s tenant assertions in the loop; next action: %s',
      v_registered, v_catalogued,
      (select count(*) from erp_meta.diagnostic_check d
        where d.kind = 'assertion' and d.scope = 'tenant'
          and d.function_name <> 'assert_whole_database_reconciles'),
      left(coalesce(v_next, 'nothing registered'), 80)), 'no answer');
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code = 'zzage-' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1);
  detail := coalesce(v_state, 'zzage rolled back with its parties, documents, journals and close');
  return next;

  -- The count guard says what stopped the fixture, so the message this suite
  -- caught — and the step that produced it — reaches the build log.
  if v_cases <> c_expected then
    raise exception 'CLOVEERP_AGEING_TIE_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$suite$;

revoke all on function erp_test.ageing_tie_suite() from public, anon;

comment on function erp_test.ageing_tie_suite() is
  'The ageing tie, proved and falsified. An invoice ages at its value and the '
  'report equals the debtors account; half paid through cash application, the '
  'report, the screen and the ledger all say what is left; a bill part paid by a '
  'payment that names it is owed once; a receivable with no customer is on both '
  'as Unallocated; tax detail with no party is not an ageing and breaks nothing; '
  'an unposted invoice is listed owing nothing on the ledger. Then money on both '
  'control accounts with no detail is refused by name, the close will neither '
  'tick nor waive the tie, and the reversal makes it true again. Rolls back '
  'everything it made.';

create or replace function erp_test.assert_ageing_tie_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $wrap$
declare
  c_expected constant integer := 12;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _ageing_tie on commit drop as
    select * from erp_test.ageing_tie_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _ageing_tie;
  drop table _ageing_tie;
  if v_fail > 0 then
    raise exception E'CLOVEERP_AGEING_TIE_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_AGEING_TIE_SUITE_SHRANK: % case(s), expected %', v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('an ageing agrees with the ledger: %s/%s cases passed', v_all, v_all);
end;
$wrap$;

revoke all on function erp_test.assert_ageing_tie_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. The generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_no_caller_reachable_internals();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_invoker_doors_executable();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_session_context_hygiene();
select erp.assert_governed_views_are_safe();
select erp.assert_pack_report_versions_sound();
select erp.assert_part5_coverage();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
select erp.assert_finance_depth_sane();

select erp_test.assert_ageing_tie_suite();
-- The two suites whose counts this migration restated, run here so each patch
-- and the proof that it landed are in one transaction.
select erp_test.assert_trial_balance_tie_suite();
select erp_test.assert_finance_depth_suite();
-- The one other reader of erp.ageing, which reads direction from a document
-- that is raised and not posted.
select erp_test.assert_document_side_suite();
-- And every organisation this database holds, with the fourth tie in the loop:
-- if a posted month does not tie, this migration does not land and the build
-- log says by how much.
select erp.assert_whole_database_reconciles();
