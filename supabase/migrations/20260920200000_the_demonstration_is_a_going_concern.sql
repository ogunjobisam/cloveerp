set lock_timeout = '30s';

-- =============================================================================
-- 20260920200000  The demonstration is a going concern
-- -----------------------------------------------------------------------------
-- Walked live on 18 September 2026, the demonstration organisation reads as a
-- company that stopped trading in the spring and never collected, never paid
-- and never closed a month. /finance says Receivables 195,274 and Overdue 60+
-- 195,274 — the same number to the penny — and Open periods 96 of 96 in the
-- calendar. /sales says 12 customers in dunning, 12 of them blocking trading.
-- /procurement says Received not invoiced 83, oldest 379 days, against 1,850
-- of trade payables on the balance sheet.
--
-- ── WHAT IS ACTUALLY WRONG ───────────────────────────────────────────────────
--
-- Not what it looks like. The books are sound: the trial balance balances, the
-- stock ledger agrees with the valuation, the subledgers agree with their
-- control accounts and the ageing agrees with the debtors account. All five of
-- those held in 109 ms when this was written. Nor is the history a single stale
-- month: erp.seed_demo_history() built 232 days, 1 September 2025 to 20 April
-- 2026, and it collected as it went — 427,242.86 of customer cash across 340
-- bank rows, with the last receipt on 20 May 2026. On the day it stopped, the
-- ageing was healthy: two December invoices open, five January, and the rest of
-- February, March and April still inside their terms.
--
-- The defect is that it stopped. The builder was last run on 14 September 2026
-- for a range ending five months before that day, and a company that has not
-- raised an invoice since April has nothing in its current bucket, so every
-- penny it is owed has aged into 90+. Settling those invoices with cash dated
-- today would empty the ageing rather than repair it: nothing recent would be
-- left to be owed, and "Receivables 0" is a worse demonstration than "all of it
-- overdue". Re-dating the history is not on the table and should not be — a
-- posted journal says when it was posted.
--
-- So the repair is the one the product already knows how to do: keep trading.
-- erp.seed_demo_history() applies cash to the oldest open item of the customer
-- it comes from, so five months of new trading collect the February-to-April
-- backlog first and leave the newest invoices owing. The tail that results is
-- the builder's own realistic tail, not one this migration invented.
--
-- ── 1. TRADE FORWARD TO THE DAY THIS RUNS ────────────────────────────────────
--
-- From the day after the last day the builder built, to the day this migration
-- applies, five days at a call, following next_from until the builder says it
-- is done — the driver supabase/ci/seed_demo.sql uses. The builder is additive
-- (there is no delete, truncate or drop in it), idempotent by document
-- reference (a day whose DEMO- prefix is already present is skipped and
-- counted), sizes every block off the stock that is actually on the shelf, and
-- clamps p_to to current_date, so it cannot post into the future.
--
-- Cost: the build seeds 30 days in 13 s on a GitHub runner, so the ~150 days
-- this has to catch up are one to three minutes, once, on the deploy that
-- carries this file. It adds no per-row work to erp.platform_assurance(): all
-- 14 of the checks that cost more than 200 ms there are platform-scoped
-- schema introspection, and the five tenant-scoped ties cost 109 ms over the
-- whole demonstration.
--
-- ── 2. THE SUPPLIER BILLS THE BUILDER NEVER RAISED ───────────────────────────
--
-- 549,657.70 of goods received not invoiced against 1,850 of trade payables is
-- the most conspicuous number on the balance sheet, and it has a cause: the
-- builder only learned to bill a supplier on 17 September (20260918600000),
-- three days after this demonstration's history was built. Every receipt it
-- ever made is still sitting in the accrual. Worse, the Thursday block it
-- gained takes the NEWEST unbilled receipt, so trading forward alone would
-- never reach the oldest and "oldest 379 days" would stay on the screen.
--
-- So the backlog is billed through erp.bill_from_receipt(), oldest first, on
-- the same predicate the builder uses to decide a receipt is billable: posted,
-- received against an order line, nothing invoiced against those lines yet,
-- and nothing sent back on a supplier credit note. The bill is dated the day
-- this runs and due thirty days after — a bill cannot be backdated any more
-- than a journal can. erp.bill_from_receipt() invoices at the agreed price, so
-- the accrual clears to the penny and no price variance is invented.
--
-- The bills are not then paid. erp.approve_payment_run() refuses the hand that
-- proposed the run (CLOVEERP_SEGREGATION_OF_DUTIES), and the demonstration has
-- exactly one active person, so there is no second pair of eyes to approve
-- one. That is the control working. It does mean the demonstration cannot
-- show a payment run until it has a second person with finance.approve_payment
-- — worth fixing, and not by this file.
--
-- ── 3. THE MONTHS THAT WERE NEVER CLOSED ─────────────────────────────────────
--
-- No organisation on this database has ever closed a period, and none of them
-- has the Period close module: erp.ensure_demo_configuration() installs six
-- modules and this is not one of them, which is why supabase/ci/close_month.sh
-- has to install it before it can close the month the build seeds. So this
-- installs it the way /administration/configuration does, raises the checklist
-- onto every period that ended before the month this runs in, completes every
-- task in its dependency order WITH NO WAIVER REASON, and closes.
--
-- No waiver is the point. Four of the six tasks are unwaivable ties and each
-- one runs its check inside erp.complete_close_task(), where it cannot be
-- ticked past, so every month either passes on the demonstration's own figures
-- or says which figure it failed on. Both ledgers, because a period is a
-- period; 64 of them at ~110 ms of assertions each.
--
-- ── WHY A REFUSAL HERE WARNS AND DOES NOT FAIL ───────────────────────────────
--
-- Every block below is wrapped so that a refusal is reported in plain words,
-- naming the organisation, the period or the receipt and the reason, and the
-- work of that block rolls back to where it started. None of this is an
-- invariant of the product: it is hygiene on one demonstration organisation's
-- data. A red deploy blocks every other branch, and blocking the release of a
-- feature because a demonstration month would not close would be the wrong
-- trade every time. What must not happen is a refusal nobody sees, so nothing
-- is caught silently — each one is raised as a warning carrying the database's
-- own message, and each block ends by asserting the ties itself, so a block
-- that would leave the books disagreeing takes none of its own work with it.
--
-- ── DEMONSTRATION ORGANISATIONS ONLY ─────────────────────────────────────────
--
-- The loop is over erp.tenant where the code begins 'demo-', which is the
-- shape erp.seed_demo() gives one and the shape every other demonstration
-- migration matches on. Nothing falls back to "the only organisation" or "the
-- first organisation": on a database where no code begins 'demo-' — which is
-- every CI build, because supabase/ci/seed_demo.sql creates ci-demo AFTER the
-- migrations have applied — each block says it found none and does nothing.
-- A demonstration whose environment has been made live is skipped as well;
-- erp.seed_demo_history() refuses that case itself and the other two blocks
-- have no business in a live ledger either. Clove Foods and the platform
-- organisation are neither named nor matched.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. Trade forward to the day this runs
-- ═════════════════════════════════════════════════════════════════════════════

