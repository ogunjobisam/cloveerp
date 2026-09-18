set lock_timeout = '30s';

-- This database's configuration file sets statement_timeout to two minutes,
-- and the work below is more than two minutes on a demonstration five months
-- behind. Two things would go wrong under it. A cancellation is
-- query_canceled, which `exception when others` deliberately does not catch,
-- so the timeout would abort the migration and take the deploy down — the one
-- outcome this file is written to avoid. And erp.seed_demo_history() paces
-- itself off statement_timeout, starting no new day once a quarter of it has
-- gone; measured against a whole DO statement rather than one call, that would
-- leave every call after the first thirty seconds building a single day.
-- Lifting it here makes each call build its five days and lets a refusal be
-- caught and reported instead of ending the run. The work is bounded — about
-- thirty calls of five days, then the receipts, then sixty-four periods at
-- roughly a tenth of a second each — and lock_timeout above still stops it
-- waiting on anybody. RESET at the foot puts the configured two minutes back
-- whether or not the replay wrapped this file in a transaction of its own.
set statement_timeout = 0;

-- =============================================================================
-- 20260920240000  The demonstration is a going concern
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
-- 2026, and it collected as it went — 427,242.86 across 340 bank rows, the last
-- of them the builder's own on 20 May 2026. On the day it stopped, the ageing
-- was healthy: two December invoices open, five January, and the rest of
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
-- 549,657.70 of goods received not invoiced against 1,850 of trade payables
-- has a cause of its own: the builder only learned to bill a supplier on
-- 17 September (20260918600000), three days after this demonstration's history
-- was built, so every receipt it ever made is still sitting in the accrual.
-- Worse, the Thursday block it gained takes the NEWEST unbilled receipt, so
-- trading forward alone would never reach the oldest and "oldest 379 days"
-- would stay on the screen. The backlog is billed oldest first instead, on the
-- builder's own test of whether a receipt may be billed.
--
-- And no organisation on this database has ever closed a period, nor has the
-- Period close module: erp.ensure_demo_configuration() installs six modules and
-- this is not one of them, which is why supabase/ci/close_month.sh has to
-- install it before it can close the month the build seeds.
--
-- ── ONE ROUTINE, BECAUSE A SUITE HAS TO BE ABLE TO RUN IT ────────────────────
--
-- The work is erp.demonstration_catch_up(), not a block of this file, and that
-- is the whole point of the shape. A migration that did this inline would be
-- proved by the build only in the branch where it finds nothing: CI creates its
-- demonstration organisation (supabase/ci/seed_demo.sql) AFTER every migration
-- has applied, and its code is ci-demo, so nothing here would match. The build
-- would have proved that the code does not crash when there is nothing to do,
-- and production would have been the first database ever to run the other
-- branch. That is the shape of the two deploys lost this week: a check correct
-- and cheap on an empty build, wrong on a live one, because CI and production
-- ran different branches of the same code.
--
-- So the behaviour lives in a routine, and erp_test.demonstration_catch_up_suite()
-- stands up an organisation with the shape this acts on — a demonstration that
-- stopped trading three weeks ago, owing money that fell due nearly five months ago,
-- with receipts nobody has billed and no month ever closed — runs the routine
-- on it, and holds it to what changed: that it traded up to today, that what it
-- is owed fell but not to nothing and is no longer all of it old, that the
-- accrual moved to the creditors, that every month before this one is closed
-- with nothing waived and this one is not, that the four ties still hold, and
-- that running it a second time changes nothing. It also holds the two guards:
-- the routine refuses an organisation that is not a demonstration, and refuses
-- a demonstration whose environment is live. Ten cases, pinned at both ends,
-- undone by CLOVEERP_SUITE_UNDO so it leaves nothing behind.
--
-- ── IT RUNS TWICE WITHOUT DOING IT TWICE ─────────────────────────────────────
--
-- This applies once to production, but a replay, a recovery rehearsal or a
-- rebuilt environment will run it again against an organisation whose
-- receivables have already been collected and whose months are already closed.
-- Every step is already idempotent and none of it is idempotent by accident:
-- erp.seed_demo_history() skips a day whose DEMO- reference is already there
-- and says how many it skipped; the billing looks only for receipts with
-- nothing invoiced against their order lines, which a bill leaves none of; and
-- the close looks only for periods still open and ending before this month.
-- The suite's ninth case is that second run, and it asserts the counts are
-- zero and nothing moved.
--
-- ── WHY A REFUSAL HERE WARNS AND DOES NOT FAIL ───────────────────────────────
--
-- Inside the routine each of the three steps is wrapped, so a refusal is
-- recorded in the report it returns and that step's work rolls back to where it
-- started; at the end of this file each organisation is wrapped again, so a
-- refusal is a warning naming the organisation and carrying the database's own
-- message. None of this is an invariant of the product: it is hygiene on one
-- demonstration organisation's data. A red deploy blocks every other branch,
-- and blocking a release because a demonstration month would not close would be
-- the wrong trade every time. What must not happen is a refusal nobody sees, so
-- nothing is caught silently, and each step asserts the ties itself before it
-- returns, so a step that would leave the books disagreeing takes none of its
-- own work with it.
--
-- ── DEMONSTRATION ORGANISATIONS ONLY ─────────────────────────────────────────
--
-- Twice over. The routine refuses any organisation whose code does not begin
-- 'demo-' or whose environment is live, and the loop at the foot of this file
-- only ever offers it organisations of that shape. Nothing falls back to "the
-- only organisation" or "the first organisation". Clove Foods and the platform
-- organisation are neither named nor matched.
--
-- Dates come from erp.local_today() (20260920110000): the bill is dated where
-- the goods arrived and the month the close stops at is the organisation's own
-- month, because at a month boundary the database's month is a different one
-- and closing it would close the month the organisation is still working in.
-- erp.bill_from_receipt() still defaults its own invoice date from
-- current_date, which 20260920110000 did not reach; the day is passed to it
-- rather than left to it, and that default is worth fixing where it lives.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The work, as one routine
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.demonstration_catch_up()
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  v_code     text;
  v_why      text;
  v_last     date;
  v_cursor   date;
  v_today    date;
  v_res      jsonb;
  v_built    integer := 0;
  v_calls    integer := 0;
  v_billed   integer := 0;
  v_unbilled integer := 0;
  v_closed   integer := 0;
  v_stuck    integer := 0;
  v_stopped  text;
  v_notes    jsonb := '[]'::jsonb;
  g          record;
  p          record;
  k          record;
