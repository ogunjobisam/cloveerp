set lock_timeout = '30s';

-- =============================================================================
-- 20260921110000  The close follows the trading
-- -----------------------------------------------------------------------------
-- 20260921090000 fixed the determination refusal and the live catch-up moved
-- on to the next one, on the same organisation and the same first day:
--
--   - demo-cbb10384: traded 2026-04-15 to 2026-09-21, 0 document(s); ...
--   - demo-cbb10384: It traded as far as it could and then stopped.
--     2026-04-15 would not build: CLOVEERP_PERIOD_CLOSED: 2026-04 is closed;
--     record a reopening with a reason before posting to it
--
-- ── WHAT IS WRONG, AND IT IS NOT THE ORDER ───────────────────────────────────
--
-- erp.demonstration_catch_up() already trades before it closes. The defect is
-- that its close phase's SCOPE never looked at how far the trading got, and
-- the phase runs whatever the trading did:
--
--   * The three phases are independent begin/exception blocks. The trading
--     phase's per-day handler catches a refusal, records a note and the block
--     then COMPLETES NORMALLY. Building nothing has been indistinguishable, to
--     the phases after it, from building everything.
--   * The close phase selected every period with ends_on < the current month,
--     with no reference to the trading at all.
--
-- So on the deploy of 18 September the determination bug meant the trading
-- built nothing, and the close then sealed 64 months — including 2026-04 to
-- 2026-08, which had never been traded. The next run's trading tried to build
-- into 2026-04 and met the close its own earlier run had performed. The two
-- halves are incapable of NOT conflicting on any organisation where the close
-- has run and the trading has not caught up.
--
-- CLOVEERP_PERIOD_CLOSED is correct and is untouched. It is a trigger under
-- every door (erp.check_period_open(), 0026), and a demonstration is not a
-- reason to make books writable after close.
--
-- ── 1. THE CLOSE FOLLOWS THE TRADING ─────────────────────────────────────────
--
-- The close now closes only periods ending on or before the last day the
-- builder has actually built — the trading frontier, taken from what
-- erp.seed_demo_history() reports as built_through on each call it answers,
-- and from the last DEMO- day already on the books before that. A month whose
-- trading is not finished is not a month anybody closes.
--
-- This is the part that ships regardless of anything below it. Had it been in
-- place on 18 September, the trading built nothing, so nothing would have been
-- closed and the second failure would not exist. It also makes the two phases
-- structurally unable to conflict again, which is what turns the repair below
-- into a one-time act rather than a standing one.
--
-- ── 2. AND THE REOPENING, WHICH IS NARROW ON PURPOSE ─────────────────────────
--
-- The frontier rule alone leaves demo-cbb10384 where it is: its 2026-04 is
-- closed and its frontier is 2026-04-14, so the trading can never advance and
-- the catch-up would report nothing built for ever. There is exactly one key
-- to that lock and the product already ships it: erp.reopen_period() records
-- who reopened a period and why, erp.check_period_open() honours a reopening
-- only while it is the most recent thing to have happened to the period, and
-- erp.close_period() closes it again (20260914071000). Reopen, trade, close
-- again is a designed, audited cycle, not a way round the guard.
--
-- WHY IT IS ALLOWED TO RUN FROM A DEPLOY, WHICH IS THE WHOLE OF THE REASON:
-- erp.demonstration_catch_up() refuses outright unless the organisation's code
-- begins 'demo-' AND erp.environment_is_live() is false. That guard is
-- load-bearing for this decision and must not be relaxed. What is established
-- here is not "a deploy may reopen closed books" — it is "a deploy may reopen
-- books in a non-live demonstration organisation", where the books are
-- invented and nobody's audit depends on them. The narrowness IS the
-- permission. A later change that widened that guard would be changing this
-- decision, not inheriting it.
--
-- The scope is narrow twice over. Only periods ending after the frontier are
-- reopened — those the close ran on before the trading ever reached them, plus
-- the part-traded month the frontier falls in. Months that were genuinely
-- traded stay closed: they were closed legitimately and nothing here disturbs
-- them. And each reopening carries a reason saying plainly that it repairs a
-- close that ran on months which had never been traded.
--
-- ── 3. AND THE RE-CLOSE IS NOT A FORMALITY ───────────────────────────────────
--
-- erp.close_period() refuses a period whose close tasks are open and takes a
-- complete one on trust. A task completed before the reopening was completed
-- against figures that are no longer the figures, so re-closing on it would be
-- a rubber stamp over months of new trading. erp.complete_close_task() has no
-- "already complete" guard and RE-RUNS its blocking check, so for a period
-- this run reopened, every task that is not waived is completed again and
-- every check runs against the figures the new trading leaves — including the
-- four unwaivable ties, which are whole-organisation reconciliations
-- (erp.close_check_is_a_tie(), 20260918400000). A waived task is somebody's
-- recorded judgement and is left alone.
--
-- Two smaller things go with it. A period left in 'closing' — tasks raised, a
-- close that did not finish — was never selected again by a phase that only
-- looked for 'open', so it could never be closed by any later run; it is
-- selected now. And a reopened period keeps status 'closed' (erp.reopen_period()
-- writes a reopening, not a status), so it is selected by identity rather than
-- by status.
--
-- ── 4. A RUN THAT STOPPED EARLY SAYS SO ──────────────────────────────────────
--
-- The reason this went unread for four days is that the trading phase catches
-- its own failure and the report reads the same either way: "traded … 0
-- document(s)" in the tone of a successful run. The report now carries
-- caught_up, stopped_on and traded_through, and .github/workflows/deploy.yml
-- reads them: an organisation that did not catch up is named as such on its
-- own line, in capitals, with its own ::warning:: and a line at the top of the
-- step summary. The frontier is how the phases after the trading know; these
-- are how a person does.
--
-- ── WHAT IT COSTS, ON A DATABASE WITH REAL HISTORY ───────────────────────────
--
-- This runs at deploy time over a bare connection, so both questions are asked
-- of it rather than of the build.
--
-- Cost: the reopening phase is one indexed read of erp.fiscal_period and one
-- insert per period it reopens, and on an organisation that is caught up it
-- selects nothing at all — every deploy after this one does no work here. The
-- re-close runs each reopened period's tasks again; the three ties are the
-- whole-organisation reconciliations 20260920300000 timed at 1,740 ms for 54
-- checks over three organisations, about 32 ms each, so demo-cbb10384's ten
-- wrongly-closed periods (five months on two ledgers) cost on the order of a
-- second, once. The close phase's own scan gains one comparison.
--
-- Context: erp.reopen_period() asks erp.authorise('finance.reopen_period') and
-- erp.current_principal_id(), which is the same principal the phase that
-- closes already acts as — no context the deploy's connection does not have,
-- provided the administrator it acts as holds that permission. So
-- erp.catch_up_demonstrations() now requires it of the person it picks, rather
-- than discovering halfway through a repair that it cannot finish one.
--
-- ── PROOF ─────────────────────────────────────────────────────────────────────
--
-- erp_test.demonstration_close_frontier_suite(): a demonstration whose trading
-- refuses. The close closes nothing past the frontier — the months after the
-- last built day stay open, which is the state that used to be created and
-- then had to be repaired — and the run is distinguishable afterwards from one
-- that worked: caught_up false and stopped_on naming the day, then true and
-- null once the trading can run.
--
-- erp_test.demonstration_reopen_suite(): a demonstration in demo-cbb10384's
-- exact shape, built by closing months beyond its frontier by hand, through
-- the doors, the way the old close did. The catch-up reopens exactly those
-- months and not the ones traded before them, trades through to today, closes
-- them again, and every tie task of a reopened period was completed AFTER the
-- close it is being re-closed over — which is the difference between the ties
-- being re-run against the new figures and being taken on trust.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The catch-up: reopen what was closed too soon, trade, then close what was
--    traded
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
  -- The last day the builder has actually built. Everything the close does is
  -- measured against it (20260921110000).
  v_frontier date;
  v_cursor   date;
  v_today    date;
  v_res      jsonb;
  v_built    integer := 0;
  v_calls    integer := 0;
  v_billed   integer := 0;
  v_unbilled integer := 0;
  v_closed   integer := 0;
  v_stuck    integer := 0;
  v_reopened uuid[] := '{}'::uuid[];
  v_stopped  text;
  v_stopped_on date;
  v_notes    jsonb := '[]'::jsonb;
  g          record;
  p          record;
  k          record;
  r          record;