do $forward$
declare
  -- What the three blocks below need of the person they act as. A
  -- demonstration whose administrator does not hold all of these is left
  -- alone rather than acted on by the build role, which holds nothing and
  -- would prove nothing.
  v_needs  constant text[] := array[
    'master_data.write', 'administration.configure', 'administration.promote',
    'finance.post', 'finance.close_period', 'procurement.match'];
  t        record;
  v_admin  uuid;
  v_last   date;
  v_cursor date;
  v_res    jsonb;
  v_built  integer;
  v_calls  integer;
  v_orgs   integer := 0;
begin
  for t in select tn.id, tn.code from erp.tenant tn
            where tn.code like 'demo-%'
              and tn.status = 'active'::erp.tenant_status
            order by tn.code
  loop
    begin
      select u.auth_user_id into v_admin
        from erp.app_user u
       where u.tenant_id = t.id
         and u.kind = 'person'::erp.principal_kind
         and u.status = 'active'::erp.principal_status
         and u.auth_user_id is not null
         and (select count(distinct rp.permission_code)
                from erp.user_role ur
                join erp.role r
                  on r.tenant_id = ur.tenant_id and r.id = ur.role_id
                 and r.status = 'active'::erp.record_status
                join erp.role_permission rp
                  on rp.tenant_id = ur.tenant_id and rp.role_id = ur.role_id
               where ur.tenant_id = u.tenant_id
                 and ur.app_user_id = u.id
                 and (ur.valid_from is null or ur.valid_from <= current_date)
                 and (ur.valid_to is null or ur.valid_to >= current_date)
                 and rp.permission_code = any (v_needs)) = array_length(v_needs, 1)
       order by u.created_at, u.id
       limit 1;

      if v_admin is null then
        raise warning 'demonstration %: nobody signed in there holds all of %, so its trading was left where it was',
          t.code, array_to_string(v_needs, ', ');
        continue;
      end if;

      -- As that administrator, in that organisation, transaction-local, the
      -- way supabase/ci/close_month.sh and supabase/ci/seed_demo.sql do it.
      perform set_config('request.jwt.claims',
                         json_build_object('sub', v_admin)::text, true);

      -- The context that administrator actually resolves to is the one this
      -- writes in. Somebody who belongs to two organisations would otherwise
      -- carry this work into whichever one the database picked, and a
      -- demonstration repair has no business anywhere it was not aimed.
      if erp.current_tenant_id() is distinct from t.id then
        raise warning 'demonstration %: signing in as its administrator resolves to another organisation, so nothing was done there', t.code;
        continue;
      end if;

      if erp.environment_is_live() then
        raise warning 'demonstration %: its environment says live, so no history was written into it', t.code;
        continue;
      end if;

      -- The last day the builder built, read off the reference it stamps
      -- rather than off a document date, because that is the key it skips a
      -- day by.
      select max(to_date(substring(d.their_reference from 6 for 8), 'YYYYMMDD'))
        into v_last
        from erp.document d
       where d.tenant_id = t.id
         and d.their_reference ~ '^DEMO-[0-9]{8}-';

      if v_last is null then
        raise warning 'demonstration %: it has no history the builder made, so there is no day to carry on from', t.code;
        continue;
      end if;

      v_cursor := v_last + 1;
      v_built  := 0;
      v_calls  := 0;

      while v_cursor <= current_date loop
        v_res := erp.seed_demo_history(v_cursor, null, 1);
        v_built := v_built + coalesce((v_res ->> 'built')::integer, 0);
        v_calls := v_calls + 1;
        exit when coalesce((v_res ->> 'done')::boolean, true);
        v_cursor := (v_res ->> 'next_from')::date;
        -- A call always advances, so this cannot spin; it is here because a
        -- loop that drives a routine on the routine's own answer should not be
        -- able to run a deploy out of its hour if that ever stops being true.
        exit when v_calls > 500;
      end loop;

      -- The books after the catching up, or none of it.
      perform erp.assert_stock_reconciles();
      perform erp.assert_inventory_reconciles();
      perform erp.assert_subledger_reconciles();
      perform erp.assert_ageing_equals_control();
      perform erp.assert_trial_balance_balances();

      v_orgs := v_orgs + 1;
      raise notice 'demonstration %: traded % to %, % document(s) in % call(s)',
        t.code, v_last + 1, current_date, v_built, v_calls;

    exception when others then
      raise warning 'demonstration %: it was left trading up to % because carrying on refused — %',
        t.code, coalesce(v_last::text, 'wherever it was'), sqlerrm;
    end;
  end loop;

  if v_orgs = 0 then
    raise notice 'no demonstration organisation was carried forward';
  end if;