begin
  select t.code into v_code from erp.tenant t where t.id = v_tenant;

  v_why := case
             when v_code is null or v_code not like 'demo-%'
               then 'its name does not begin with demo-'
             when erp.environment_is_live()
               then 'its environment is a live one'
           end;

  if v_why is not null then
    raise exception
      'CLOVEERP_NOT_A_DEMONSTRATION: % is not a demonstration organisation, because %',
      coalesce(v_code, 'this organisation'), v_why
      using errcode = '42501',
            hint = 'Open a demonstration organisation and run it there. Made-up '
                   'trading, made-up supplier bills and months closed on nobody''s '
                   'say-so do not belong in a real company''s books.';
  end if;

  -- ── Trading, up to the day this runs ───────────────────────────────────────
  --
  -- current_date and not erp.local_today(): the builder clamps its own end to
  -- current_date, so a bound past that one would only buy a call that builds
  -- nothing.
  begin
    select max(to_date(substring(d.their_reference from 6 for 8), 'YYYYMMDD'))
      into v_last
      from erp.document d
     where d.tenant_id = v_tenant
       and d.their_reference ~ '^DEMO-[0-9]{8}-';

    if v_last is null then
      v_notes := v_notes || to_jsonb(
        'It has no history the builder made, so there is no day to carry on from.'::text);
    else
      v_cursor := v_last + 1;

      <<catching_up>>
      while v_cursor <= current_date loop
        -- A slice that refuses stops the catching up where it stopped. The days
        -- already built are days of trading that happened and each one was a
        -- call of its own; throwing them away because the day after them would
        -- not build would be giving ground at the wrong end.
        begin
          v_res := erp.seed_demo_history(v_cursor, null, 1);
        exception when others then
          v_stopped := format('%s would not build: %s', v_cursor, sqlerrm);
        end;
        exit catching_up when v_stopped is not null;

        v_built := v_built + coalesce((v_res ->> 'built')::integer, 0);
        v_calls := v_calls + 1;
        exit catching_up when coalesce((v_res ->> 'done')::boolean, true);
        v_cursor := (v_res ->> 'next_from')::date;
        -- A call always advances, so this cannot spin; it is here because a
        -- loop driving a routine on that routine's own answer should not be
        -- able to run a deploy out of its hour if that ever stops being true.
        exit catching_up when v_calls > 500;
      end loop catching_up;

      if v_stopped is not null then
        v_notes := v_notes || to_jsonb(
          format('It traded as far as it could and then stopped. %s', v_stopped));
      end if;

      -- The books after the catching up, or none of it.
      perform erp.assert_stock_reconciles();
      perform erp.assert_inventory_reconciles();
      perform erp.assert_subledger_reconciles();
      perform erp.assert_ageing_equals_control();
      perform erp.assert_trial_balance_balances();
    end if;
  exception when others then
    -- Variables are not rolled back with the rows, so the count of what was
    -- built has to be put back by hand or it would report work that no longer
    -- exists.
    v_built := 0; v_calls := 0;
    v_notes := v_notes || to_jsonb(
      format('Its trading was left where it was, because carrying on refused. %s', sqlerrm));
  end;

  -- ── The supplier bills the builder never raised ────────────────────────────
  begin
    for g in
      select d.id, d.document_number, d.document_date, d.site_id
        from erp.document d
        join erp.document_type dt
          on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
       where d.tenant_id = v_tenant
         and dt.code = 'goods_receipt'
         and not d.is_cancelled
         and erp.object_current_state('document', d.id) = 'posted'
         and exists (select 1 from erp.document_relation fr
                      where fr.tenant_id = d.tenant_id
                        and fr.from_document_id = d.id
                        and fr.relation_kind = 'fulfils'
                        and fr.to_line_id is not null)
         -- Nothing billed against the order lines it arrived against, so the
         -- accrual it raised is the whole of what this bill clears. It is also
         -- what makes a second run find nothing: a bill leaves none.
         and not exists (select 1 from erp.document_relation fr
                           join erp.document_line ol
                             on ol.tenant_id = fr.tenant_id and ol.id = fr.to_line_id
                          where fr.tenant_id = d.tenant_id
                            and fr.from_document_id = d.id
                            and fr.relation_kind = 'fulfils'
                            and coalesce(ol.quantity_invoiced, 0) > 0)
         -- Nothing on its way back to the supplier: billing for goods that were
         -- returned is how a demonstration acquires a credit balance nobody can
         -- explain.
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
        -- Dated where the goods arrived rather than where the database is
        -- standing (20260920110000).
        v_today := erp.local_today(g.site_id);
        perform erp.bill_from_receipt(
                  g.id, 'INV/' || g.document_number, v_today, v_today + 30, true);
        v_billed := v_billed + 1;
      exception when others then
        v_unbilled := v_unbilled + 1;
        v_notes := v_notes || to_jsonb(
          format('%s of %s is still waiting for its bill. %s',
                 g.document_number, g.document_date, sqlerrm));
      end;
    end loop;

    -- The accrual has moved to the creditors, or none of it has.
    perform erp.assert_subledger_reconciles();
    perform erp.assert_ageing_equals_control();
    perform erp.assert_trial_balance_balances();
  exception when others then
    v_billed := 0; v_unbilled := 0;
    v_notes := v_notes || to_jsonb(
      format('Its goods received not invoiced were left as they were, because billing refused. %s',
             sqlerrm));
  end;

  -- ── The months that were never closed ──────────────────────────────────────
  begin
    if not exists (select 1 from erp.change_set c
                    where c.tenant_id = v_tenant and c.code = 'period-close') then
      perform erp.configure_period_close();
    end if;

    -- The month is the organisation's own, not the one the database is standing
    -- in: at a month boundary those are different months, and this would
    -- otherwise close the month the organisation is still working in.
    v_today := erp.local_today();

    for p in select fp.id, fp.code, l.code as ledger
               from erp.fiscal_period fp
               join erp.ledger l
                 on l.tenant_id = fp.tenant_id and l.id = fp.ledger_id
              where fp.tenant_id = v_tenant
                and fp.status = 'open'::erp.period_status
                and fp.ends_on < date_trunc('month', v_today)::date
              order by fp.ends_on, l.code
    loop
      begin
        -- erp.open_period_close() refuses a period whose tasks are already
        -- raised, because its insert conflicts away to nothing and it reads
        -- that as an organisation with no template. Raise them once.
        if not exists (select 1 from erp.close_task ct
                        where ct.tenant_id = v_tenant
                          and ct.fiscal_period_id = p.id) then
          perform erp.open_period_close(p.id);
        end if;

        -- In the order the dependencies allow, and with no waiver reason: four
        -- of the six are unwaivable ties and each runs its check inside
        -- erp.complete_close_task(), where it cannot be ticked past, so a month
        -- passes on its own figures or says which figure it failed on.
        for k in select ct.id
                   from erp.close_task ct
                  where ct.tenant_id = v_tenant
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
        v_notes := v_notes || to_jsonb(
          format('%s of the %s ledger stays open. %s', p.code, p.ledger, sqlerrm));
      end;
    end loop;
  exception when others then
    v_closed := 0; v_stuck := 0;
    v_notes := v_notes || to_jsonb(
      format('Its months were left open, because the close refused. %s', sqlerrm));
  end;

  return jsonb_build_object(
    'organisation',     v_code,
    'traded_from',      v_last + 1,
    'traded_to',        current_date,
    'documents_built',  v_built,
    'calls',            v_calls,
    'bills_raised',     v_billed,
    'receipts_unbilled', v_unbilled,
    'periods_closed',   v_closed,
    'periods_left_open', v_stuck,
    'notes',            v_notes);