begin
  select t.code into v_code from erp.tenant t where t.id = v_tenant;

  -- Load-bearing, and the reason a deploy is allowed to reopen anything here
  -- at all (20260921110000). Both halves: the name says it is a demonstration
  -- and the environment says it is not live.
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
                   'trading, made-up supplier bills, months closed on nobody''s '
                   'say-so and months reopened on nobody''s say-so do not belong '
                   'in a real company''s books.';
  end if;

  -- The day the builder has reached, before this run adds to it.
  select max(to_date(substring(d.their_reference from 6 for 8), 'YYYYMMDD'))
    into v_last
    from erp.document d
   where d.tenant_id = v_tenant
     and d.their_reference ~ '^DEMO-[0-9]{8}-';
  v_frontier := v_last;

  -- ── The months a close ran on before the trading reached them ──────────────
  --
  -- Narrow on purpose: ends_on > the frontier is exactly the set the close
  -- should never have touched — the months after the last built day, and the
  -- part-traded month the last built day falls in. A month that ends on or
  -- before the frontier was traded and was closed legitimately; nothing here
  -- goes near it. starts_on <= today keeps it to months that stand in the way
  -- of catching up. 'closed' and not 'permanently_closed': a year closed for
  -- good is not reopened, and erp.reopen_period() would refuse it anyway.
  begin
    if v_last is not null then
      for r in select fp.id, fp.code, l.code as ledger
                 from erp.fiscal_period fp
                 join erp.ledger l
                   on l.tenant_id = fp.tenant_id and l.id = fp.ledger_id
                where fp.tenant_id = v_tenant
                  and fp.status = 'closed'::erp.period_status
                  and fp.ends_on > v_last
                  and fp.starts_on <= current_date
                order by fp.starts_on, l.code
      loop
        begin
          perform erp.reopen_period(r.id, format(
            'Reopened by the demonstration catch-up to finish trading it. %s was closed by a '
            'catch-up whose close ran on months its trading had never reached: nothing had been '
            'built past %s. It is closed again in the same run, once its trading is done and '
            'every close check has been run again against the figures that trading leaves.',
            r.code, v_last));
          v_reopened := v_reopened || r.id;
        exception when others then
          v_notes := v_notes || to_jsonb(format(
            '%s of the %s ledger could not be reopened, so it cannot be traded. %s',
            r.code, r.ledger, sqlerrm));
        end;
      end loop;

      if coalesce(array_length(v_reopened, 1), 0) > 0 then
        v_notes := v_notes || to_jsonb(format(
          '%s month(s) that were closed past %s, the last day built, were reopened to be traded and closed again.',
          array_length(v_reopened, 1), v_last));
      end if;
    end if;
  exception when others then
    v_reopened := '{}'::uuid[];
    v_notes := v_notes || to_jsonb(format(
      'Its months were left as they were, because reopening one refused. %s', sqlerrm));
  end;

  -- ── Trading, up to the day this runs ───────────────────────────────────────
  --
  -- current_date and not erp.local_today(): the builder clamps its own end to
  -- current_date, so a bound past that one would only buy a call that builds
  -- nothing.
  begin
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
          v_stopped_on := v_cursor;
        end;
        exit catching_up when v_stopped is not null;

        v_built := v_built + coalesce((v_res ->> 'built')::integer, 0);
        v_calls := v_calls + 1;
        -- What the close is allowed to close, moved forward by what this call
        -- actually built rather than by what it was asked to build.
        v_frontier := greatest(v_frontier,
                               coalesce((v_res ->> 'built_through')::date, v_frontier));
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
    -- exists — and so does the frontier, or the close would close months whose
    -- trading has just been rolled back out from under it.
    v_built := 0; v_calls := 0; v_frontier := v_last;
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

  -- ── The months whose trading is finished ───────────────────────────────────
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
                -- A period this run reopened keeps status 'closed', because
                -- erp.reopen_period() writes a reopening and not a status, so
                -- it is selected by identity. 'closing' is a close somebody
                -- started and did not finish: a phase that looked only for
                -- 'open' could never finish one.
                and (fp.status in ('open'::erp.period_status, 'closing'::erp.period_status)
                     or fp.id = any (v_reopened))
                and fp.ends_on < date_trunc('month', v_today)::date
                -- The close follows the trading (20260921110000). A month the
                -- builder has not finished is not a month anybody closes, and
                -- this is what stops a run that built nothing from sealing the
                -- months the next run needs to build into.
                and fp.ends_on <= v_frontier
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
        --
        -- For a period this run reopened, a task already complete was completed
        -- against figures that months of new trading have since changed, and
        -- erp.close_period() would take it on trust. Every such task is
        -- completed again, which re-runs its check against the figures the
        -- trading leaves. A waived task is somebody's recorded judgement and is
        -- left as it is.
        for k in select ct.id
                   from erp.close_task ct
                  where ct.tenant_id = v_tenant
                    and ct.fiscal_period_id = p.id
                    and (ct.status not in ('complete', 'waived')
                         or (ct.status = 'complete' and p.id = any (v_reopened)))
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
    -- What it actually reached, which is not the same claim as what it was
    -- asked to reach, and is what the close measured itself against.
    'traded_through',   v_frontier,
    -- Said outright, so a run that stopped is not read as one that worked. The
    -- builder makes no document on a day it has nothing to make one for, so
    -- yesterday counts as caught up, the way supabase/ci/demonstration_catch_up.sh
    -- has always counted it.
    'caught_up',        coalesce(v_stopped is null and v_frontier >= current_date - 1, false),
    'stopped_on',       v_stopped_on,
    'documents_built',  v_built,
    'calls',            v_calls,
    'bills_raised',     v_billed,
    'receipts_unbilled', v_unbilled,
    'periods_reopened', coalesce(array_length(v_reopened, 1), 0),
    'periods_closed',   v_closed,
    'periods_left_open', v_stuck,
    'notes',            v_notes);
