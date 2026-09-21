set lock_timeout = '30s';

-- =============================================================================
-- 20260921130000  The catch-up finishes inside its own statement
-- -----------------------------------------------------------------------------
-- 20260921110000 applied and the demonstration moved: the catch-up ran for
-- 121.9 s where the run before it died after 5.4 s on CLOVEERP_PERIOD_CLOSED.
-- The frontier rule and the narrow reopening did what they were written to do.
-- Then the step failed on something else, and what it printed was a stack with
-- no error on the front of it:
--
--   ...values ( ... coalesce(p_document_date, erp.local_today(p_site_id)), ...
--   PL/pgSQL function erp.create_document(...) line 55 at SQL statement
--   PL/pgSQL function erp.open_document(...) line 42 at assignment
--   PL/pgSQL function erp.raise_customer_credit_note(...) line 71 at assignment
--   PL/pgSQL function erp.seed_demo_history(date,date,numeric) line 630 ...
--   PL/pgSQL function erp.demonstration_catch_up() line 126 at assignment
--   PL/pgSQL function erp.catch_up_demonstrations(text) line 80 at assignment
--
-- ── WHAT ACTUALLY REFUSED: NOTHING DID ───────────────────────────────────────
--
-- There is no business refusal here. The statement was CANCELLED:
--
--   ERROR: canceling statement due to statement timeout   (SQLSTATE 57014)
--
-- Three things say so and no other reading fits all three.
--
--   The clock. The step began its psql at 16:33:14.6 and reported failure at
--   16:35:16.5 — 121.9 s, which is two minutes and the connection. Live's own
--   deploy step for the assurance says in its warning text that a statement
--   timeout is configured there; this is that timeout, to the second.
--
--   The escape. The error came out through erp.catch_up_demonstrations(), and
--   it could only do that by passing TWO `exception when others` handlers: the
--   per-day one inside erp.demonstration_catch_up()'s trading loop and the
--   per-organisation one in the caller. PL/pgSQL's OTHERS does not catch
--   query_canceled — this repository wrote that down itself in 20260920250000
--   — so an ordinary refusal from erp.seed_demo_history() is caught and
--   recorded as a note, and cannot be what this was. Only a cancellation gets
--   out.
--
--   The shape of what survived. Every line the step printed is CONTEXT: the
--   tail of a `SQL statement "insert into erp.document …"` and then the
--   function stack. A cancellation prints exactly that after its ERROR line.
--   The credit note in the stack is not the cause; it is where the axe fell.
--
-- So the NOTICE the step quoted (CLOVEERP_COUNT_IN_PROGRESS) was incidental, as
-- suspected, and the credit note is innocent: the seeder reached one for the
-- first time because the trading finally got that far.
--
-- ── WHY THE STEP'S "NO STATEMENT TIMEOUT" WAS NOT TRUE ───────────────────────
--
-- .github/workflows/deploy.yml set `PGOPTIONS: -c statement_timeout=0` on the
-- step and its header said "No statement timeout". It never took. PGOPTIONS
-- travels in libpq's startup packet, and this deploy connects through the
-- SESSION POOLER — the secret is required to be the pooler URL, and a pooler
-- does not forward arbitrary startup options to the server. Even on a direct
-- connection a per-role `ALTER ROLE … SET statement_timeout` is applied after
-- the startup options and would override it. The setting looked set, was not,
-- and nothing said so until a statement ran long enough to be killed by the
-- limit it thought it had removed. That is the same shape as everything else
-- this week: a thing that is true of the build and not of production.
--
-- ── AND WHY IT WOULD NEVER HAVE CONVERGED ────────────────────────────────────
--
-- This is the part that matters more than the timeout. A cancelled statement
-- rolls back, so every one of those 121.9 s of trading was thrown away. The
-- next deploy would start from the same day, take the same two minutes, be
-- killed at the same place and throw the same work away — for ever. The
-- demonstration has about five months to build; no single statement under a
-- two-minute limit is ever going to contain that. It had to stop being one.
--
-- ── THE FIX: THE ROUTINE YIELDS BEFORE IT IS KILLED ──────────────────────────
--
-- erp.catch_up_deadline() reads the session's OWN statement_timeout and returns
-- a moment a fraction of the way into it, anchored on statement_timestamp() so
-- every organisation in one call shares one deadline rather than each getting a
-- fresh one. The trading loop stops at 60% of the limit and the billing and
-- closing loops at 80%, each recording where it got to. The statement then
-- returns normally, COMMITS what it built, and the next deploy carries on from
-- the new frontier — which is precisely what the frontier rule of 20260921110000
-- already made safe: the close closes only what the trading reached, so
-- stopping early leaves the months it has not reached open for the next run.
--
-- What it does NOT do is invent a limit where the session has none. If
-- statement_timeout is 0 or unset, erp.catch_up_deadline() returns null and
-- nothing yields — which is what every build does, so CI behaviour and every
-- existing suite are unchanged. The routine respects the limit it is given
-- rather than assuming one.
--
-- The deploy step is changed with it: it now sets statement_timeout with an
-- explicit SET, which a pooler cannot drop and a role setting cannot override,
-- and it sets it to five minutes rather than to nothing. Five minutes is a
-- deliberate, stated bound — the routine yields at three — instead of the
-- unbounded write transaction "no timeout" would have meant on a database with
-- a year of trading in it, had it ever worked.
--
-- ── SHOULD IT HAVE ESCAPED? YES, AND IT COULD NOT HAVE DONE OTHERWISE ────────
--
-- Asked because the three-phase design claims a refusal in one phase leaves the
-- others to run. That claim holds for refusals and cannot hold for a
-- cancellation: the statement is over, everything it did is rolled back, and a
-- handler that swallowed it into a note would be reporting work that no longer
-- exists — the same trap the trading phase already resets v_built and
-- v_frontier for. So a cancellation SHOULD abort loudly, and does. The header
-- of erp.demonstration_catch_up() now says that rather than leaving the reader
-- to infer a stronger promise than the code can keep.
--
-- ── WHAT IT COSTS ────────────────────────────────────────────────────────────
--
-- erp.catch_up_deadline() reads one setting and does one interval
-- multiplication. The checks added to the three loops are one comparison of
-- clock_timestamp() per iteration. Against a database with a year of trading
-- the change is a reduction: the work per statement is now bounded by the
-- session's own limit instead of running until something kills it.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. A deadline taken from the session's own limit
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.catch_up_deadline(p_fraction double precision)
returns timestamptz
language plpgsql
stable
set search_path = ''
as $$
declare
  v_raw   text;
  v_limit interval;
begin
  v_raw := current_setting('statement_timeout', true);
  if coalesce(btrim(coalesce(v_raw, '')), '') = '' then
    return null;
  end if;

  -- SHOW normalises the setting to a unit string ('2min', '0'), but a value
  -- this cannot read is a value it must not guess at.
  begin
    v_limit := v_raw::interval;
  exception when others then
    return null;
  end;

  -- The session says there is no limit, so there is no deadline. A routine that
  -- invented one here would be imposing a bound nobody asked for, and would
  -- change what every build does.
  if v_limit <= interval '0' then
    return null;
  end if;

  -- statement_timestamp() and not clock_timestamp(): the limit is measured from
  -- the start of the statement, so this is the same moment for every
  -- organisation the caller visits inside one call rather than a fresh
  -- allowance for each.
  return statement_timestamp() + (v_limit * p_fraction);
end;
$$;

revoke all on function erp.catch_up_deadline(double precision) from public, anon;

comment on function erp.catch_up_deadline(double precision) is
  'A moment a fraction of the way into the session''s own statement_timeout, '
  'measured from the start of the statement so that everything done in one '
  'call shares it. Null when the session has no limit, because a routine that '
  'invented one would be imposing a bound nobody asked for (20260921130000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The catch-up stops while it still can, and says so
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
  -- Where this statement has to stop, taken from the session's own limit
  -- (20260921130000). Null when there is no limit, and then nothing yields.
  v_trade_by  timestamptz := erp.catch_up_deadline(0.60);
  v_finish_by timestamptz := erp.catch_up_deadline(0.80);
  v_out_of_time boolean := false;
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
            'built past %s. It is closed again once its trading is done and every close check '
            'has been run again against the figures that trading leaves.',
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

  -- ── Trading, up to the day this runs or the time this statement has ────────
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
        -- Before the call rather than after it: a slice begun with seconds left
        -- is a slice the session's limit cancels, and a cancelled statement
        -- takes every day already built down with it (20260921130000).
        if v_trade_by is not null and clock_timestamp() >= v_trade_by then
          v_out_of_time := true;
          exit catching_up;
        end if;

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
      elsif v_out_of_time then
        v_notes := v_notes || to_jsonb(format(
          'It ran out of the time this statement is allowed and stopped at %s with the day '
          'after it unbuilt. Nothing is lost: the next deploy carries on from there.',
          v_frontier));
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
    --
    -- This handler catches a refusal. It cannot catch a cancellation:
    -- query_canceled is one of the two conditions PL/pgSQL's OTHERS does not
    -- take, and that is correct — the statement is over and everything it did
    -- is rolled back, so a note claiming otherwise would be a lie. The deadline
    -- above is what keeps the statement from reaching that point.
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
      exit when v_finish_by is not null and clock_timestamp() >= v_finish_by;
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

    if v_finish_by is not null and clock_timestamp() >= v_finish_by then
      v_out_of_time := true;
    end if;

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
      -- A month left open here is a month the next run closes: the frontier
      -- rule means it is still a month whose trading is finished then too.
      if v_finish_by is not null and clock_timestamp() >= v_finish_by then
        v_out_of_time := true;
        exit;
      end if;

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
    'caught_up',        coalesce(v_stopped is null and not v_out_of_time
                                 and v_frontier >= current_date - 1, false),
    -- Not the same thing as a refusal, and read differently by the deploy: it
    -- stopped because the statement is only allowed so long, it committed what
    -- it did, and the next run carries on (20260921130000).
    'ran_out_of_time',  v_out_of_time,
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
  'Closes nothing past the day the builder reached. Stops and commits before '
  'the session''s statement_timeout would cancel it, and says so, because a '
  'cancelled statement loses everything it did (20260921130000). Refuses any '
  'organisation that is not a demonstration or whose environment is live, '
  'which is what makes the reopening permissible at all. Safe to run twice.';

revoke all on function erp.demonstration_catch_up() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Proof — the deadline is the session's own, and a run that yields commits
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The arithmetic first, which is where the rule lives: a session with no limit
-- gets no deadline, and a session with one gets a fraction of it measured from
-- the start of the statement. Then one run that actually yields, under a limit
-- small enough to hit in a few seconds and large enough that nothing else in
-- the suite is at risk of being cancelled — what is asserted there is that it
-- stopped short, said so, and kept what it built.

create or replace function erp_test.catch_up_budget_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases    integer := 0;
  v_tenant   uuid; v_admin uuid; v_token text;
  v_auth     constant uuid := '00000000-0000-4000-8000-00000000bd47';
  v_was      text;
  v_none     timestamptz; v_some timestamptz;
  v_from     date;
  v_report   jsonb;
  v_docs     integer;
  v_frontier date;
  v_fixture  text;
begin
  begin
  v_was := current_setting('statement_timeout');

  -- ── 1. A session with no limit is given no deadline ────────────────────────
  v_cases := v_cases + 1;
  perform set_config('statement_timeout', '0', true);
  v_none := erp.catch_up_deadline(0.60);
  case_name := 'a session whose statement_timeout is 0 gets no deadline, so nothing yields and every build behaves as it did';
  passed := v_none is null;
  detail := format('erp.catch_up_deadline(0.60) answered %s under statement_timeout 0',
                   coalesce(v_none::text, 'null'));
  return next;

  -- ── 2. A session with one is given a fraction of it ────────────────────────
  v_cases := v_cases + 1;
  perform set_config('statement_timeout', '100s', true);
  v_some := erp.catch_up_deadline(0.60);
  case_name := 'a session with a limit is given a deadline a fraction of the way into it, measured from the start of the statement and not from now';
  -- A range and not an equality: an interval multiplied by a double precision
  -- fraction is not exact to the microsecond, and a guard that demands it would
  -- fail on arithmetic rather than on behaviour.
  passed := v_some is not null
        and v_some between statement_timestamp() + interval '59 seconds'
                       and statement_timestamp() + interval '61 seconds';
  detail := format('under a 100 s limit the 0.60 deadline is %s, and the statement began at %s',
                   v_some, statement_timestamp());
  return next;

  -- ── 3. Every organisation in one call shares the one deadline ──────────────
  v_cases := v_cases + 1;
  case_name := 'the deadline does not move between calls inside one statement, so a second organisation does not get a fresh allowance';
  passed := erp.catch_up_deadline(0.60) = v_some
        and erp.catch_up_deadline(0.80) between statement_timestamp() + interval '79 seconds'
                                            and statement_timestamp() + interval '81 seconds';
  detail := format('asked twice, the 0.60 deadline is still %s; the 0.80 one is %s',
                   erp.catch_up_deadline(0.60), erp.catch_up_deadline(0.80));
  return next;

  -- ── 4. A run that reaches its deadline stops short and keeps what it built ─
  -- Thirty seconds, so the trading yields at eighteen and the billing and
  -- closing at twenty-four, leaving six for the phases' own assertions and the
  -- return. Long enough that days are built first, short enough that the suite
  -- is not slow. If this ever IS cancelled the build fails loudly, which is the
  -- honest failure: it would mean the headroom the fractions leave is wrong,
  -- here and on live.
  select t.tenant_id, t.admin_user_id, t.admin_token
    into v_tenant, v_admin, v_token
    from erp.provision_tenant('demo-zzbudget', 'Catch-up budget suite',
                              'admin@demo-zzbudget.test', 'Budget Admin') t;
  insert into auth.users (id, email) values (v_auth, 'admin@demo-zzbudget.test');
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_auth)::text, true);
  perform erp.claim_invitation(v_token);
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  perform erp.ensure_demo_configuration(v_tenant, v_admin);

  -- A day a long way back, so there is far more to build than the budget allows.
  v_from := date_trunc('week', (current_date - 200)::timestamp)::date;
  perform erp.seed_demo_history(v_from, v_from, 1);
  set constraints all immediate;

  v_cases := v_cases + 1;
  perform set_config('statement_timeout', '30s', true);
  v_report := erp.demonstration_catch_up();
  perform set_config('statement_timeout', '0', true);

  select count(*) into v_docs
    from erp.document d
   where d.tenant_id = v_tenant and d.their_reference like 'DEMO-%'
     and d.document_date > v_from;
  select max(to_date(substring(d.their_reference from 6 for 8), 'YYYYMMDD'))
    into v_frontier
    from erp.document d
   where d.tenant_id = v_tenant and d.their_reference ~ '^DEMO-[0-9]{8}-';

  case_name := 'with two hundred days to build and thirty seconds to do it in, it stops part way, says it ran out of time rather than that anything refused, and keeps every day it built';
  passed := (v_report ->> 'ran_out_of_time')::boolean = true
        and (v_report ->> 'caught_up')::boolean = false
        and v_report ->> 'stopped_on' is null
        and (v_report ->> 'documents_built')::integer > 0
        and v_docs > 0
        and v_frontier > v_from
        and v_frontier < current_date - 1;
  detail := format('ran_out_of_time %s, caught_up %s, stopped_on %s; %s document(s) built, frontier moved from %s to %s',
                   v_report ->> 'ran_out_of_time', v_report ->> 'caught_up',
                   coalesce(v_report ->> 'stopped_on', '(none)'),
                   v_report ->> 'documents_built', v_from, v_frontier);
  return next;

  -- ── 5. And it closed nothing it had not traded ────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'a run that stopped part way still closed nothing past the day it reached, so the months it has not built into are open for the next one';
  passed := not exists (select 1 from erp.fiscal_period fp
                         where fp.tenant_id = v_tenant
                           and fp.status in ('closing'::erp.period_status,
                                             'closed'::erp.period_status)
                           and fp.ends_on > v_frontier);
  detail := format('no period ending after %s is closed or closing', v_frontier);
  return next;

  perform set_config('statement_timeout', v_was, true);
  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_fixture := left(sqlerrm, 300);
    end if;
    -- Whatever happened, the session is handed back as it was found.
    perform set_config('statement_timeout', coalesce(v_was, '0'), true);
  end;

  v_cases := v_cases + 1;
  case_name := 'the fixture was undone, the session''s own timeout was put back, and nothing in it stopped early';
  passed := not exists (select 1 from erp.tenant where code = 'demo-zzbudget')
        and not exists (select 1 from auth.users where id = v_auth)
        and current_setting('statement_timeout') = v_was
        and v_fixture is null;
  detail := coalesce('the fixture stopped early: ' || v_fixture,
                     format('demo-zzbudget rolled back; statement_timeout is %s, as it was',
                            current_setting('statement_timeout')));
  return next;

  if v_cases <> 6 then
    raise exception
      'CLOVEERP_SUITE_SHRANK: catch_up_budget_suite ran % cases, expected 6%',
      v_cases, coalesce(' — the fixture stopped early: ' || v_fixture, '');
  end if;