end;
$$;

comment on function erp.demonstration_catch_up() is
  'Brings one demonstration organisation up to today: trades forward from the '
  'last day its builder built, bills the goods it received and never billed, '
  'and closes every month before this one with nothing waived. Refuses any '
  'organisation that is not a demonstration. Safe to run twice.';

revoke all on function erp.demonstration_catch_up() from public, anon;

select erp.register_refusal(
  'CLOVEERP_NOT_A_DEMONSTRATION',
  'Asking for made-up trading to be added to an organisation that is not a demonstration.',
  'A demonstration organisation is one nobody works in: its customers, its '
  'orders and its money were all invented so the product has something to show. '
  'Bringing one up to date means inventing more of them, billing goods against '
  'orders nobody placed and closing months on nobody''s say-so. Doing that to a '
  'real company would put transactions in its books that never happened, and '
  'the books are the one thing an accounting system is not allowed to make up. '
  'So it is refused unless the organisation is named as a demonstration and its '
  'environment says it is not a live one.',
  'Open a demonstration organisation and run it there. If this organisation '
  'really is meant to be a demonstration, that is a question about how it was '
  'set up, not something to work around here.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Proved on an organisation shaped like the one it is for
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The fixture is a demonstration that stopped trading three weeks ago and traded
-- for ten days four months before that, so it owes money that fell due long
-- enough ago to be old, holds receipts nobody has billed, and has never closed a
-- month — the live organisation's shape, small enough to build in seconds. It
-- starts under a name that is not a demonstration's and in a live environment,
-- so both guards are met before anything else happens.

create or replace function erp_test.demonstration_catch_up_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases    integer := 0;
  v_tenant   uuid; v_admin uuid; v_token text;
  v_auth     constant uuid := '00000000-0000-4000-8000-00000000cac0';
  v_old      constant date := current_date - 145;
  v_recent   constant date := current_date - 25;
  v_report   jsonb; v_again jsonb;
  v_refused1 text; v_refused2 text;
  v_owed_before bigint; v_owed_after bigint;
  v_stale_before bigint; v_stale_after bigint;
  v_fresh_after bigint;
  v_grni_before integer; v_grni_after integer;
  v_accrual_before bigint; v_accrual_after bigint; v_payables_after bigint;
  v_last_before date; v_last_after date;
  v_open_before integer; v_historic_after integer; v_current_open integer;
  v_waived integer; v_ties integer; v_closed_periods integer;
  v_docs integer; v_docs_again integer;
  v_bills integer; v_bills_again integer;
  v_closed_again integer;
  v_ok boolean; v_msg text; v_fixture text;
begin
  begin
  select t.tenant_id, t.admin_user_id, t.admin_token
    into v_tenant, v_admin, v_token
    from erp.provision_tenant('zzcatchup', 'Catch-up suite',
                              'admin@zzcatchup.test', 'Catch-up Admin') t;
  insert into auth.users (id, email) values (v_auth, 'admin@zzcatchup.test');
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_auth)::text, true);
  perform erp.claim_invitation(v_token);

  -- ── 1. Not a demonstration, so it is refused ───────────────────────────────
  v_cases := v_cases + 1;
  begin
    perform erp.demonstration_catch_up();
    v_refused1 := '(it did not refuse)';
  exception when others then
    v_refused1 := sqlerrm;
  end;
  case_name := 'an organisation whose name does not begin demo- is refused, whatever else is true of it';
  passed := v_refused1 like 'CLOVEERP_NOT_A_DEMONSTRATION:%'
        and v_refused1 like '%does not begin with demo-%';
  detail := left(v_refused1, 200);
  return next;

  -- ── 2. A demonstration in a live environment is refused ────────────────────
  -- erp.provision_tenant() leaves the organisation live, as it should.
  v_cases := v_cases + 1;
  update erp.tenant set code = 'demo-zzcatchup' where id = v_tenant;
  begin
    perform erp.demonstration_catch_up();
    v_refused2 := '(it did not refuse)';
  exception when others then
    v_refused2 := sqlerrm;
  end;
  case_name := 'a demonstration whose environment says live is refused too, so the name alone is not enough';
  passed := v_refused2 like 'CLOVEERP_NOT_A_DEMONSTRATION:%'
        and v_refused2 like '%environment is a live one%';
  detail := left(v_refused2, 200);
  return next;

  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  perform erp.ensure_demo_configuration(v_tenant, v_admin);

  -- Ten days of trading four months ago, then five days three weeks ago: money
  -- that fell due long ago, and a gap for the routine to close.
  perform erp.seed_demo_history(v_old, null, 1);
  perform erp.seed_demo_history(v_old + 5, null, 1);
  perform erp.seed_demo_history(v_recent, null, 1);
  set constraints all immediate;

  select coalesce(sum(a.total_minor), 0),
         coalesce(sum(a.days_over_90), 0)
    into v_owed_before, v_stale_before
    from erp.receivables_ageing(null) a;
  select count(*), coalesce(sum(g.open_value_minor), 0)
    into v_grni_before, v_accrual_before
    from erp.grni_report() g;
  select max(to_date(substring(d.their_reference from 6 for 8), 'YYYYMMDD'))
    into v_last_before
    from erp.document d
   where d.tenant_id = v_tenant and d.their_reference ~ '^DEMO-[0-9]{8}-';
  select count(*) into v_open_before
    from erp.fiscal_period fp
   where fp.tenant_id = v_tenant and fp.status = 'open'::erp.period_status;

  -- ── 3. The fixture is the shape this suite is about ────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture stopped trading three weeks ago, is owed money that fell due more than ninety days ago, holds receipts nobody has billed, and has never closed a month';
  passed := v_last_before = v_recent + 4
        and v_owed_before > 0 and v_stale_before > 0
        and v_grni_before > 0 and v_accrual_before > 0
        and v_open_before > 0
        and not exists (select 1 from erp.fiscal_period fp
                         where fp.tenant_id = v_tenant
                           and fp.status <> 'open'::erp.period_status);
  detail := format('last built %s; owed %s of which %s over ninety days; %s receipt(s) unbilled worth %s; %s period(s), all open',
                   v_last_before, v_owed_before, v_stale_before,
                   v_grni_before, v_accrual_before, v_open_before);
  return next;

  v_report := erp.demonstration_catch_up();

  select coalesce(sum(a.total_minor), 0),
         coalesce(sum(a.days_over_90), 0),
         coalesce(sum(a.current_minor + a.days_1_30), 0)
    into v_owed_after, v_stale_after, v_fresh_after
    from erp.receivables_ageing(null) a;
  select count(*), coalesce(sum(g.open_value_minor), 0)
    into v_grni_after, v_accrual_after
    from erp.grni_report() g;
  select max(to_date(substring(d.their_reference from 6 for 8), 'YYYYMMDD'))
    into v_last_after
    from erp.document d
   where d.tenant_id = v_tenant and d.their_reference ~ '^DEMO-[0-9]{8}-';

  -- ── 4. It traded forward to today ──────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'it carried on from the day after the last day the builder built and traded up to today, in calls of five days';
  passed := (v_report ->> 'traded_from')::date = v_last_before + 1
        and (v_report ->> 'traded_to')::date = current_date
        and (v_report ->> 'documents_built')::integer > 0
        and v_last_after > v_last_before
        and v_last_after >= current_date - 1;
  detail := format('from %s to %s, %s document(s) in %s call(s); last day built %s',
                   v_report ->> 'traded_from', v_report ->> 'traded_to',
                   v_report ->> 'documents_built', v_report ->> 'calls', v_last_after);
  return next;

  -- ── 5. The tail, not nothing ───────────────────────────────────────────────
  -- The builder applies cash to the oldest open item of the customer it comes
  -- from, so the old debt is what the new months collect first.
  v_cases := v_cases + 1;
  case_name := 'what it is owed fell but not to nothing, the debt that had fallen due long ago was collected, and what is owed now includes invoices raised since';
  passed := v_owed_after > 0
        and v_stale_after < v_stale_before
        and v_fresh_after > 0;
  detail := format('owed %s before, %s after; over ninety days %s before, %s after; %s of it inside thirty days',
                   v_owed_before, v_owed_after, v_stale_before, v_stale_after, v_fresh_after);
  return next;

  -- ── 6. The accrual became a creditor ───────────────────────────────────────
  v_cases := v_cases + 1;
  select coalesce(sum(si.credit_minor - si.debit_minor), 0) into v_payables_after
    from erp.subledger_item si
   where si.tenant_id = v_tenant and si.control_kind = 'payable';
  case_name := 'the goods it had received and never billed are billed, oldest first, and the accrual has moved to the creditors';
  passed := (v_report ->> 'bills_raised')::integer > 0
        and v_grni_after < v_grni_before
        and v_accrual_after < v_accrual_before
        and v_payables_after > 0;
  detail := format('%s bill(s) raised, %s receipt(s) refused; unbilled %s→%s, accrual %s→%s; creditors %s',
                   v_report ->> 'bills_raised', v_report ->> 'receipts_unbilled',
                   v_grni_before, v_grni_after, v_accrual_before, v_accrual_after,
                   v_payables_after);
  return next;

  -- ── 7. Every month before this one, and not this one ───────────────────────
  v_cases := v_cases + 1;
  select count(*) into v_historic_after
    from erp.fiscal_period fp
   where fp.tenant_id = v_tenant
     and fp.status = 'open'::erp.period_status
     and fp.ends_on < date_trunc('month', erp.local_today())::date;
  select count(*) into v_current_open
    from erp.fiscal_period fp
   where fp.tenant_id = v_tenant
     and fp.status = 'open'::erp.period_status
     and erp.local_today() between fp.starts_on and fp.ends_on;
  select count(*) into v_closed_periods
    from erp.fiscal_period fp
   where fp.tenant_id = v_tenant and fp.status = 'closed'::erp.period_status;
  select count(*) filter (where ct.status <> 'complete'),
         count(*) filter (where not ct.is_waivable)
    into v_waived, v_ties
    from erp.close_task ct
   where ct.tenant_id = v_tenant;
  case_name := 'every month that ended before this one is closed, this month is still open, and nothing was waived to get there';
  passed := v_closed_periods = (v_report ->> 'periods_closed')::integer
        and v_closed_periods > 0
        and v_historic_after = 0
        and v_current_open > 0
        and (v_report ->> 'periods_left_open')::integer = 0
        and v_waived = 0
        and v_ties >= 4 * v_closed_periods;
  detail := format('%s period(s) closed, %s historic still open, %s current open; %s task(s) not complete, %s unwaivable tie(s)',
                   v_closed_periods, v_historic_after, v_current_open, v_waived, v_ties);
  return next;

  -- ── 8. And the books still tie ─────────────────────────────────────────────
  v_cases := v_cases + 1;
  begin
    v_msg := erp.assert_stock_reconciles() || '; ' || erp.assert_inventory_reconciles()
             || '; ' || erp.assert_subledger_reconciles()
             || '; ' || erp.assert_ageing_equals_control()
             || '; ' || erp.assert_trial_balance_balances();
    v_ok := true;
  exception when others then
    v_ok := false;
    v_msg := left(sqlerrm, 300);
  end;
  case_name := 'after the trading, the bills and the closes, stock, inventory, the subledgers, the ageing and the trial balance all still agree';
  passed := v_ok;
  detail := v_msg;
  return next;

  -- ── 9. A second run finds nothing to do ────────────────────────────────────
  v_cases := v_cases + 1;
  select count(*) into v_docs from erp.document d where d.tenant_id = v_tenant;
  select count(*) into v_bills
    from erp.document d join erp.document_type dt
      on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
   where d.tenant_id = v_tenant and dt.code = 'purchase_invoice';
  v_again := erp.demonstration_catch_up();
  select count(*) into v_docs_again from erp.document d where d.tenant_id = v_tenant;
  select count(*) into v_bills_again
    from erp.document d join erp.document_type dt
      on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
   where d.tenant_id = v_tenant and dt.code = 'purchase_invoice';
  select count(*) into v_closed_again
    from erp.fiscal_period fp
   where fp.tenant_id = v_tenant and fp.status = 'closed'::erp.period_status;
  case_name := 'run a second time it builds nothing, bills nothing and closes nothing, and the organisation is exactly as the first run left it';
  passed := (v_again ->> 'documents_built')::integer = 0
        and (v_again ->> 'bills_raised')::integer = 0
        and (v_again ->> 'periods_closed')::integer = 0
        and (v_again ->> 'periods_left_open')::integer = 0
        and (v_again ->> 'receipts_unbilled')::integer = 0
        and v_docs_again = v_docs
        and v_bills_again = v_bills
        and v_closed_again = v_closed_periods;
  detail := format('%s document(s) before, %s after; %s bill(s) before, %s after; %s period(s) closed before, %s after; report %s',
                   v_docs, v_docs_again, v_bills, v_bills_again,
                   v_closed_periods, v_closed_again,
                   v_again - 'notes');
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      -- Kept so the count guard below can say what the fixture met. Re-raising
      -- here would lose every case already returned.
      v_fixture := left(sqlerrm, 300);
    end if;
  end;

  -- ── 10. Undone ─────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone, and nothing in it stopped early';
  -- v_fixture holds anything the fixture met that was not the undo. Without
  -- this the suite would pass on a fixture that fell over after its last case,
  -- which is the failure a suite is supposed to be incapable of.
  passed := not exists (select 1 from erp.tenant
                         where code in ('zzcatchup', 'demo-zzcatchup'))
        and not exists (select 1 from auth.users where id = v_auth)
        and v_fixture is null;
  detail := coalesce('the fixture stopped early: ' || v_fixture,
                     'demo-zzcatchup rolled back with its trading, its bills and its closed months');
  return next;

  if v_cases <> 10 then
    raise exception
      'CLOVEERP_SUITE_SHRANK: demonstration_catch_up_suite ran % cases, expected 10%',
      v_cases, coalesce(' — the fixture stopped early: ' || v_fixture, '');
  end if;