end;
$$;

comment on function erp.demonstration_catch_up() is
  'Brings one demonstration organisation up to today: reopens the months a '
  'close ran on before its trading ever reached them, trades forward from the '
  'last day its builder built, bills the goods it received and never billed, '
  'and closes the months whose trading is finished — re-running every close '
  'check of a month it reopened against the figures the new trading leaves. '
  'Closes nothing past the day the builder reached. Refuses any organisation '
  'that is not a demonstration or whose environment is live, which is what '
  'makes the reopening permissible at all. Says whether it caught up. Safe to '
  'run twice.';

revoke all on function erp.demonstration_catch_up() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The caller asks for the permission the repair needs
-- ═════════════════════════════════════════════════════════════════════════════
--
-- An organisation whose administrator cannot reopen a period is left alone
-- rather than acted on half way: the trading would refuse on the first closed
-- month and the run would report nothing built, which is where this started.
-- Everything else about the caller is 20260920400000's and is restated only
-- because the array is a constant in its body.

create or replace function erp.catch_up_demonstrations(p_code text default null)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  -- What erp.demonstration_catch_up() needs of the person it acts as. An
  -- organisation whose administrator does not hold all of these is left alone
  -- rather than acted on by the deploy's own role, which holds nothing and
  -- would prove nothing. finance.reopen_period joined them on 20260921110000,
  -- when the catch-up gained the repair that needs it.
  v_needs  constant text[] := array[
    'master_data.write', 'administration.configure', 'administration.promote',
    'finance.post', 'finance.close_period', 'finance.reopen_period',
    'procurement.match'];
  t        record;
  v_admin  uuid;
  v_out    jsonb := '[]'::jsonb;