end
$forward$;

select set_config('request.jwt.claims', '', true);

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The supplier bills the builder never raised
-- ═════════════════════════════════════════════════════════════════════════════

do $bills$
declare
  v_needs  constant text[] := array[
    'master_data.write', 'administration.configure', 'administration.promote',
    'finance.post', 'finance.close_period', 'procurement.match'];
  t        record;
  g        record;
  v_admin  uuid;
  v_billed integer;
  v_left   integer;
begin
  for t in select tn.id, tn.code from erp.tenant tn
            where tn.code like 'demo-%'
              and tn.status = 'active'::erp.tenant_status
            order by tn.code
  loop
    begin
      select u.auth_user_id into v_admin
        from erp.app_user u
       where u.tenant_id = t.id
         and u.kind = 'person'::erp.principal_kind
         and u.status = 'active'::erp.principal_status
         and u.auth_user_id is not null
         and (select count(distinct rp.permission_code)
                from erp.user_role ur
                join erp.role r
                  on r.tenant_id = ur.tenant_id and r.id = ur.role_id
                 and r.status = 'active'::erp.record_status
                join erp.role_permission rp
                  on rp.tenant_id = ur.tenant_id and rp.role_id = ur.role_id
               where ur.tenant_id = u.tenant_id
                 and ur.app_user_id = u.id
                 and (ur.valid_from is null or ur.valid_from <= current_date)
                 and (ur.valid_to is null or ur.valid_to >= current_date)
                 and rp.permission_code = any (v_needs)) = array_length(v_needs, 1)
       order by u.created_at, u.id
       limit 1;

      if v_admin is null then
        continue;   -- block 1 has already said so about this organisation
      end if;

      perform set_config('request.jwt.claims',
                         json_build_object('sub', v_admin)::text, true);

      -- The context that administrator actually resolves to is the one this
      -- writes in. Somebody who belongs to two organisations would otherwise
      -- carry this work into whichever one the database picked, and a
      -- demonstration repair has no business anywhere it was not aimed.
      if erp.current_tenant_id() is distinct from t.id then
        raise warning 'demonstration %: signing in as its administrator resolves to another organisation, so nothing was done there', t.code;
        continue;
      end if;

      if erp.environment_is_live() then
        continue;
      end if;

      v_billed := 0;
      v_left   := 0;

      -- Billable on the builder's own terms, oldest first: it is the age of
      -- the accrual that reads badly, and the builder's Thursday takes the
      -- newest, so the oldest is exactly what it would never reach.
      for g in
        select d.id, d.document_number, d.document_date
          from erp.document d
          join erp.document_type dt
            on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
         where d.tenant_id = t.id
           and dt.code = 'goods_receipt'
           and not d.is_cancelled
           and erp.object_current_state('document', d.id) = 'posted'
           and exists (select 1 from erp.document_relation fr
                        where fr.tenant_id = d.tenant_id
                          and fr.from_document_id = d.id
                          and fr.relation_kind = 'fulfils'
                          and fr.to_line_id is not null)
           -- Nothing billed against the order lines it arrived against, so the
           -- accrual it raised is the whole of what this bill clears.
           and not exists (select 1 from erp.document_relation fr
                             join erp.document_line ol
                               on ol.tenant_id = fr.tenant_id and ol.id = fr.to_line_id
                            where fr.tenant_id = d.tenant_id
                              and fr.from_document_id = d.id
                              and fr.relation_kind = 'fulfils'
                              and coalesce(ol.quantity_invoiced, 0) > 0)
           -- Nothing on its way back to the supplier: billing for goods that
           -- were returned is how a demonstration acquires a credit balance
           -- nobody can explain.
           and not exists (select 1 from erp.document_line gl
                             join erp.document_relation rr
                               on rr.tenant_id = gl.tenant_id
                              and rr.to_line_id = gl.id
                              and rr.relation_kind = 'returns'
                            where gl.tenant_id = d.tenant_id
                              and gl.document_id = d.id)
         order by d.document_date, d.document_number
      loop
        begin
          perform erp.bill_from_receipt(
                    g.id, 'INV/' || g.document_number, current_date,
                    current_date + 30, true);
          v_billed := v_billed + 1;
        exception when others then
          v_left := v_left + 1;
          raise warning 'demonstration %: % of % is still waiting for its bill — %',
            t.code, g.document_number, g.document_date, sqlerrm;
        end;
      end loop;

      -- The accrual has moved to the creditors, or none of it has.
      perform erp.assert_subledger_reconciles();
      perform erp.assert_ageing_equals_control();
      perform erp.assert_trial_balance_balances();

      if v_billed > 0 or v_left > 0 then
        raise notice 'demonstration %: % supplier bill(s) raised against goods already received, % receipt(s) left unbilled',
          t.code, v_billed, v_left;
      end if;

    exception when others then
      raise warning 'demonstration %: its goods received not invoiced were left as they were because billing refused — %',
        t.code, sqlerrm;
    end;
  end loop;