end;
$$;

revoke all on function erp_test.demonstration_catch_up_suite() from public, anon;

create or replace function erp_test.assert_demonstration_catch_up_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _demonstration_catch_up on commit drop as
    select * from erp_test.demonstration_catch_up_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _demonstration_catch_up;
  drop table _demonstration_catch_up;
  if v_fail > 0 then
    raise exception E'CLOVEERP_DEMONSTRATION_CATCH_UP_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> 10 then
    raise exception 'CLOVEERP_SUITE_SHRANK: demonstration_catch_up_suite ran % cases, expected 10', v_all;
  end if;
  return format('a demonstration is brought up to today and stays that way: %s/%s cases passed',
                v_all, v_all);
end;
$$;

revoke all on function erp_test.assert_demonstration_catch_up_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. And then it is run, on the demonstrations this database has
-- ═════════════════════════════════════════════════════════════════════════════

do $catch_up$
declare
  -- What the routine needs of the person it acts as. A demonstration whose
  -- administrator does not hold all of these is left alone rather than acted on
  -- by the build role, which holds nothing and would prove nothing.
  v_needs  constant text[] := array[
    'master_data.write', 'administration.configure', 'administration.promote',
    'finance.post', 'finance.close_period', 'procurement.match'];
  t        record;
  v_admin  uuid;
  v_report jsonb;
  n        jsonb;
  v_orgs   integer := 0;