begin
  for t in select tn.id, tn.code from erp.tenant tn
            where tn.code like 'demo-%'
              and tn.status = 'active'::erp.tenant_status
              and (p_code is null or tn.code = p_code)
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
        v_out := v_out || jsonb_build_array(jsonb_build_object(
          'organisation', t.code,
          'notes', jsonb_build_array(format(
            'Nobody signed in there holds all of %s, so it was left as it was.',
            array_to_string(v_needs, ', ')))));
        continue;
      end if;

      -- The person, because the work is authorised to somebody and
      -- erp.authorise() reads a principal. Transaction-local, the way
      -- supabase/ci/close_month.sh and supabase/ci/seed_demo.sql do it.
      perform set_config('request.jwt.claims',
                         json_build_object('sub', v_admin)::text, true);

      -- And the organisation, said outright. On a connection whose role has
      -- rolbypassrls — which the deploy's has and the application's has not —
      -- this answers erp.current_tenant_id() by itself, so a trigger that
      -- reaches for an organisation still finds one even where no person is
      -- resolvable.
      perform set_config('erp.job_tenant_id', t.id::text, true);

      -- The context that administrator actually resolves to is the one this
      -- writes in. Somebody who belongs to two organisations would otherwise
      -- carry this work into whichever one the database picked, and a
      -- demonstration repair has no business anywhere it was not aimed.
      if erp.current_tenant_id() is distinct from t.id then
        v_out := v_out || jsonb_build_array(jsonb_build_object(
          'organisation', t.code,
          'notes', jsonb_build_array(
            'Signing in as its administrator resolves to another organisation, so nothing was done there.')));
        continue;
      end if;

      v_out := v_out || jsonb_build_array(erp.demonstration_catch_up());

      -- Here, and not at commit. erp.journal's number and both balance checks
      -- are constraint triggers that are initially deferred, so a journal
      -- written above is numbered at the end of the transaction — by which time
      -- this loop has moved on and, on the old code, had put the context back.
      -- Draining the queue while this organisation's context is still in force
      -- numbers its journals under it, which is the answer whether there is one
      -- demonstration or four.
      set constraints all immediate;

    exception when others then
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'organisation', t.code,
        'notes', jsonb_build_array(format(
          'It was left as it was, because bringing it up to date refused. %s', sqlerrm))));
    end;
  end loop;

  -- The invariant the first version broke, written down: nothing may be left to
  -- fire when the context goes. Cheap when the loop has already drained, and
  -- the only thing standing between a future caller and the same failure.
  set constraints all immediate;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('erp.job_tenant_id', '', true);
  return v_out;