end
$bills$;

select set_config('request.jwt.claims', '', true);

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The months that were never closed
-- ═════════════════════════════════════════════════════════════════════════════

do $close$
declare
  v_needs  constant text[] := array[
    'master_data.write', 'administration.configure', 'administration.promote',
    'finance.post', 'finance.close_period', 'procurement.match'];
  t        record;
  p        record;
  k        record;
  v_admin  uuid;
  v_closed integer;
  v_stuck  integer;
begin
  for t in select tn.id, tn.code from erp.tenant tn
            where tn.code like 'demo-%'
              and tn.status = 'active'::erp.tenant_status
            order by tn.code
  loop
    begin
      select u.auth_user_id into v_admin
        from erp.app_user u
       where u.tenant_id = t.id
         and u.kind = 'person'::erp.principal_kind
         and u.status = 'active'::erp.principal_status
         and u.auth_user_id is not null
         and (select count(distinct rp.permission_code)
                from erp.user_role ur
                join erp.role r
                  on r.tenant_id = ur.tenant_id and r.id = ur.role_id
                 and r.status = 'active'::erp.record_status
                join erp.role_permission rp
                  on rp.tenant_id = ur.tenant_id and rp.role_id = ur.role_id
               where ur.tenant_id = u.tenant_id
                 and ur.app_user_id = u.id
                 and (ur.valid_from is null or ur.valid_from <= current_date)
                 and (ur.valid_to is null or ur.valid_to >= current_date)
                 and rp.permission_code = any (v_needs)) = array_length(v_needs, 1)
       order by u.created_at, u.id
       limit 1;

      if v_admin is null then
        continue;
      end if;

      perform set_config('request.jwt.claims',
                         json_build_object('sub', v_admin)::text, true);

      -- The context that administrator actually resolves to is the one this
      -- writes in. Somebody who belongs to two organisations would otherwise
      -- carry this work into whichever one the database picked, and a
      -- demonstration repair has no business anywhere it was not aimed.
      if erp.current_tenant_id() is distinct from t.id then
        raise warning 'demonstration %: signing in as its administrator resolves to another organisation, so nothing was done there', t.code;
        continue;
      end if;

      if erp.environment_is_live() then
        continue;
      end if;

      -- The checklist the organisation has never installed, installed the way
      -- /administration/configuration installs it.
      if not exists (select 1 from erp.change_set c
                      where c.tenant_id = t.id and c.code = 'period-close') then
        perform erp.configure_period_close();
      end if;

      v_closed := 0;
      v_stuck  := 0;

      -- Every period that ended before the month this runs in. The current
      -- month stays open, because today's cash and today's bills are posted
      -- into it.
      for p in select fp.id, fp.code, l.code as ledger
                 from erp.fiscal_period fp
                 join erp.ledger l
                   on l.tenant_id = fp.tenant_id and l.id = fp.ledger_id
                where fp.tenant_id = t.id
                  and fp.status = 'open'::erp.period_status
                  and fp.ends_on < date_trunc('month', current_date)::date
                order by fp.ends_on, l.code
      loop
        begin
          -- erp.open_period_close() refuses a period whose tasks are already
          -- raised, because its insert conflicts away to nothing and it reads
          -- that as an organisation with no template. Raise them once.
          if not exists (select 1 from erp.close_task ct
                          where ct.tenant_id = t.id
                            and ct.fiscal_period_id = p.id) then
            perform erp.open_period_close(p.id);
          end if;

          -- In the order the dependencies allow, and with no waiver reason:
          -- the four ties are unwaivable and each runs its check inside
          -- erp.complete_close_task(), so the month passes on its own figures
          -- or says which figure it failed on.
          for k in select ct.id
                     from erp.close_task ct
                    where ct.tenant_id = t.id
                      and ct.fiscal_period_id = p.id
                      and ct.status not in ('complete', 'waived')
                    order by ct.seq, ct.code
          loop
            perform erp.complete_close_task(k.id, null);
          end loop;

          perform erp.close_period(p.id);
          v_closed := v_closed + 1;

        exception when others then
          v_stuck := v_stuck + 1;
          raise warning 'demonstration %: % of the % ledger stays open — %',
            t.code, p.code, p.ledger, sqlerrm;
        end;
      end loop;

      raise notice 'demonstration %: % historic period(s) closed with nothing waived, % left open',
        t.code, v_closed, v_stuck;

    exception when others then
      raise warning 'demonstration %: its months were left open because the close refused — %',
        t.code, sqlerrm;
    end;
  end loop;
end
$close$;

select set_config('request.jwt.claims', '', true);

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

-- ── Proved ───────────────────────────────────────────────────────────────────
--
-- Nothing new is declared here, so there is no governance to assert and no
-- door to give a home to; what this file changes is one demonstration
-- organisation's data, through doors that already have both. The claim it has
-- to answer for is that the books still tie afterwards, over every
-- organisation on the database and not only the one it touched — which is the
-- assertion the deploy's own proof step would fail on if this were wrong.

select erp.assert_whole_database_reconciles();
select erp.assert_isolation();
select erp.assert_public_api_safe();