begin
  for t in select tn.id, tn.code from erp.tenant tn
            where tn.code like 'demo-%'
              and tn.status = 'active'::erp.tenant_status
            order by tn.code
  loop
    begin
      v_admin := null;

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
        raise warning 'demonstration %: nobody signed in there holds all of %, so it was left as it was',
          t.code, array_to_string(v_needs, ', ');
        continue;
      end if;

      -- As that administrator, in that organisation, transaction-local, the way
      -- supabase/ci/close_month.sh and supabase/ci/seed_demo.sql do it.
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

      v_report := erp.demonstration_catch_up();
      v_orgs := v_orgs + 1;

      raise notice 'demonstration %: traded % to %, % document(s) in % call(s); % supplier bill(s) raised, % receipt(s) left; % month(s) closed, % left open',
        t.code, v_report ->> 'traded_from', v_report ->> 'traded_to',
        v_report ->> 'documents_built', v_report ->> 'calls',
        v_report ->> 'bills_raised', v_report ->> 'receipts_unbilled',
        v_report ->> 'periods_closed', v_report ->> 'periods_left_open';

      -- Nothing the routine could not do is left unsaid.
      for n in select jsonb_array_elements(v_report -> 'notes') loop
        raise warning 'demonstration %: %', t.code, n #>> '{}';
      end loop;

    exception when others then
      raise warning 'demonstration %: it was left as it was, because bringing it up to date refused — %',
        t.code, sqlerrm;
    end;
  end loop;

  if v_orgs = 0 then
    raise notice 'no demonstration organisation was brought up to date';
  end if;