end;
$$;

comment on function erp.catch_up_demonstrations(text) is
  'Brings every demonstration organisation up to today, as an administrator of '
  'each and in that organisation''s own context, and answers with what each one '
  'did. Acts only as somebody holding everything the catch-up needs, reopening '
  'a period included (20260921110000). Drains the deferred constraint queue '
  'before it gives the context back, because erp.journal is numbered at commit. '
  'Raises nothing: an organisation that refuses is reported and the next one is '
  'tried. The deploy calls it with no argument, over a connection that arrives '
  'with nothing set.';

revoke all on function erp.catch_up_demonstrations(text) from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Proof — the close never closes past the trading, and a run that stopped
--    says so
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The trading is made to refuse by taking master_data.write off every role,
-- which is the permission erp.seed_demo_history() asks for before it builds
-- anything and before it configures anything. It has nothing to do with
-- periods, so the reopening phase cannot rescue it and what is measured is the
-- close's own scope. Giving the grant back and running again is the other half
-- of the claim: the two runs are told apart by the report itself, not by
-- reading the notes underneath it.

create or replace function erp_test.demonstration_close_frontier_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases   integer := 0;
  v_tenant  uuid; v_admin uuid; v_token text;
  v_auth    constant uuid := '00000000-0000-4000-8000-00000000f0a1';
  v_from    date;
  v_roles   uuid[];
  v_stopped jsonb; v_worked jsonb;
  v_sealed_past integer; v_open_after integer;
  v_fixture text;
begin
  begin
  select t.tenant_id, t.admin_user_id, t.admin_token
    into v_tenant, v_admin, v_token
    from erp.provision_tenant('demo-zzfrontier', 'Close frontier suite',
                              'admin@demo-zzfrontier.test', 'Frontier Admin') t;
  insert into auth.users (id, email) values (v_auth, 'admin@demo-zzfrontier.test');
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_auth)::text, true);
  perform erp.claim_invitation(v_token);
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  perform erp.ensure_demo_configuration(v_tenant, v_admin);

  -- The Monday of three weeks ago, and only that day: p_to = p_from limits
  -- erp.seed_demo_history() to one day (v_end := least(v_from + 4, v_to)), so
  -- the frontier is a known date rather than whatever a five-day slice reached.
  v_from := date_trunc('week', (current_date - 20)::timestamp)::date;
  perform erp.seed_demo_history(v_from, v_from, 1);
  set constraints all immediate;

  -- ── 1. Its trading cannot run ──────────────────────────────────────────────
  v_cases := v_cases + 1;
  select array_agg(distinct rp.role_id) into v_roles
    from erp.role_permission rp
   where rp.tenant_id = v_tenant and rp.permission_code = 'master_data.write';
  delete from erp.role_permission rp
   where rp.tenant_id = v_tenant and rp.permission_code = 'master_data.write';

  case_name := 'the demonstration has built one day, and the permission its builder asks for before it builds anything has been taken away';
  passed := coalesce(array_length(v_roles, 1), 0) > 0
        and not exists (select 1 from erp.role_permission rp
                         where rp.tenant_id = v_tenant
                           and rp.permission_code = 'master_data.write')
        and exists (select 1 from erp.document d
                     where d.tenant_id = v_tenant and d.their_reference like 'DEMO-%');
  detail := format('built %s and nothing after it; master_data.write withdrawn from %s role(s)',
                   v_from, coalesce(array_length(v_roles, 1), 0));
  return next;

  -- ── 2. It stops, and the report says so without anybody reading a note ────
  v_cases := v_cases + 1;
  v_stopped := erp.demonstration_catch_up();
  case_name := 'a run whose trading stopped answers caught_up false and names the day it stopped on, so it cannot be read as a run that worked';
  passed := (v_stopped ->> 'caught_up')::boolean = false
        and (v_stopped ->> 'stopped_on')::date = v_from + 1
        and (v_stopped ->> 'traded_through')::date = v_from
        and (v_stopped ->> 'documents_built')::integer = 0;
  detail := format('caught_up %s, stopped_on %s, traded_through %s, %s document(s)',
                   v_stopped ->> 'caught_up', coalesce(v_stopped ->> 'stopped_on', '(none)'),
                   v_stopped ->> 'traded_through', v_stopped ->> 'documents_built');
  return next;

  -- ── 3. And it closed nothing the builder had not reached ──────────────────
  -- This is the state the old close created and which then had to be repaired:
  -- the months after the last built day are still open, so the next run can
  -- build into them.
  v_cases := v_cases + 1;
  select count(*) into v_sealed_past
    from erp.fiscal_period fp
   where fp.tenant_id = v_tenant
     and fp.status in ('closing'::erp.period_status, 'closed'::erp.period_status,
                       'permanently_closed'::erp.period_status)
     and fp.ends_on > v_from;
  select count(*) into v_open_after
    from erp.fiscal_period fp
   where fp.tenant_id = v_tenant
     and fp.status = 'open'::erp.period_status
     and fp.ends_on > v_from;
  case_name := 'no period ending after the last day built was closed, so the months the next run has to build into are still open';
  passed := v_sealed_past = 0 and v_open_after > 0;
  detail := format('%s period(s) ending after %s are closed or closing, %s are still open',
                   v_sealed_past, v_from, v_open_after);
  return next;

  -- ── 4. Given the grant back, the same run is told apart from that one ─────
  v_cases := v_cases + 1;
  insert into erp.role_permission (tenant_id, role_id, permission_code, data_classes)
  select v_tenant, x, 'master_data.write', '{}' from unnest(v_roles) x
  on conflict do nothing;
  v_worked := erp.demonstration_catch_up();
  case_name := 'with the grant back it catches up and answers caught_up true with no day to name, so the two runs differ in the report and not only in the notes';
  passed := (v_worked ->> 'caught_up')::boolean = true
        and v_worked ->> 'stopped_on' is null
        and (v_worked ->> 'traded_through')::date >= current_date - 1
        and (v_worked ->> 'documents_built')::integer > 0
        and (v_stopped ->> 'caught_up') <> (v_worked ->> 'caught_up');
  detail := format('caught_up %s, stopped_on %s, traded_through %s, %s document(s), %s month(s) closed',
                   v_worked ->> 'caught_up', coalesce(v_worked ->> 'stopped_on', '(none)'),
                   v_worked ->> 'traded_through', v_worked ->> 'documents_built',
                   v_worked ->> 'periods_closed');
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_fixture := left(sqlerrm, 300);
    end if;
  end;

  v_cases := v_cases + 1;
  case_name := 'the fixture was undone, and nothing in it stopped early';
  passed := not exists (select 1 from erp.tenant where code = 'demo-zzfrontier')
        and not exists (select 1 from auth.users where id = v_auth)
        and v_fixture is null;
  detail := coalesce('the fixture stopped early: ' || v_fixture,
                     'demo-zzfrontier rolled back with its trading and its periods');
  return next;

  if v_cases <> 5 then
    raise exception
      'CLOVEERP_SUITE_SHRANK: demonstration_close_frontier_suite ran % cases, expected 5%',
      v_cases, coalesce(' — the fixture stopped early: ' || v_fixture, '');
  end if;