end;
$$;

revoke all on function erp_test.catch_up_budget_suite() from public, anon;

create or replace function erp_test.assert_catch_up_budget_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _catch_up_budget on commit drop as
    select * from erp_test.catch_up_budget_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _catch_up_budget;
  drop table _catch_up_budget;
  if v_fail > 0 then
    raise exception E'CLOVEERP_CATCH_UP_BUDGET_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> 6 then
    raise exception 'CLOVEERP_SUITE_SHRANK: catch_up_budget_suite ran % cases, expected 6', v_all;
  end if;
  return format('the catch-up stops inside the time its statement is allowed and keeps what it built: %s/%s cases passed',
                v_all, v_all);
end;
$$;

revoke all on function erp_test.assert_catch_up_budget_suite() from public, anon;

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
-- No suite is run from here: erp_test.assert_catch_up_budget_suite() builds an
-- organisation of its own and trades it, so its cost is its fixture's and not
-- the schema's, and 20260921120000 says where a suite like that belongs. The
-- catalogue picks it up by name and every build runs it.
--
-- What is below is the ordinary schema proof. Its cost is the size of the
-- schema, except erp.assert_whole_database_reconciles(), which grows with the
-- ledger and was timed on live at 1.7 s over three organisations.

select erp.assert_whole_database_reconciles();
select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