end
$catch_up$;

select set_config('request.jwt.claims', '', true);

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. What the screens now read
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Through the doors the tiles themselves call, so the deploy's log carries the
-- figures a person would see rather than a restatement of them. Nothing here
-- writes: every door below is STABLE.

do $report$
declare
  v_needs  constant text[] := array[
    'master_data.write', 'administration.configure', 'administration.promote',
    'finance.post', 'finance.close_period', 'procurement.match'];
  t        record;
  v_admin  uuid;
  v_ageing jsonb;
  v_grni   jsonb;
  v_owed   bigint;
  v_late   bigint;
begin
  for t in select tn.id, tn.code from erp.tenant tn
            where tn.code like 'demo-%'
              and tn.status = 'active'::erp.tenant_status
            order by tn.code
  loop
    begin
      v_admin := null;

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

      if erp.current_tenant_id() is distinct from t.id then
        continue;
      end if;

      v_ageing := public.erp_receivables_ageing(null);
      v_grni   := public.erp_grni();

      select coalesce(sum((e ->> 'total_minor')::bigint), 0),
             coalesce(sum((e ->> 'days_61_90')::bigint
                          + (e ->> 'days_over_90')::bigint), 0)
        into v_owed, v_late
        from jsonb_array_elements(v_ageing) e;

      raise notice
        'demonstration %: receivables % over % customer(s), % of it past sixty days; % customer(s) in dunning; % receipt(s) not invoiced, oldest % day(s); % of % period(s) open',
        t.code,
        to_char(v_owed / 100.0, 'FM999G999G990D00'),
        jsonb_array_length(v_ageing),
        to_char(v_late / 100.0, 'FM999G999G990D00'),
        jsonb_array_length(public.erp_dunning_worklist()),
        jsonb_array_length(v_grni),
        coalesce((select max((e ->> 'age_days')::integer)
                    from jsonb_array_elements(v_grni) e), 0),
        (select count(*) from jsonb_array_elements(public.erp_fiscal_periods()) e
          where e ->> 'status' = 'open'),
        jsonb_array_length(public.erp_fiscal_periods());

    exception when others then
      raise warning 'demonstration %: its figures could not be read back — %',
        t.code, sqlerrm;
    end;
  end loop;
end
$report$;

select set_config('request.jwt.claims', '', true);

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The generators, then the assertions
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
-- The suite first, because it is the only thing on an empty build that runs the
-- routine at all: this database has no organisation whose name begins 'demo-'
-- until supabase/ci/seed_demo.sql makes one, and it makes ci-demo after every
-- migration has applied. Then the whole database, over every organisation and
-- not only the one this touched, which is the assertion the deploy's own proof
-- step would fail on if this were wrong.

select erp_test.assert_demonstration_catch_up_suite();

select erp.assert_whole_database_reconciles();
select erp.assert_refusals_name_next_action();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();

reset statement_timeout;