end;
$$;

revoke all on function erp_test.demonstration_close_frontier_suite() from public, anon;

create or replace function erp_test.assert_demonstration_close_frontier_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _demo_close_frontier on commit drop as
    select * from erp_test.demonstration_close_frontier_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _demo_close_frontier;
  drop table _demo_close_frontier;
  if v_fail > 0 then
    raise exception E'CLOVEERP_DEMONSTRATION_CLOSE_FRONTIER_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> 5 then
    raise exception 'CLOVEERP_SUITE_SHRANK: demonstration_close_frontier_suite ran % cases, expected 5', v_all;
  end if;
  return format('the close closes nothing the trading has not reached, and a run that stopped says so: %s/%s cases passed',
                v_all, v_all);
end;
$$;

revoke all on function erp_test.assert_demonstration_close_frontier_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Proof — a demonstration whose months were closed past its trading
-- ═════════════════════════════════════════════════════════════════════════════
--
-- demo-cbb10384's shape, built by hand because the routine can no longer
-- produce it: one day built about three months back, and then every month
-- before this one closed through the doors, the way the old close did. Some of
-- those months end after the day that was built — those are the damage — and
-- the rest end before it and were closed legitimately.
--
-- How the re-close is proved. erp.complete_close_task() stamps completed_at
-- with now(), which is the TRANSACTION's timestamp and is therefore the same
-- value throughout a suite: a later completion cannot be told from an earlier
-- one by its clock. So every close task is stamped back to the epoch by hand
-- once the fixture's closes are done, and what is asserted afterwards is that
-- the stamp was overwritten. It can only have been overwritten by
-- erp.complete_close_task() running again, and that routine writes the row
-- only after its blocking check has passed — so an overwritten stamp is
-- evidence the check ran against the figures the new trading left. The months
-- that were not reopened keep their epoch stamp, which is the negative half of
-- the same claim.

create or replace function erp_test.demonstration_reopen_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases    integer := 0;
  v_tenant   uuid; v_admin uuid; v_token text;
  v_auth     constant uuid := '00000000-0000-4000-8000-00000000e0b2';
  v_epoch    constant timestamptz := timestamptz '1970-01-01 00:00:00+00';
  v_from     date;
  v_report   jsonb;
  v_beyond   uuid[] := '{}'::uuid[];
  v_before   uuid[] := '{}'::uuid[];
  v_reopenings_beyond integer; v_reopenings_before integer;
  v_closed_beyond integer; v_still_open integer; v_docs_after integer;
  v_ties_rerun integer; v_ties_total integer; v_before_rerun integer;
  v_ok boolean; v_msg text; v_fixture text;
  q          record;
  k          record;
begin
  begin
  select t.tenant_id, t.admin_user_id, t.admin_token
    into v_tenant, v_admin, v_token
    from erp.provision_tenant('demo-zzreopen', 'Reopen suite',
                              'admin@demo-zzreopen.test', 'Reopen Admin') t;
  insert into auth.users (id, email) values (v_auth, 'admin@demo-zzreopen.test');
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_auth)::text, true);
  perform erp.claim_invitation(v_token);
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  perform erp.ensure_demo_configuration(v_tenant, v_admin);
  perform erp.configure_period_close();

  -- One day, about three months back, so that whole months lie between it and
  -- this one — which is what demo-cbb10384 has and what a three-week gap would
  -- not produce.
  v_from := date_trunc('week', (current_date - 80)::timestamp)::date;
  perform erp.seed_demo_history(v_from, v_from, 1);
  set constraints all immediate;

  -- ── 1. The damage the old close did, reproduced through the doors ─────────
  v_cases := v_cases + 1;
  for q in select fp.id, fp.ends_on
             from erp.fiscal_period fp
            where fp.tenant_id = v_tenant
              and fp.status = 'open'::erp.period_status
              and fp.ends_on < date_trunc('month', current_date)::date
            order by fp.ends_on
  loop
    perform erp.open_period_close(q.id);
    -- In the checklist's own order: erp.complete_close_task() refuses a task
    -- whose predecessor is open, so this cannot be a set-returning call.
    for k in select ct.id from erp.close_task ct
              where ct.tenant_id = v_tenant and ct.fiscal_period_id = q.id
                and ct.status not in ('complete', 'waived')
              order by ct.seq, ct.code
    loop
      perform erp.complete_close_task(k.id, null);
    end loop;
    perform erp.close_period(q.id);
    if q.ends_on > v_from then
      v_beyond := v_beyond || q.id;   -- closed past the trading: the damage
    else
      v_before := v_before || q.id;   -- traded, and closed legitimately
    end if;
  end loop;

  -- Stamped back so that a completion after this one can be seen at all.
  update erp.close_task ct set completed_at = v_epoch
   where ct.tenant_id = v_tenant
     and ct.fiscal_period_id = any (v_beyond || v_before);

  case_name := 'every month before this one is closed, including months ending after the last day built, which is the state the old close left behind';
  passed := coalesce(array_length(v_beyond, 1), 0) > 0
        and coalesce(array_length(v_before, 1), 0) > 0
        and not exists (select 1 from erp.fiscal_period fp
                         where fp.tenant_id = v_tenant
                           and fp.status = 'open'::erp.period_status
                           and fp.ends_on < date_trunc('month', current_date)::date);
  detail := format('%s month(s) closed past %s, %s closed up to it, none left open behind this month',
                   coalesce(array_length(v_beyond, 1), 0), v_from,
                   coalesce(array_length(v_before, 1), 0));
  return next;

  -- ── 2. The catch-up reopens exactly the months closed past the trading ────
  v_report := erp.demonstration_catch_up();

  v_cases := v_cases + 1;
  select count(*) into v_reopenings_beyond
    from erp.period_reopening pr
   where pr.tenant_id = v_tenant and pr.fiscal_period_id = any (v_beyond);
  select count(*) into v_reopenings_before
    from erp.period_reopening pr
   where pr.tenant_id = v_tenant and pr.fiscal_period_id = any (v_before);
  case_name := 'it reopened every month that had been closed past the last day built, and not one of the months that were traded before it';
  passed := v_reopenings_beyond = coalesce(array_length(v_beyond, 1), 0)
        and v_reopenings_before = 0
        and (v_report ->> 'periods_reopened')::integer = coalesce(array_length(v_beyond, 1), 0);
  detail := format('%s reopening(s) across the %s month(s) closed too soon, %s across the %s closed legitimately; the report says %s',
                   v_reopenings_beyond, coalesce(array_length(v_beyond, 1), 0),
                   v_reopenings_before, coalesce(array_length(v_before, 1), 0),
                   v_report ->> 'periods_reopened');
  return next;

  -- ── 3. It traded through them and closed them again ───────────────────────
  v_cases := v_cases + 1;
  select count(*) into v_closed_beyond
    from erp.fiscal_period fp
   where fp.tenant_id = v_tenant and fp.id = any (v_beyond)
     and fp.status = 'closed'::erp.period_status;
  select count(*) into v_still_open
    from erp.fiscal_period fp
   where fp.tenant_id = v_tenant
     and fp.status = 'open'::erp.period_status
     and fp.ends_on < date_trunc('month', erp.local_today())::date;
  select count(*) into v_docs_after
    from erp.document d
   where d.tenant_id = v_tenant and d.their_reference like 'DEMO-%'
     and d.document_date > v_from;
  case_name := 'it traded through the months it reopened and closed every one of them again, with nothing left open behind this month';
  passed := (v_report ->> 'caught_up')::boolean = true
        and (v_report ->> 'documents_built')::integer > 0
        and v_docs_after > 0
        and v_closed_beyond = coalesce(array_length(v_beyond, 1), 0)
        and v_still_open = 0;
  detail := format('caught_up %s, %s document(s) built, %s dated after %s; %s of %s reopened month(s) closed again, %s historic month(s) still open',
                   v_report ->> 'caught_up', v_report ->> 'documents_built', v_docs_after,
                   v_from, v_closed_beyond, coalesce(array_length(v_beyond, 1), 0), v_still_open);
  return next;

  -- ── 4. And the re-close was not a formality ───────────────────────────────
  v_cases := v_cases + 1;
  select count(*) filter (where ct.completed_at > v_epoch), count(*)
    into v_ties_rerun, v_ties_total
    from erp.close_task ct
   where ct.tenant_id = v_tenant
     and ct.fiscal_period_id = any (v_beyond)
     and not ct.is_waivable;
  select count(*) into v_before_rerun
    from erp.close_task ct
   where ct.tenant_id = v_tenant
     and ct.fiscal_period_id = any (v_before)
     and ct.completed_at > v_epoch;
  case_name := 'every tie of a reopened month was completed again, so its check ran against the figures the new trading left; the months that were not reopened were not touched';
  passed := v_ties_total > 0
        and v_ties_rerun = v_ties_total
        and v_before_rerun = 0;
  detail := format('%s of %s unwaivable tie task(s) on the reopened months were completed again; %s task(s) on the months closed legitimately were touched',
                   v_ties_rerun, v_ties_total, v_before_rerun);
  return next;

  -- ── 5. And the books still tie ────────────────────────────────────────────
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
  case_name := 'after the reopening, the trading and the re-close, stock, inventory, the subledgers, the ageing and the trial balance all still agree';
  passed := v_ok;
  detail := v_msg;
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_fixture := left(sqlerrm, 300);
    end if;
  end;

  v_cases := v_cases + 1;
  case_name := 'the fixture was undone, and nothing in it stopped early';
  passed := not exists (select 1 from erp.tenant where code = 'demo-zzreopen')
        and not exists (select 1 from auth.users where id = v_auth)
        and v_fixture is null;
  detail := coalesce('the fixture stopped early: ' || v_fixture,
                     'demo-zzreopen rolled back with its trading, its reopenings and its closes');
  return next;

  if v_cases <> 6 then
    raise exception
      'CLOVEERP_SUITE_SHRANK: demonstration_reopen_suite ran % cases, expected 6%',
      v_cases, coalesce(' — the fixture stopped early: ' || v_fixture, '');
  end if;
end;
$$;

revoke all on function erp_test.demonstration_reopen_suite() from public, anon;

create or replace function erp_test.assert_demonstration_reopen_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _demo_reopen on commit drop as
    select * from erp_test.demonstration_reopen_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _demo_reopen;
  drop table _demo_reopen;
  if v_fail > 0 then
    raise exception E'CLOVEERP_DEMONSTRATION_REOPEN_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> 6 then
    raise exception 'CLOVEERP_SUITE_SHRANK: demonstration_reopen_suite ran % cases, expected 6', v_all;
  end if;
  return format('a demonstration closed past its trading reopens those months, trades them and closes them again on their own figures: %s/%s cases passed',
                v_all, v_all);
end;
$$;

revoke all on function erp_test.assert_demonstration_reopen_suite() from public, anon;


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

select erp_test.assert_demonstration_close_frontier_suite();
select erp_test.assert_demonstration_reopen_suite();
select erp_test.assert_demonstration_catch_up_suite();

select erp.assert_whole_database_reconciles();
select erp.assert_refusals_name_next_action();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
