-- The close is two presses: opening it runs the checks, closing it shuts
-- every ledger (PR12 M2, F1).
--
-- A month cost eight actions a ledger: open the close, tick six tasks, close
-- it. A company has two ledgers of the same months, GL and COMMIT, so a month
-- was sixteen, and nobody paid for the second eight: COMMIT was never closed.
-- The doors keep their names and their calls; what they do changes.
--
--   * erp.open_period_close(p) opens the close of p and of its siblings, the
--     periods of the same company with the same dates on its other active
--     statutory and management ledgers (D4), and raises the month's checklist
--     once, on p, or leaves it where a sibling already carries it. The six checks are questions about the whole organisation,
--     so a second copy on COMMIT would ask the same questions again and cost a
--     second waiver for every judgement. It runs each distinct check once, in
--     the checklist's order, and completes every task whose check passes and
--     whose predecessors are done, as the person who opened it (D5). A task
--     whose check fails, that has no check, or that waits on one that failed
--     is left open for erp.complete_close_task(), which is now the exception
--     door: a waiver, or a task nothing can check. Opening a period that
--     closed with a sibling is nothing to do.
--   * erp.close_period(p) runs the check of every completed task again,
--     because the six checks are questions about the whole organisation now,
--     not about the period, and the trading does not stop while a period is
--     closing (spec correction S3). A check that passed when its task was
--     completed and fails now refuses the close in the check's own words. A
--     waived task is a recorded judgement and is not asked again. Then it
--     closes p and every sibling on that checklist, with one timestamp (a
--     sibling's own checklist, where somebody raised one, must be finished
--     too): COMMIT closes with GL
--     from the next close onwards (D3), so a commitment dated into a closed
--     month is refused the way a journal is. A second close of a sibling that
--     closed with p is nothing to do, so a caller that closes ledger by
--     ledger, the demonstration's catch-up among them, still finishes green.
--   * Consolidation keeps its own close: a group ledger is nobody's sibling.
--     Tax and budget ledgers are not closed by a company's close either.
--
-- Two presses a month, from sixteen. Walked by erp_test.step_budget_suite
-- case 13 and proved by erp_test.period_close_suite.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. A period's siblings
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.period_siblings(p_fiscal_period_id uuid)
returns setof uuid
language sql
stable
security invoker
set search_path = ''
as $$
  -- The same company, the same dates, another active statutory or management
  -- ledger. Nothing for a period of a group, tax or budget ledger: a
  -- consolidation closes after its eliminations, on its own (D4).
  select s.id
    from erp.fiscal_period fp
    join erp.ledger l
      on l.tenant_id = fp.tenant_id and l.id = fp.ledger_id
    join erp.ledger sl
      on sl.tenant_id = l.tenant_id and sl.entity_id = l.entity_id
     and sl.id <> l.id
     and sl.status = 'active'
     and sl.ledger_kind in ('statutory', 'management')
    join erp.fiscal_period s
      on s.tenant_id = sl.tenant_id and s.ledger_id = sl.id
     and s.starts_on = fp.starts_on and s.ends_on = fp.ends_on
   where fp.tenant_id = erp.require_tenant_id()
     and fp.id = p_fiscal_period_id
     and l.ledger_kind in ('statutory', 'management')
   order by sl.code, s.id
$$;

revoke all on function erp.period_siblings(uuid) from public, anon, authenticated;

comment on function erp.period_siblings(uuid) is
  'The periods that close with this one: the same company, the same dates, on its other active '
  'statutory and management ledgers (GL and COMMIT). None for a period of a group, tax or budget '
  'ledger, whose close is its own (20260929200000, D4).';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Opening the close runs the checks
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Replaced whole, and only over the body 20260918400000 left: a door with the
-- period guard under it is not patched by a fragment.

do $anchor_open$
declare
  v_src text := (select p.prosrc from pg_catalog.pg_proc p
                  where p.oid = 'erp.open_period_close(uuid)'::regprocedure);
begin
  if position('erp.period_siblings(' in v_src) > 0 then
    raise notice 'erp.open_period_close(uuid) already runs the checks; replaced with the same body';
  elsif md5(v_src) <> '63ecc79a8d7d08b5582b78212c7a683f' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: erp.open_period_close(uuid) is not the body 20260918400000 left (md5 %)', md5(v_src);
  end if;
end
$anchor_open$;

create or replace function erp.open_period_close(p_fiscal_period_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  p         erp.fiscal_period%rowtype;
  v_set     uuid[];
  v_by      uuid;
  v_ran     jsonb := '{}'::jsonb;
  k         record;
  v_out     text;
  v_ok      boolean;
  v_n       integer;
  v_home    uuid;
begin
  perform erp.authorise('finance.close_period', null, null, null,
                        'fiscal_period', p_fiscal_period_id);

  select fp.* into p
    from erp.fiscal_period fp
   where fp.tenant_id = v_tenant
     and fp.id = p_fiscal_period_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_FISCAL_PERIOD: no period of this organisation has that identifier'
      using errcode = 'P0002',
            hint = 'Refresh the list of periods and choose again.';
  end if;

  if p.status = 'permanently_closed' then
    raise exception 'CLOVEERP_PERIOD_PERMANENTLY_CLOSED: % was closed for good at the end of its year', p.code
      using errcode = '23514',
            hint = 'A period of a closed year is neither closed again nor reopened. Post an adjustment in the current year.';
  end if;

  -- Closed, with a sibling or on its own, and not reopened since: there is
  -- nothing to open. It is not put back to closing either, which would take
  -- postings again with nobody's reopening on record. A caller that opens
  -- ledger by ledger reaches the second ledger of a month here.
  if not erp.period_accepts_postings(p.id) then
    return (select count(*)::integer from erp.close_task ct
             where ct.tenant_id = v_tenant and ct.fiscal_period_id = p.id);
  end if;

  -- This period, and its siblings that still take postings. A sibling closed
  -- before the siblings closed together is left as it was closed (D3).
  v_set := array[p.id] || coalesce(array(
             select s.id
               from erp.period_siblings(p.id) s(id)
              where erp.period_accepts_postings(s.id)), '{}'::uuid[]);

  -- Locked in one order, the month's every ledger, so an opening and a close
  -- of the same month from two of its ledgers queue rather than deadlock.
  perform 1 from erp.fiscal_period fp
   where fp.tenant_id = v_tenant and fp.id = any (v_set)
   order by fp.id
     for update;

  -- The month's checklist, raised once: where it already is, if a close of
  -- the month was opened from another of its ledgers, and otherwise on this
  -- period. Opened again, it raises nothing twice.
  select ct.fiscal_period_id into v_home
    from erp.close_task ct
   where ct.tenant_id = v_tenant and ct.fiscal_period_id = any (v_set)
   order by array_position(v_set, ct.fiscal_period_id)
   limit 1;
  v_home := coalesce(v_home, p.id);

  insert into erp.close_task (
    tenant_id, fiscal_period_id, code, name, seq, depends_on, blocking_check,
    is_waivable)
  select v_tenant, v_home, t.code, t.name, t.seq, t.depends_on,
         t.blocking_check, t.is_waivable
    from erp.close_task_template t
   where t.tenant_id = v_tenant and t.status = 'active'
  on conflict (tenant_id, fiscal_period_id, code) do nothing;

  select count(*) into v_n
    from erp.close_task ct
   where ct.tenant_id = v_tenant and ct.fiscal_period_id = v_home;

  if v_n = 0 then
    raise exception
      'CLOVEERP_NO_CLOSE_TEMPLATE: nothing to do at close, which is not the same '
      'as nothing to check'
      using errcode = '23503',
      hint = 'erp.configure_period_close() installs the tasks.';
  end if;

  -- Closing, and still taking postings, until the close. A reopened period
  -- keeps the status its reopening left it.
  update erp.fiscal_period fp set status = 'closing', updated_at = now()
   where fp.tenant_id = v_tenant and fp.id = any (v_set)
     and fp.status in ('future', 'open', 'closing');

  -- Every task that is waiting, in the checklist's order, so a predecessor is
  -- settled before the task that reads it: the month's checklist, and a
  -- second one where somebody raised one before the ledgers closed together. Each check is a question about the whole
  -- organisation, so each distinct one runs once however many checklists
  -- carry it (D5: the opener is who the checklist says did it).
  v_by := erp.current_principal_id();
  for k in
    select ct.id, ct.fiscal_period_id, ct.depends_on,
           nullif(btrim(coalesce(ct.blocking_check, '')), '') as check_call
      from erp.close_task ct
     where ct.tenant_id = v_tenant
       and ct.fiscal_period_id = any (v_set)
       and ct.status in ('open', 'blocked')
     order by ct.seq, ct.code, array_position(v_set, ct.fiscal_period_id)
  loop
    -- Nothing checks it: it is somebody's to tick.
    continue when k.check_call is null;

    -- It reads what its predecessors settled, and one of them is not.
    continue when exists (
      select 1 from erp.close_task d
       where d.tenant_id = v_tenant and d.fiscal_period_id = k.fiscal_period_id
         and d.code = any (k.depends_on)
         and d.status not in ('complete', 'waived'));

    if not v_ran ? k.check_call then
      begin
        execute format('select %s', k.check_call) into v_out;
        v_ran := v_ran || jsonb_build_object(k.check_call,
                   jsonb_build_object('ok', true, 'out', v_out));
      exception when others then
        v_ran := v_ran || jsonb_build_object(k.check_call,
                   jsonb_build_object('ok', false, 'out', sqlerrm));
      end;
    end if;

    v_ok := (v_ran -> k.check_call ->> 'ok')::boolean;
    continue when not v_ok;

    update erp.close_task ct
       set status = 'complete',
           completed_at = now(), completed_by = v_by,
           waiver_reason = null,
           check_output = v_ran -> k.check_call ->> 'out',
           updated_at = now()
     where ct.id = k.id;
  end loop;

  return v_n;
end;
$$;

revoke all on function erp.open_period_close(uuid) from public, anon;

comment on function erp.open_period_close(uuid) is
  'Opens the close of a period and of its siblings (erp.period_siblings: the same company and dates on '
  'its other statutory and management ledgers), raising the month''s checklist once (on this period, '
  'unless a sibling already carries it) and running each distinct check once, in order: every task whose '
  'check passes and whose predecessors are done is completed as the opener, with what the check said. A '
  'task that fails, has no check, or waits on one that failed stays open for erp.complete_close_task(). '
  'Returns the number of tasks on the month''s checklist; nothing to do for a period closed and not '
  'reopened since (20260929200000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Closing runs them again, and closes the siblings with it
-- ═════════════════════════════════════════════════════════════════════════════

do $anchor_close$
declare
  v_src text := (select p.prosrc from pg_catalog.pg_proc p
                  where p.oid = 'erp.close_period(uuid)'::regprocedure);
begin
  if position('erp.period_siblings(' in v_src) > 0 then
    raise notice 'erp.close_period(uuid) already closes the siblings; replaced with the same body';
  elsif md5(v_src) <> 'd7a0063ffbef60c612f7c345d781762f' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: erp.close_period(uuid) is not the body 20260914071000 left (md5 %)', md5(v_src);
  end if;
end
$anchor_close$;

create or replace function erp.close_period(p_fiscal_period_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  p        erp.fiscal_period%rowtype;
  v_set    uuid[];
  v_open   text;
  k        record;
  v_out    text;
  v_at     timestamptz;
begin
  perform erp.authorise('finance.close_period', null, null, null,
                        'fiscal_period', p_fiscal_period_id);

  select fp.* into p
    from erp.fiscal_period fp
   where fp.tenant_id = v_tenant
     and fp.id = p_fiscal_period_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_FISCAL_PERIOD: no period of this organisation has that identifier'
      using errcode = 'P0002',
            hint = 'Refresh the list of periods and choose again.';
  end if;

  if p.status = 'permanently_closed' then
    raise exception 'CLOVEERP_PERIOD_PERMANENTLY_CLOSED: % was closed for good at the end of its year', p.code
      using errcode = '23514',
            hint = 'A period of a closed year is neither closed again nor reopened. Post an adjustment in the current year.';
  end if;

  -- The siblings that still take postings close with it, on the month's
  -- checklist, and the month's every ledger is locked in one order so two
  -- closes of the same month queue rather than deadlock. The checks are the
  -- organisation's, not the ledger's.
  v_set := array[p.id] || coalesce(array(
             select s.id
               from erp.period_siblings(p.id) s(id)
              where erp.period_accepts_postings(s.id)), '{}'::uuid[]);
  perform 1 from erp.fiscal_period fp
   where fp.tenant_id = v_tenant and fp.id = any (v_set)
   order by fp.id
     for update;
  select fp.* into p
    from erp.fiscal_period fp
   where fp.tenant_id = v_tenant
     and fp.id = p_fiscal_period_id;

  -- Closed already, with a sibling or on its own, and nobody has reopened it
  -- since: there is nothing to do, and its closed_at stays the moment it
  -- closed.
  if p.status = 'closed' and not erp.period_accepts_postings(p.id) then
    return;
  end if;

  -- A month with no checklist has nothing saying it is ready to close. It is
  -- the month's: a close opened from COMMIT is closed from GL, and the other
  -- way round.
  if not exists (select 1 from erp.close_task t
                  where t.tenant_id = v_tenant and t.fiscal_period_id = any (v_set)) then
    raise exception 'CLOVEERP_CLOSE_NO_TASKS: % has no close tasks, so nothing says it is ready to close', p.code
      using errcode = '23514',
            hint = format('Open a period close for %s first: it raises the tasks that are done before the period shuts. If there are no tasks to raise, install Period close under Configuration.', p.code);
  end if;

  -- Every task on the month's checklist, and on a second one where somebody
  -- raised one before the ledgers closed together, is finished.
  select string_agg(t.name || case when t.fiscal_period_id = p.id then '' else ' (' || l.code || ')' end,
                    ', ' order by t.fiscal_period_id <> p.id, l.code, t.seq, t.code)
    into v_open
    from erp.close_task t
    join erp.fiscal_period fp on fp.tenant_id = t.tenant_id and fp.id = t.fiscal_period_id
    join erp.ledger l on l.tenant_id = fp.tenant_id and l.id = fp.ledger_id
   where t.tenant_id = v_tenant
     and t.fiscal_period_id = any (v_set)
     and t.status not in ('complete', 'waived');

  if v_open is not null then
    raise exception 'CLOVEERP_CLOSE_TASKS_OPEN: % still has close tasks open: %', p.code, v_open
      using errcode = '23514',
            hint = format('Complete %s, or waive a task with the reason it is passed, then close %s.', v_open, p.code);
  end if;

  -- Asked again. A task completed when the close was opened answered for that
  -- moment, and the period has taken postings since (S3). Each distinct check
  -- once; a waived task is somebody's recorded judgement and is not re-run.
  for k in
    select c.check_call,
           string_agg(distinct c.name, ', ') as tasks
      from (select nullif(btrim(coalesce(t.blocking_check, '')), '') as check_call,
                   t.name, t.seq
              from erp.close_task t
             where t.tenant_id = v_tenant
               and t.fiscal_period_id = any (v_set)
               and t.status = 'complete') c
     where c.check_call is not null
     group by c.check_call
     order by min(c.seq), c.check_call
  loop
    begin
      execute format('select %s', k.check_call) into v_out;
    exception when others then
      raise exception 'CLOVEERP_CLOSE_CHECK_FAILED: % — %', k.check_call, sqlerrm
        using errcode = '23514',
              detail = format('%s passed when it was completed and fails at the close of %s: something posted since.',
                              k.tasks, p.code),
              hint = 'Fix the difference the check names and close again, or, where the task is not one of the four '
                     'ties, waive it with a reason that will be read at audit and close again.';
    end;
  end loop;

  -- One moment for every ledger of the month, and the moment of closing
  -- rather than the start of the transaction: a reopening recorded before it
  -- no longer opens the period (erp.period_accepts_postings).
  v_at := clock_timestamp();
  update erp.fiscal_period fp
     set status = 'closed',
         closed_at = v_at,
         closed_by = erp.current_principal_id(),
         updated_at = now()
   where fp.tenant_id = v_tenant
     and fp.id = any (v_set);
end;
$$;

revoke all on function erp.close_period(uuid) from public, anon;

comment on function erp.close_period(uuid) is
  'Closes a period and its siblings (erp.period_siblings) on its checklist, with one timestamp, once '
  'every task on it (and on a sibling''s own, where one was raised) is complete or waived and the check of every completed task passes again, now. A waived '
  'task is not re-run. Nothing to do for a period already closed and not reopened since, so a close of '
  'a sibling that closed with it returns (20260929200000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The demonstration's catch-up, re-pinned on purpose
-- ═════════════════════════════════════════════════════════════════════════════
--
-- It closes ledger by ledger, and still finishes green: the second ledger of a
-- month closed with the first, and opening or closing it again is nothing to
-- do. Two things move. It reaches the primary ledger of each month first, so
-- the month's checklist lands on GL, where the close screen reads it, and not
-- on whichever ledger sorts first by code. And it opens every month it
-- closes, because opening a close that is already raised now raises nothing
-- twice and runs the checks; the guard that raised the tasks only once said
-- the opposite. The completion loop is kept as it is: what the opening left
-- open failed its check and says so there, and a month it reopened has its
-- completed tasks asked again.

do $catch_up$
declare
  v_sig constant text := 'erp.demonstration_catch_up()';
  v_def text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$              order by fp.ends_on, l.code
    loop
$o$,
    $n$              -- The primary ledger first, so the month's checklist is
              -- raised where the close screen reads it (20260929200000).
              order by fp.ends_on, l.is_primary desc, l.code
    loop
$n$,
    $o$        -- erp.open_period_close() refuses a period whose tasks are already
        -- raised, because its insert conflicts away to nothing and it reads
        -- that as an organisation with no template. Raise them once.
        if not exists (select 1 from erp.close_task ct
                        where ct.tenant_id = v_tenant
                          and ct.fiscal_period_id = p.id) then
          perform erp.open_period_close(p.id);
        end if;
$o$,
    $n$        -- Opening the close raises the month's checklist once, completes
        -- every task whose check passes, and opens the siblings with it; on a
        -- ledger that closed with its sibling it is nothing to do
        -- (20260929200000).
        perform erp.open_period_close(p.id);
$n$];
  v_hits integer;
begin
  if position('20260929200000' in v_def) > 0 then
    raise notice '% already opens every month it closes; left as it is', v_sig;
    return;
  end if;
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$catch_up$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Re-pinned on purpose: opening the close completes what passes
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Four suites pinned the checklist as the opening left it, every task open.
-- Opening now completes every task whose check passes, so each is re-pinned
-- where it read that, and says so. The refusals they prove are unchanged.

create or replace function erp_test.repin_close_suite(
  p_sig text, p_marker text, p_pairs text[])
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_def  text := pg_catalog.pg_get_functiondef(p_sig::regprocedure);
  v_hits integer;
begin
  -- Applied already: the marker is there.
  if position(p_marker in v_def) > 0 then
    return;
  end if;
  for v_i in 1 .. array_length(p_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, p_pairs[2*v_i - 1], ''))) / length(p_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', p_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, p_pairs[2*v_i - 1], p_pairs[2*v_i]);
  end loop;
  if position(p_marker in v_def) = 0 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % re-pinned without its marker %', p_sig, p_marker;
  end if;
  execute v_def;
end;
$$;

revoke all on function erp_test.repin_close_suite(text, text, text[]) from public, anon;

comment on function erp_test.repin_close_suite(text, text, text[]) is
  'Replaces each anchor of a suite''s body with its re-pin, refusing CLOVEERP_ANCHOR_MOVED unless each '
  'anchor is found exactly once; nothing to do once the marker is there. The re-pins of 20260929200000.';

-- erp_test.finance_depth_suite: opening raises six and, on its books, completes
-- all six as the opener. The exception door's refusals (a task before its
-- predecessor, a close with a task open) are then worked from the checklist as
-- it stood before the opening completed it.
select erp_test.repin_close_suite('erp_test.finance_depth_suite()', 'opening runs every check (20260929200000)', array[
$o$  v_n := erp.open_period_close(v_period);
  return query select 'opening a close raises the tasks from the template',
    v_n = 6
    and (select p.status::text from erp.fiscal_period p where p.id = v_period) = 'closing',
$o$,
$n$  v_n := erp.open_period_close(v_period);
  return query select 'opening a close raises the tasks from the template',
    v_n = 6
    and (select p.status::text from erp.fiscal_period p where p.id = v_period) = 'closing'
    -- And runs their checks: on these books all six pass, so all six are
    -- complete, as the opener. opening runs every check (20260929200000).
    and (select count(*) from erp.close_task ct
          where ct.fiscal_period_id = v_period and ct.status = 'complete'
            and ct.completed_by = erp.current_principal_id()
            and ct.check_output is not null) = 6,
$n$,
$o$  select ct.id into v_task from erp.close_task ct
   where ct.fiscal_period_id = v_period and ct.code = 'inventory_valued';
$o$,
$n$  -- The exception door, worked from the checklist as it stood before the
  -- opening completed it.
  update erp.close_task ct
     set status = 'open', completed_at = null, completed_by = null,
         check_output = null, updated_at = now()
   where ct.fiscal_period_id = v_period;

  select ct.id into v_task from erp.close_task ct
   where ct.fiscal_period_id = v_period and ct.code = 'inventory_valued';
$n$]);

-- erp_test.trial_balance_tie_suite: the subledgers tie passed when the close
-- was opened, so it is complete, and a waiver refused leaves it so.
select erp_test.repin_close_suite('erp_test.trial_balance_tie_suite()', 'as the opening left it (20260929200000)', array[
$o$          and (select t.status from erp.close_task t where t.id = v_task_sub) = 'open';
$o$,
$n$          -- Complete, as the opening left it (20260929200000): its check
          -- passed, and a refused waiver does not change it.
          and (select t.status from erp.close_task t where t.id = v_task_sub) = 'complete';
$n$]);

-- erp_test.ageing_tie_suite: the ageing tie passed when the close was opened
-- and was broken afterwards, which is the case the close asks again for
-- (erp_test.period_close_suite). A tick and a waiver are still refused, and
-- the task is left as the opening left it.
select erp_test.repin_close_suite('erp_test.ageing_tie_suite()', 'as the opening left it (20260929200000)', array[
$o$          and (select t.status from erp.close_task t where t.id = v_task_age) = 'open';
$o$,
$n$          -- Complete, as the opening left it (20260929200000), before the
          -- falsification; erp.close_period() runs the check again.
          and (select t.status from erp.close_task t where t.id = v_task_age) = 'complete';
$n$]);

-- erp_test.close_and_ties_read_suite: its books break two ties, so the
-- checklist is still in progress after opening; what is open is what failed,
-- or waits on what failed.
select erp_test.repin_close_suite('erp_test.close_and_ties_read_suite()', 'what the opening left open (20260929200000)', array[
$o$          and (v_res ->> 'open_tasks')::integer = v_tmpl
$o$,
$n$          -- Fewer than all of them: what the opening left open (20260929200000)
          -- is what failed its check or waits on one that did.
          and (v_res ->> 'open_tasks')::integer =
              (select count(*) from erp.close_task ct
                where ct.tenant_id = v_tenant and ct.fiscal_period_id = v_period and ct.status = 'open')
          and (v_res ->> 'open_tasks')::integer between 1 and v_tmpl - 1
$n$,
$o$          and (v_res ->> 'open_tasks')::integer = v_tmpl - 1, false);
$o$,
$n$          and (v_res ->> 'open_tasks')::integer =
              (select count(*) from erp.close_task ct
                where ct.tenant_id = v_tenant and ct.fiscal_period_id = v_period and ct.status = 'open'), false);
$n$]);

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- erp_test.period_close_suite (20260929000000) proved the GRNI check by
-- ticking the task by hand. The opening ticks it now, so its cases read what
-- the opening did, and the two-press close is proved beside them.

create or replace function erp_test.period_close_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 30;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  s_read   uuid := gen_random_uuid();
  rb       record;
  res      jsonb;
  v_step   text := 'provisioning';
  v_state  text;
  v_tenant uuid; v_entity uuid; v_ledger uuid; v_ccy char(3);
  v_commit uuid; v_group uuid;
  v_p1 uuid; v_p2 uuid; v_p3 uuid; v_p4 uuid;
  v_c1 uuid; v_c2 uuid; v_c4 uuid; v_g1 uuid;
  v_uom uuid; v_site uuid; v_sup uuid; v_item uuid;
  v_po uuid; v_pol uuid; v_grn uuid; v_po2 uuid;
  v_grni text; v_grni_id uuid; v_cos uuid; v_inv_id uuid;
  v_j uuid; v_on date; v_later date;
  v_tmpl record; v_task record;
  v_t1_grni uuid; v_t2_grni uuid; v_t4_inv uuid;
  v_raised integer; v_again integer; v_sib_open integer;
  v_ok text; v_bad text; v_tick text; v_waive text; v_nobody text; v_diag jsonb;
  v_close text; v_close2 text; v_tie text; v_commitment text;
  v_read_open text; v_read_close text;
  v_open bigint;
  v_at1 timestamptz; v_atc1 timestamptz; v_at2 timestamptz;
  v_opener uuid;
  v_job  text;
  v_owner text := current_user;

  -- A journal on two accounts, posted as the suite's owner: the plants and
  -- their corrections.
  v_lines jsonb;
begin
  begin
    -- ── The fixture: an organisation that buys, receives and closes ────────
    v_step := 'an organisation with finance, procurement, inventory, controls and the close';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzpcs-' || v_tag, 'Period Close Suite',
      'admin@zzpcs-' || v_tag || '.test', 'Period Close Admin');
    v_tenant := rb.tenant_id;
    update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzpcs-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.configure_finance();
    perform erp.configure_procurement(100000000);
    perform erp.configure_sales(15);
    perform erp.configure_inventory('average');
    perform erp.configure_procurement_controls();
    perform erp.configure_period_close();
    v_opener := erp.current_principal_id();

    v_step := 'the ledgers, their periods and the accounts';
    select l.entity_id, l.id, l.currency into v_entity, v_ledger, v_ccy
      from erp.ledger l where l.tenant_id = v_tenant and l.is_primary order by l.code limit 1;
    select l.id into strict v_commit from erp.ledger l
     where l.tenant_id = v_tenant and l.entity_id = v_entity and l.ledger_kind = 'management';
    select fp.id into strict v_p1 from erp.fiscal_period fp
     where fp.tenant_id = v_tenant and fp.ledger_id = v_ledger
       and current_date between fp.starts_on and fp.ends_on;
    select fp.id into strict v_p2 from erp.fiscal_period fp
     where fp.tenant_id = v_tenant and fp.ledger_id = v_ledger and fp.id <> v_p1
     order by fp.starts_on limit 1;
    select fp.id into strict v_p3 from erp.fiscal_period fp
     where fp.tenant_id = v_tenant and fp.ledger_id = v_ledger and fp.id not in (v_p1, v_p2)
     order by fp.starts_on limit 1;
    select fp.id into strict v_p4 from erp.fiscal_period fp
     where fp.tenant_id = v_tenant and fp.ledger_id = v_ledger and fp.id not in (v_p1, v_p2, v_p3)
     order by fp.starts_on limit 1;
    select s.id into strict v_c1 from erp.fiscal_period s join erp.fiscal_period fp on fp.id = v_p1
     where s.tenant_id = v_tenant and s.ledger_id = v_commit and s.starts_on = fp.starts_on;
    select s.id into strict v_c2 from erp.fiscal_period s join erp.fiscal_period fp on fp.id = v_p2
     where s.tenant_id = v_tenant and s.ledger_id = v_commit and s.starts_on = fp.starts_on;
    select s.id into strict v_c4 from erp.fiscal_period s join erp.fiscal_period fp on fp.id = v_p4
     where s.tenant_id = v_tenant and s.ledger_id = v_commit and s.starts_on = fp.starts_on;

    -- A consolidation of the same company, with this month open on it.
    insert into erp.ledger (tenant_id, entity_id, code, name, ledger_kind, currency, is_primary, status)
    values (v_tenant, v_entity, 'ZZGROUP', 'Period close suite group', 'group', v_ccy, false, 'active')
    returning id into v_group;
    insert into erp.fiscal_period (tenant_id, ledger_id, code, fiscal_year, period_number,
                                   starts_on, ends_on, status)
    select v_tenant, v_group, fp.code, fp.fiscal_year, fp.period_number, fp.starts_on, fp.ends_on, 'open'
      from erp.fiscal_period fp where fp.id = v_p1
    returning id into v_g1;

    v_grni := erp.tenant_account_code('goods_received_not_invoiced');
    select a.id into strict v_grni_id from erp.account a
     where a.tenant_id = v_tenant and a.entity_id = v_entity and a.code = v_grni;
    select a.id into strict v_cos from erp.account a
     where a.tenant_id = v_tenant and a.entity_id = v_entity
       and a.code = erp.tenant_account_code('cost_of_sales');
    select a.id into strict v_inv_id from erp.account a
     where a.tenant_id = v_tenant and a.entity_id = v_entity
       and a.code = erp.tenant_account_code('inventory');

    v_step := 'a supplier, a product, and a hundred of them received on a ten-pound order';
    select u.id into v_uom from erp.uom u
     where u.tenant_id = v_tenant and u.is_base order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (v_tenant, 'ZCEA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (v_tenant, v_entity, 'ZCSITE', 'Period close suite site', 'warehouse', 'active')
    returning id into v_site;
    perform erp.create_location(v_site, 'ZC-RECV', 'Goods in', 'receiving');
    perform erp.create_location(v_site, 'ZC-BULK', 'Bulk', 'bulk');
    insert into erp.party (tenant_id, code, name, status)
    values (v_tenant, 'ZCSUP', 'Period Close Suite Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (v_tenant, v_sup, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (v_tenant, 'ZCWID', 'Period Close Suite Widget', v_uom, 'active')
    returning id into v_item;
    v_po := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    v_pol := erp.add_document_line(v_po, v_item, 100, 1000, 'a hundred widgets at ten pounds');
    perform erp.transition_document(v_po, 'submit', 'period close suite');
    perform erp_test.approve_document(v_po, 'period close suite');
    perform erp.transition_document(v_po, 'send', 'period close suite');
    v_grn := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    perform erp.receive_against(v_grn, v_pol, 100, null);
    perform erp.transition_document(v_grn, 'post', 'period close suite');
    select coalesce(sum(g.open_value_minor), 0) into v_open from erp.grni_report() g;

    -- ── 1. The checklist carries the check, and it is not a tie ─────────────
    v_step := 'the close opened on this month';
    v_raised := erp.open_period_close(v_p1);
    select ct.blocking_check, ct.is_waivable into v_tmpl
      from erp.close_task_template ct
     where ct.tenant_id = v_tenant and ct.code = 'grni_reviewed';
    select t.id, t.blocking_check, t.is_waivable, t.status, t.completed_by, t.check_output into v_task
      from erp.close_task t where t.fiscal_period_id = v_p1 and t.code = 'grni_reviewed';
    v_t1_grni := v_task.id;

    v_cases := v_cases + 1;
    case_name := 'a raised grni_reviewed carries erp.assert_grni_reconciles() and stays waivable, and the ties are still four';
    passed := v_state is null
          and v_raised = 6
          and v_tmpl.blocking_check = 'erp.assert_grni_reconciles()'
          and v_tmpl.is_waivable
          and v_task.blocking_check = 'erp.assert_grni_reconciles()'
          and v_task.is_waivable
          and not erp.close_check_is_a_tie(v_task.blocking_check)
          and erp.close_tie_check('grni_reviewed') is null
          and (select count(*) from erp.close_task t
                where t.fiscal_period_id = v_p1 and not t.is_waivable) = 4;
    detail := coalesce(v_state, format('%s raised; template %s (waivable %s); task %s (waivable %s, %s); %s unwaivable',
      v_raised, v_tmpl.blocking_check, v_tmpl.is_waivable, v_task.blocking_check, v_task.is_waivable,
      v_task.status,
      (select count(*) from erp.close_task t where t.fiscal_period_id = v_p1 and not t.is_waivable)),
      'no answer');
    return next;

    -- ── 2. The opening ran the checks ──────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'opening the close runs every check and completes all six on clean books, as the person who opened it, with what each check said';
    passed := v_state is null
          and (select count(*) from erp.close_task t
                where t.fiscal_period_id = v_p1 and t.status = 'complete'
                  and t.completed_by = v_opener and t.waiver_reason is null
                  and t.check_output is not null) = 6
          and v_task.check_output like 'grni: ' || v_grni || ' reconciles%'
          and (select t.check_output from erp.close_task t
                where t.fiscal_period_id = v_p1 and t.code = 'trial_balance') like 'trial balance:%';
    detail := coalesce(v_state, (select string_agg(format('%s %s', t.code, t.status), ', ' order by t.seq)
                                   from erp.close_task t where t.fiscal_period_id = v_p1), 'no answer');
    return next;

    -- ── 3. It opened the month on every ledger that closes with it ─────────
    v_cases := v_cases + 1;
    case_name := 'opening raises one checklist, on the period it was opened on, and opens COMMIT''s month with it; the consolidation''s month is not its sibling';
    passed := v_state is null
          and (select array_agg(s) from erp.period_siblings(v_p1) s) = array[v_c1]
          and not exists (select 1 from erp.period_siblings(v_g1))
          and (select fp.status::text from erp.fiscal_period fp where fp.id = v_p1) = 'closing'
          and (select fp.status::text from erp.fiscal_period fp where fp.id = v_c1) = 'closing'
          and (select fp.status::text from erp.fiscal_period fp where fp.id = v_g1) = 'open'
          and not exists (select 1 from erp.close_task t where t.fiscal_period_id in (v_c1, v_g1));
    detail := coalesce(v_state, format('GL %s, COMMIT %s, group %s; %s task(s) on COMMIT',
      (select fp.status from erp.fiscal_period fp where fp.id = v_p1),
      (select fp.status from erp.fiscal_period fp where fp.id = v_c1),
      (select fp.status from erp.fiscal_period fp where fp.id = v_g1),
      (select count(*) from erp.close_task t where t.fiscal_period_id = v_c1)), 'no answer');
    return next;

    -- ── 4. Books that reconcile say so, three ways ─────────────────────────
    v_step := 'the check on books that reconcile';
    v_ok := erp.assert_grni_reconciles();

    v_cases := v_cases + 1;
    case_name := 'on books that reconcile the check passes, naming the account and the tile''s, the ledger''s and the balance sheet''s figure';
    passed := v_state is null
          and v_open = 100000
          and v_ok = format('grni: %s reconciles — open receipts 100000, ledger 100000, balance sheet at %s 100000',
                            v_grni, current_date);
    detail := coalesce(v_state, v_ok, 'no answer');
    return next;

    -- ── 5. A journal nothing received explains ─────────────────────────────
    --
    -- The spec's £957: money on the account with no receipt behind it.
    v_step := 'a journal on the GRNI account that no receipt explains';
    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date,
                             description, status, manual_reason)
    values (v_tenant, v_entity, v_ledger, 'manual', current_date, 'ZZPCS-PLANT', 'draft',
            'suite: a credit to GRNI with no receipt behind it')
    returning id into v_j;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
                                  currency, base_debit_minor, base_credit_minor, exchange_rate)
    values (v_tenant, v_j, 1, v_cos, 95700, 0, v_ccy, 95700, 0, 1),
           (v_tenant, v_j, 2, v_grni_id, 0, 95700, v_ccy, 0, 95700, 1);
    update erp.journal set status = 'posted', posted_at = now(),
                           posted_by = erp.current_principal_id() where id = v_j;
    begin
      v_bad := 'passed: ' || erp.assert_grni_reconciles();
    exception when others then
      v_bad := sqlerrm;
    end;

    v_cases := v_cases + 1;
    case_name := 'a journal on the account that no receipt explains fails the check, naming the three figures, the difference and what posted it';
    passed := v_state is null
          and v_bad like 'CLOVEERP_GRNI_DOES_NOT_RECONCILE: ' || v_grni || ' — open receipts 100000, ledger 195700 (out by 95700), balance sheet at % 195700 (out by 95700)%'
          and v_bad like '%manual 95700 (1 line(s))%'
          and v_bad like '%goods_receipt v% 100000 (1 line(s))%';
    detail := coalesce(v_state, left(v_bad, 400), 'no answer');
    return next;

    -- ── 6. The close asks again ────────────────────────────────────────────
    --
    -- The task passed when the close was opened and the books moved since.
    -- The period is still closing, so it took the posting (S3).
    v_step := 'the period closed after the GRNI check stopped passing';
    begin
      perform erp.close_period(v_p1);
      v_close := 'the period closed over a check that fails now';
    exception when others then
      v_close := sqlerrm;
    end;

    v_cases := v_cases + 1;
    case_name := 'a check that passed when the close was opened and fails by the close refuses the close, in the check''s own words, and nothing closes';
    passed := v_state is null
          and v_close like 'CLOVEERP_CLOSE_CHECK_FAILED: erp.assert_grni_reconciles() — CLOVEERP_GRNI_DOES_NOT_RECONCILE:%out by 95700%'
          and (select t.status from erp.close_task t where t.id = v_t1_grni) = 'complete'
          and (select fp.status::text from erp.fiscal_period fp where fp.id = v_p1) = 'closing'
          and (select fp.status::text from erp.fiscal_period fp where fp.id = v_c1) = 'closing';
    detail := coalesce(v_state, left(v_close, 400), 'no answer');
    return next;

    -- ── 7. The close will not tick past it ─────────────────────────────────
    v_step := 'the GRNI task ticked while the account is out';
    begin
      perform erp.complete_close_task(v_t1_grni);
      v_tick := 'the task was ticked over a difference';
    exception when others then
      v_tick := sqlerrm;
    end;

    v_cases := v_cases + 1;
    case_name := 'the exception door will not tick the task past the difference either, and says what the check said';
    passed := v_state is null
          and v_tick like 'CLOVEERP_CLOSE_CHECK_FAILED: erp.assert_grni_reconciles() — CLOVEERP_GRNI_DOES_NOT_RECONCILE:%out by 95700%'
          and (select cs.check_passes from erp.close_status(v_p1) cs where cs.code = 'grni_reviewed') is false;
    detail := coalesce(v_state, left(v_tick, 400), 'no answer');
    return next;

    -- ── 8. Waived with a reason ────────────────────────────────────────────
    v_step := 'the GRNI task waived with a reason';
    v_waive := erp.complete_close_task(v_t1_grni, 'Residue from bills before procurement-controls v4; journal next month');
    select t.status, t.waiver_reason, t.check_output into v_task
      from erp.close_task t where t.id = v_t1_grni;

    v_cases := v_cases + 1;
    case_name := 'waived with a reason it passes, and the task records the difference the check found';
    passed := v_state is null
          and v_task.status = 'waived'
          and v_task.waiver_reason like 'Residue from bills%'
          and v_task.check_output like 'FAILED: CLOVEERP_GRNI_DOES_NOT_RECONCILE:%out by 95700%'
          and v_waive = v_task.check_output;
    detail := coalesce(v_state, format('%s: %s', v_task.status, left(v_task.check_output, 300)), 'no answer');
    return next;

    -- ── 9. Reversed, it reconciles again ───────────────────────────────────
    v_step := 'the plant reversed';
    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date,
                             description, status, manual_reason)
    values (v_tenant, v_entity, v_ledger, 'manual', current_date, 'ZZPCS-REVERSE', 'draft',
            'suite: the correction')
    returning id into v_j;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
                                  currency, base_debit_minor, base_credit_minor, exchange_rate)
    values (v_tenant, v_j, 1, v_grni_id, 95700, 0, v_ccy, 95700, 0, 1),
           (v_tenant, v_j, 2, v_cos, 0, 95700, v_ccy, 0, 95700, 1);
    update erp.journal set status = 'posted', posted_at = now(),
                           posted_by = erp.current_principal_id() where id = v_j;
    begin
      v_ok := erp.assert_grni_reconciles();
    exception when others then
      v_ok := sqlerrm;
    end;

    v_cases := v_cases + 1;
    case_name := 'once the correction is posted the three figures agree again';
    passed := v_state is null and v_ok like 'grni: ' || v_grni || ' reconciles — open receipts 100000, ledger 100000,%';
    detail := coalesce(v_state, left(v_ok, 300), 'no answer');
    return next;

    -- ── 10. An organisation configured before this ─────────────────────────
    --
    -- Its template names no check: the product shipped none. Nothing rewrites
    -- it, and its next close raises the task with the check all the same.
    v_step := 'a template from before the check, and its next close';
    update erp.close_task_template set blocking_check = null, updated_at = now()
     where tenant_id = v_tenant and code = 'grni_reviewed';
    select ct.blocking_check, ct.is_waivable into v_tmpl
      from erp.close_task_template ct
     where ct.tenant_id = v_tenant and ct.code = 'grni_reviewed';
    perform erp.open_period_close(v_p2);
    select t.id, t.blocking_check, t.is_waivable, t.status, t.waiver_reason, t.check_output, t.completed_by
      into v_task
      from erp.close_task t where t.fiscal_period_id = v_p2 and t.code = 'grni_reviewed';
    v_t2_grni := v_task.id;

    v_cases := v_cases + 1;
    case_name := 'the template of an organisation configured before this is left as it is, and its next raised task still carries the check';
    passed := v_state is null
          and v_tmpl.blocking_check is null
          and v_tmpl.is_waivable
          and v_task.blocking_check = 'erp.assert_grni_reconciles()'
          and v_task.is_waivable;
    detail := coalesce(v_state, format('template %s; raised %s (waivable %s, %s)',
      coalesce(v_tmpl.blocking_check, 'no check'), v_task.blocking_check, v_task.is_waivable, v_task.status),
      'no answer');
    return next;

    -- ── 11. Clean books complete it at the opening ─────────────────────────
    v_cases := v_cases + 1;
    case_name := 'on clean books the opening runs the check and completes the task, with what the check said recorded';
    passed := v_state is null
          and v_task.status = 'complete'
          and v_task.waiver_reason is null
          and v_task.completed_by = v_opener
          and v_task.check_output like 'grni: ' || v_grni || ' reconciles%';
    detail := coalesce(v_state, format('%s: %s', v_task.status, v_task.check_output), 'no answer');
    return next;

    -- ── 12. Closing, and still taking postings, until the close ────────────
    v_cases := v_cases + 1;
    case_name := 'an opened month is closing on both ledgers and still takes postings on both until it is closed';
    passed := v_state is null
          and (select fp.status::text from erp.fiscal_period fp where fp.id = v_p2) = 'closing'
          and (select fp.status::text from erp.fiscal_period fp where fp.id = v_c2) = 'closing'
          and erp.period_accepts_postings(v_p2)
          and erp.period_accepts_postings(v_c2);
    detail := coalesce(v_state, format('GL %s, COMMIT %s',
      (select fp.status from erp.fiscal_period fp where fp.id = v_p2),
      (select fp.status from erp.fiscal_period fp where fp.id = v_c2)), 'no answer');
    return next;

    -- ── 13. A check of the organisation's own is kept ──────────────────────
    v_step := 'a template naming a check of its own';
    update erp.close_task_template set blocking_check = 'erp.assert_stock_reconciles()', updated_at = now()
     where tenant_id = v_tenant and code = 'grni_reviewed';
    perform erp.open_period_close(v_p3);
    select t.blocking_check, t.is_waivable into v_task
      from erp.close_task t where t.fiscal_period_id = v_p3 and t.code = 'grni_reviewed';

    v_cases := v_cases + 1;
    case_name := 'an organisation that gave the task a check of its own keeps it, and it stays waivable';
    passed := v_state is null
          and v_task.blocking_check = 'erp.assert_stock_reconciles()'
          and v_task.is_waivable;
    detail := coalesce(v_state, format('raised with %s (waivable %s)', v_task.blocking_check, v_task.is_waivable),
      'no answer');
    return next;

    update erp.close_task_template set blocking_check = 'erp.assert_grni_reconciles()', updated_at = now()
     where tenant_id = v_tenant and code = 'grni_reviewed';

    -- ── 14. The balance sheet is a figure of its own ───────────────────────
    --
    -- Money taken off the account today and put back tomorrow nets to nothing
    -- on the ledger, so the reconciliation reads zero; the balance sheet as at
    -- today does not, and the check says so.
    v_step := 'a posting today undone by one dated tomorrow';
    v_on := current_date;
    v_later := current_date + 1;
    if not exists (select 1 from erp.fiscal_period fp
                    where fp.tenant_id = v_tenant and fp.ledger_id = v_ledger
                      and v_later between fp.starts_on and fp.ends_on) then
      insert into erp.fiscal_period (tenant_id, ledger_id, code, fiscal_year, period_number,
                                     starts_on, ends_on, status)
      values (v_tenant, v_ledger, 'ZZ-' || to_char(v_later, 'YYYY-MM'),
              extract(year from v_later)::integer, 1::smallint,
              date_trunc('month', v_later)::date,
              (date_trunc('month', v_later) + interval '1 month - 1 day')::date, 'open');
    end if;
    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date,
                             description, status, manual_reason)
    values (v_tenant, v_entity, v_ledger, 'manual', v_on, 'ZZPCS-TODAY', 'draft', 'suite: off today')
    returning id into v_j;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
                                  currency, base_debit_minor, base_credit_minor, exchange_rate)
    values (v_tenant, v_j, 1, v_grni_id, 500, 0, v_ccy, 500, 0, 1),
           (v_tenant, v_j, 2, v_cos, 0, 500, v_ccy, 0, 500, 1);
    update erp.journal set status = 'posted', posted_at = now(),
                           posted_by = erp.current_principal_id() where id = v_j;
    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date,
                             description, status, manual_reason)
    values (v_tenant, v_entity, v_ledger, 'manual', v_later, 'ZZPCS-TOMORROW', 'draft', 'suite: back tomorrow')
    returning id into v_j;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
                                  currency, base_debit_minor, base_credit_minor, exchange_rate)
    values (v_tenant, v_j, 1, v_cos, 500, 0, v_ccy, 500, 0, 1),
           (v_tenant, v_j, 2, v_grni_id, 0, 500, v_ccy, 0, 500, 1);
    update erp.journal set status = 'posted', posted_at = now(),
                           posted_by = erp.current_principal_id() where id = v_j;
    begin
      v_bad := 'passed: ' || erp.assert_grni_reconciles();
    exception when others then
      v_bad := sqlerrm;
    end;

    v_cases := v_cases + 1;
    case_name := 'a posting the ledger nets away by a later date still fails, because the balance sheet as at today is out';
    passed := v_state is null
          and (select r.difference_minor from erp.grni_reconciliation() r) = 0
          and v_bad like 'CLOVEERP_GRNI_DOES_NOT_RECONCILE: %ledger 100000 (out by 0), balance sheet at % 99500 (out by -500)%';
    detail := coalesce(v_state, left(v_bad, 400), 'no answer');
    return next;

    -- ── 15. §8.1's chart: GRNI is 3200 ─────────────────────────────────────
    v_step := 'the account renumbered as §8.1 numbers it';
    -- Both undone: put back today, taken off again tomorrow.
    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date,
                             description, status, manual_reason)
    values (v_tenant, v_entity, v_ledger, 'manual', v_on, 'ZZPCS-BACK', 'draft', 'suite: back today')
    returning id into v_j;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
                                  currency, base_debit_minor, base_credit_minor, exchange_rate)
    values (v_tenant, v_j, 1, v_cos, 500, 0, v_ccy, 500, 0, 1),
           (v_tenant, v_j, 2, v_grni_id, 0, 500, v_ccy, 0, 500, 1);
    update erp.journal set status = 'posted', posted_at = now(),
                           posted_by = erp.current_principal_id() where id = v_j;
    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date,
                             description, status, manual_reason)
    values (v_tenant, v_entity, v_ledger, 'manual', v_later, 'ZZPCS-OFF', 'draft', 'suite: off tomorrow')
    returning id into v_j;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
                                  currency, base_debit_minor, base_credit_minor, exchange_rate)
    values (v_tenant, v_j, 1, v_grni_id, 500, 0, v_ccy, 500, 0, 1),
           (v_tenant, v_j, 2, v_cos, 0, 500, v_ccy, 0, 500, 1);
    update erp.journal set status = 'posted', posted_at = now(),
                           posted_by = erp.current_principal_id() where id = v_j;
    update erp.account a set code = '3200', updated_at = now()
     where a.tenant_id = v_tenant and a.id = v_grni_id;
    begin
      v_ok := erp.assert_grni_reconciles();
    exception when others then
      v_ok := sqlerrm;
    end;

    v_cases := v_cases + 1;
    case_name := 'on §8.1''s chart the check finds GRNI at 3200 by its purpose and reconciles it there';
    passed := v_state is null
          and erp.tenant_account_code('goods_received_not_invoiced') = '3200'
          and v_ok like 'grni: 3200 reconciles — open receipts 100000, ledger 100000, balance sheet at % 100000';
    detail := coalesce(v_state, left(v_ok, 300), 'no answer');
    return next;

    -- ── 16. Registered for reading, not for the deploy ─────────────────────
    v_step := 'the registers';
    v_diag := erp.run_diagnostic('grni_reconciles');

    v_cases := v_cases + 1;
    case_name := 'the check is a report the diagnostics screen runs in an organisation, outside the whole-database gate and the structural phase';
    passed := v_state is null
          and exists (select 1 from erp_meta.diagnostic_check d
                       where d.code = 'grni_reconciles' and d.kind = 'report' and d.scope = 'tenant'
                         and d.schema_name = 'erp' and d.function_name = 'assert_grni_reconciles'
                         and d.detail_function = 'grni_reconciliation'
                         and not d.runs_in_ci and d.book_tie_name is null)
          and not exists (select 1 from erp_meta.diagnostic_check d
                           where d.function_name = 'assert_grni_reconciles' and d.kind = 'assertion')
          and not exists (select 1 from erp.ci_check_catalogue() c
                           where c.qualified_name = 'erp.assert_grni_reconciles')
          and (v_diag ->> 'ok')::boolean
          and v_diag ->> 'summary' like 'grni: 3200 reconciles%'
          and not exists (select 1 from erp_ref.refusal f where f.code = 'CLOVEERP_GRNI_DOES_NOT_RECONCILE')
          and position('supabase/ops/20260929_grni_residue.sql' in
                       pg_get_functiondef('erp.assert_grni_reconciles()'::regprocedure)) > 0;
    detail := coalesce(v_state, format('diagnostic: %s', left(v_diag::text, 300)), 'no answer');
    return next;

    -- ── 17. Nobody's books ─────────────────────────────────────────────────
    v_step := 'the check with no organisation';
    v_job := current_setting('erp.job_tenant_id', true);
    perform set_config('request.jwt.claims', '', true);
    perform set_config('erp.job_tenant_id', '', true);
    begin
      v_nobody := 'passed: ' || erp.assert_grni_reconciles();
    exception when others then
      v_nobody := sqlerrm;
    end;
    perform set_config('erp.job_tenant_id', coalesce(v_job, ''), true);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_cases := v_cases + 1;
    case_name := 'with no organisation the check refuses rather than reconciling nothing';
    passed := v_state is null and v_nobody like 'CLOVEERP_NO_TENANT_CONTEXT:%';
    detail := coalesce(v_state, left(v_nobody, 200), 'no answer');
    return next;

    -- ── 18. The tile's words ───────────────────────────────────────────────
    v_step := 'the tile''s words';
    v_cases := v_cases + 1;
    case_name := 'the purchasing tile says it counts open receipts at order price today, and the words can be renamed';
    passed := v_state is null
          and exists (select 1 from erp_ref.resource r
                       where r.key = erp_ref.ui_key('open receipts at order price, today')
                         and r.locale = 'en' and r.value = 'open receipts at order price, today');
    detail := coalesce(v_state, 'erp_ref.resource holds the tile''s hint', 'no answer');
    return next;

    -- ── 19. What fails at the opening is left for somebody ─────────────────
    --
    -- Money on inventory that no stock explains, and on GRNI that no receipt
    -- does: one breaks a tie, the other a judgement.
    v_step := 'a month opened while inventory and GRNI are both out';
    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date,
                             description, status, manual_reason)
    values (v_tenant, v_entity, v_ledger, 'manual', current_date, 'ZZPCS-BOTH', 'draft',
            'suite: inventory and GRNI with nothing behind them')
    returning id into v_j;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
                                  currency, base_debit_minor, base_credit_minor, exchange_rate)
    values (v_tenant, v_j, 1, v_inv_id, 4321, 0, v_ccy, 4321, 0, 1),
           (v_tenant, v_j, 2, v_cos, 0, 4321, v_ccy, 0, 4321, 1),
           (v_tenant, v_j, 3, v_cos, 800, 0, v_ccy, 800, 0, 1),
           (v_tenant, v_j, 4, v_grni_id, 0, 800, v_ccy, 0, 800, 1);
    update erp.journal set status = 'posted', posted_at = now(),
                           posted_by = erp.current_principal_id() where id = v_j;
    perform erp.open_period_close(v_p4);
    select t.id into v_t4_inv from erp.close_task t
     where t.fiscal_period_id = v_p4 and t.code = 'inventory_valued';
    begin
      perform erp.complete_close_task(v_t4_inv, 'Counted by hand, it is fine');
      v_tie := 'the tie was waived';
    exception when others then
      v_tie := sqlerrm;
    end;
    begin
      perform erp.close_period(v_p4);
      v_close2 := 'the period closed with tasks open';
    exception when others then
      v_close2 := sqlerrm;
    end;

    v_cases := v_cases + 1;
    case_name := 'a task whose check fails at the opening is left open, and so is what waits on it, while what passes is complete';
    passed := v_state is null
          and (select t.status from erp.close_task t where t.fiscal_period_id = v_p4 and t.code = 'stock_reconciles') = 'complete'
          and (select t.status from erp.close_task t where t.fiscal_period_id = v_p4 and t.code = 'inventory_valued') = 'open'
          and (select t.status from erp.close_task t where t.fiscal_period_id = v_p4 and t.code = 'grni_reviewed') = 'open'
          and (select t.status from erp.close_task t where t.fiscal_period_id = v_p4 and t.code = 'trial_balance') = 'open'
          and (select t.completed_by from erp.close_task t where t.fiscal_period_id = v_p4 and t.code = 'inventory_valued') is null;
    detail := coalesce(v_state, (select string_agg(format('%s %s', t.code, t.status), ', ' order by t.seq)
                                   from erp.close_task t where t.fiscal_period_id = v_p4), 'no answer');
    return next;

    v_cases := v_cases + 1;
    case_name := 'a tie that failed at the opening cannot be waived, and the close refuses naming every task still open, and closes neither ledger';
    passed := v_state is null
          and v_tie like 'CLOVEERP_CLOSE_TIE_NOT_WAIVABLE:%'
          and v_close2 like 'CLOVEERP_CLOSE_TASKS_OPEN:%Inventory valuation agrees with the ledger%'
          and v_close2 like '%Goods received not invoiced reviewed%'
          and v_close2 like '%Trial balance reviewed and signed%'
          and (select fp.status::text from erp.fiscal_period fp where fp.id = v_p4) = 'closing'
          and (select fp.status::text from erp.fiscal_period fp where fp.id = v_c4) = 'closing';
    detail := coalesce(v_state, left(format('waive: %s; close: %s', v_tie, v_close2), 400), 'no answer');
    return next;

    -- Undone, dated today, while this month still takes postings.
    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date,
                             description, status, manual_reason)
    values (v_tenant, v_entity, v_ledger, 'manual', current_date, 'ZZPCS-BOTH-BACK', 'draft',
            'suite: the correction of both')
    returning id into v_j;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
                                  currency, base_debit_minor, base_credit_minor, exchange_rate)
    values (v_tenant, v_j, 1, v_cos, 4321, 0, v_ccy, 4321, 0, 1),
           (v_tenant, v_j, 2, v_inv_id, 0, 4321, v_ccy, 0, 4321, 1),
           (v_tenant, v_j, 3, v_grni_id, 800, 0, v_ccy, 800, 0, 1),
           (v_tenant, v_j, 4, v_cos, 0, 800, v_ccy, 0, 800, 1);
    update erp.journal set status = 'posted', posted_at = now(),
                           posted_by = erp.current_principal_id() where id = v_j;

    -- ── 20. A waived task is not asked again ───────────────────────────────
    --
    -- GRNI was waived on this month (case 8). The difference is back; the
    -- close goes through on the waiver, and closes both ledgers at once.
    v_step := 'this month closed while its waived task would fail';
    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date,
                             description, status, manual_reason)
    values (v_tenant, v_entity, v_ledger, 'manual', current_date, 'ZZPCS-PLANT-2', 'draft',
            'suite: the residue the waiver named')
    returning id into v_j;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
                                  currency, base_debit_minor, base_credit_minor, exchange_rate)
    values (v_tenant, v_j, 1, v_cos, 95700, 0, v_ccy, 95700, 0, 1),
           (v_tenant, v_j, 2, v_grni_id, 0, 95700, v_ccy, 0, 95700, 1);
    update erp.journal set status = 'posted', posted_at = now(),
                           posted_by = erp.current_principal_id() where id = v_j;
    begin
      v_bad := 'passed: ' || erp.assert_grni_reconciles();
    exception when others then
      v_bad := sqlerrm;
    end;
    perform erp.close_period(v_p1);
    select fp.closed_at into v_at1 from erp.fiscal_period fp where fp.id = v_p1;
    select fp.closed_at into v_atc1 from erp.fiscal_period fp where fp.id = v_c1;

    v_cases := v_cases + 1;
    case_name := 'a waived task is a recorded judgement and is not run again at the close, which goes through while its check fails';
    passed := v_state is null
          and v_bad like 'CLOVEERP_GRNI_DOES_NOT_RECONCILE:%'
          and (select t.status from erp.close_task t where t.id = v_t1_grni) = 'waived'
          and (select fp.status::text from erp.fiscal_period fp where fp.id = v_p1) = 'closed';
    detail := coalesce(v_state, format('GRNI %s; GL %s',
      (select t.status from erp.close_task t where t.id = v_t1_grni),
      (select fp.status from erp.fiscal_period fp where fp.id = v_p1)), 'no answer');
    return next;

    v_cases := v_cases + 1;
    case_name := 'the close closes GL and COMMIT together, with one timestamp and one closer, and leaves the consolidation''s month open';
    passed := v_state is null
          and (select fp.status::text from erp.fiscal_period fp where fp.id = v_c1) = 'closed'
          and v_at1 is not null and v_at1 = v_atc1
          and (select fp.closed_by from erp.fiscal_period fp where fp.id = v_c1) = v_opener
          and not erp.period_accepts_postings(v_p1)
          and not erp.period_accepts_postings(v_c1)
          and (select fp.status::text from erp.fiscal_period fp where fp.id = v_g1) = 'open'
          and erp.period_accepts_postings(v_g1);
    detail := coalesce(v_state, format('GL %s at %s, COMMIT %s at %s, group %s',
      (select fp.status from erp.fiscal_period fp where fp.id = v_p1), v_at1,
      (select fp.status from erp.fiscal_period fp where fp.id = v_c1), v_atc1,
      (select fp.status from erp.fiscal_period fp where fp.id = v_g1)), 'no answer');
    return next;

    -- ── 21. The second ledger of a closed month ────────────────────────────
    v_step := 'COMMIT''s month opened and closed again after it closed with GL';
    v_again := erp.open_period_close(v_c1);
    perform erp.close_period(v_c1);

    v_cases := v_cases + 1;
    case_name := 'opening or closing the sibling that closed with the month is nothing to do: it stays closed, at the moment it closed, with no checklist of its own';
    passed := v_state is null
          and v_again = 0
          and (select fp.status::text from erp.fiscal_period fp where fp.id = v_c1) = 'closed'
          and (select fp.closed_at from erp.fiscal_period fp where fp.id = v_c1) = v_atc1
          and not exists (select 1 from erp.close_task t where t.fiscal_period_id = v_c1);
    detail := coalesce(v_state, format('opening answered %s; COMMIT %s at %s',
      v_again, (select fp.status from erp.fiscal_period fp where fp.id = v_c1),
      (select fp.closed_at from erp.fiscal_period fp where fp.id = v_c1)), 'no answer');
    return next;

    -- ── 22. A commitment dated into the closed month (D3) ──────────────────
    v_step := 'an order raised and sent, dated in the closed month';
    begin
      v_po2 := erp.open_document('purchase_order', v_sup, v_entity, v_site);
      perform erp.add_document_line(v_po2, v_item, 5, 1000, 'five more, into a closed month');
      perform erp.transition_document(v_po2, 'submit', 'period close suite');
      perform erp_test.approve_document(v_po2, 'period close suite');
      perform erp.transition_document(v_po2, 'send', 'period close suite');
      v_commitment := 'the commitment posted into a closed month';
    exception when others then
      v_commitment := sqlerrm;
    end;

    v_cases := v_cases + 1;
    case_name := 'COMMIT closed with GL, so an order committing money inside the closed month is refused, and the refusal says a reopening is recorded first';
    passed := v_state is null
          and v_commitment like 'CLOVEERP_PERIOD_CLOSED: ' || (select fp.code from erp.fiscal_period fp where fp.id = v_c1) || ' is closed%reopening%';
    detail := coalesce(v_state, left(v_commitment, 300), 'no answer');
    return next;

    -- ── 23. Reopened, it closes again in the same two presses ──────────────
    v_step := 'GL reopened, corrected, and closed again';
    perform erp.reopen_period(v_p1, 'suite: post the correction the waiver named');
    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date,
                             description, status, manual_reason)
    values (v_tenant, v_entity, v_ledger, 'manual', current_date, 'ZZPCS-REVERSE-2', 'draft',
            'suite: the correction, into the reopened month')
    returning id into v_j;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
                                  currency, base_debit_minor, base_credit_minor, exchange_rate)
    values (v_tenant, v_j, 1, v_grni_id, 95700, 0, v_ccy, 95700, 0, 1),
           (v_tenant, v_j, 2, v_cos, 0, 95700, v_ccy, 0, 95700, 1);
    update erp.journal set status = 'posted', posted_at = now(),
                           posted_by = erp.current_principal_id() where id = v_j;
    v_again := erp.open_period_close(v_p1);
    perform erp.close_period(v_p1);
    select fp.closed_at into v_at2 from erp.fiscal_period fp where fp.id = v_p1;

    v_cases := v_cases + 1;
    case_name := 'a reopened month closes again through the same two presses, raising nothing twice; the sibling nobody reopened keeps the close it had';
    passed := v_state is null
          and v_again = 6
          and (select count(*) from erp.close_task t where t.fiscal_period_id = v_p1) = 6
          and (select fp.status::text from erp.fiscal_period fp where fp.id = v_p1) = 'closed'
          and v_at2 > v_at1
          and not erp.period_accepts_postings(v_p1)
          and (select fp.closed_at from erp.fiscal_period fp where fp.id = v_c1) = v_atc1;
    detail := coalesce(v_state, format('%s on the checklist; GL %s at %s (first %s); COMMIT at %s',
      v_again, (select fp.status from erp.fiscal_period fp where fp.id = v_p1), v_at2, v_at1,
      (select fp.closed_at from erp.fiscal_period fp where fp.id = v_c1)), 'no answer');
    return next;

    -- ── 24. Somebody who reads the books ───────────────────────────────────
    v_step := 'a person who may read the books but not close them';
    res := public.erp_invite_principal('reader@zzpcs-' || v_tag || '.test', 'Rita Reader');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'observer', null, null, 'reads the books');
    perform set_config('request.jwt.claims', json_build_object('sub', s_read)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    begin
      perform public.erp_open_period_close(v_p3);
      v_read_open := 'the reader opened a close';
    exception when others then
      v_read_open := sqlerrm;
    end;
    begin
      perform public.erp_close_period(v_p2);
      v_read_close := 'the reader closed a month';
    exception when others then
      v_read_close := sqlerrm;
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_cases := v_cases + 1;
    case_name := 'somebody holding finance.read and not finance.close_period can neither open a close nor close a month';
    passed := v_state is null
          and exists (select 1 from erp.role r join erp.role_permission rp on rp.role_id = r.id
                       where r.tenant_id = v_tenant and r.code = 'observer' and rp.permission_code = 'finance.read')
          and not exists (select 1 from erp.role r join erp.role_permission rp on rp.role_id = r.id
                           where r.tenant_id = v_tenant and r.code = 'observer' and rp.permission_code = 'finance.close_period')
          and v_read_open like '%finance.close_period%'
          and v_read_close like '%finance.close_period%'
          and (select fp.status::text from erp.fiscal_period fp where fp.id = v_p2) = 'closing';
    detail := coalesce(v_state, left(format('open: %s; close: %s', v_read_open, v_read_close), 300), 'no answer');
    return next;

    -- ── 25. Consolidation keeps its own close ──────────────────────────────
    v_step := 'the consolidation''s month closed on its own';
    perform erp.open_period_close(v_g1);
    perform erp.close_period(v_g1);

    v_cases := v_cases + 1;
    case_name := 'a consolidation''s month is opened and closed on its own, with its own checklist, and closes nothing else';
    passed := v_state is null
          and (select fp.status::text from erp.fiscal_period fp where fp.id = v_g1) = 'closed'
          and (select count(*) from erp.close_task t where t.fiscal_period_id = v_g1) = 6
          and (select fp.closed_at from erp.fiscal_period fp where fp.id = v_p1) = v_at2
          and (select fp.status::text from erp.fiscal_period fp where fp.id = v_p2) = 'closing';
    detail := coalesce(v_state, format('group %s with %s task(s)',
      (select fp.status from erp.fiscal_period fp where fp.id = v_g1),
      (select count(*) from erp.close_task t where t.fiscal_period_id = v_g1)), 'no answer');
    return next;

    -- ── 26. A month opened from GL and closed from COMMIT ──────────────────
    v_step := 'the month opened from GL, opened again and closed from COMMIT';
    v_again := erp.open_period_close(v_c2);
    perform erp.close_period(v_c2);

    v_cases := v_cases + 1;
    case_name := 'a month has one checklist wherever it is pressed from: opened again from COMMIT it raises nothing there, and closed from COMMIT it closes GL with it at one moment';
    passed := v_state is null
          and v_again = 6
          and not exists (select 1 from erp.close_task t where t.fiscal_period_id = v_c2)
          and (select fp.status::text from erp.fiscal_period fp where fp.id = v_p2) = 'closed'
          and (select fp.status::text from erp.fiscal_period fp where fp.id = v_c2) = 'closed'
          and (select fp.closed_at from erp.fiscal_period fp where fp.id = v_p2)
            = (select fp.closed_at from erp.fiscal_period fp where fp.id = v_c2);
    detail := coalesce(v_state, format('opening from COMMIT answered %s, %s task(s) there; GL %s, COMMIT %s',
      v_again, (select count(*) from erp.close_task t where t.fiscal_period_id = v_c2),
      (select fp.status from erp.fiscal_period fp where fp.id = v_p2),
      (select fp.status from erp.fiscal_period fp where fp.id = v_c2)), 'no answer');
    return next;

    -- ── 27. The count of sibling-closes ────────────────────────────────────
    select count(*) into v_sib_open
      from erp.fiscal_period fp
     where fp.tenant_id = v_tenant and fp.ledger_id = v_commit and fp.status = 'closed';

    v_cases := v_cases + 1;
    case_name := 'COMMIT closed only the months GL closed: two';
    passed := v_state is null and v_sib_open = 2;
    detail := coalesce(v_state, format('%s COMMIT month(s) closed', v_sib_open), 'no answer');
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
        and not exists (select 1 from erp.tenant t where t.code = 'zzpcs-' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1)
        and current_user = v_owner;
  detail := coalesce(v_state, 'zzpcs rolled back with its receipt, journals, periods and close');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_PERIOD_CLOSE_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.period_close_suite() from public, anon;

comment on function erp_test.period_close_suite() is
  'The period close (20260929000000, 20260929200000). grni_reviewed is raised with '
  'erp.assert_grni_reconciles() and stays waivable; a template from before still carries it; an '
  'organisation''s own check is kept; the balance sheet as at today is a figure of its own; §8.1''s 3200; '
  'a report, not a gate. And the close is two presses: opening raises one checklist and completes '
  'every task whose check passes, as the opener, and leaves open what fails or waits on a failure; '
  'closing asks every completed task''s check again, refuses one that fails now, does not ask a waived '
  'one, and closes GL and COMMIT with one timestamp; the second ledger is then nothing to do; a '
  'commitment dated into the closed month is refused; a reopened month closes again the same way; '
  'finance.read can do neither; the consolidation closes on its own; a month opened from one ledger '
  'is closed from the other on the same checklist.';

create or replace function erp_test.assert_period_close_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)),
         count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.period_close_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_PERIOD_CLOSE_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A close was opened, checked, ticked, waived or closed other than the checklist says. Read the case that failed.';
  end if;
  if v_total <> 30 then
    raise exception 'CLOVEERP_PERIOD_CLOSE_SUITE_SHRANK: % case(s), expected 30', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('period close: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_period_close_suite() from public, anon;

comment on function erp_test.assert_period_close_suite() is
  'The close''s GRNI task is checked and stays waivable (20260929000000), and a month closes in two '
  'presses across its ledgers, with the checks asked at the opening and again at the close (20260929200000).';

-- erp_test.demonstration_catch_up_suite counted four ties on every closed
-- period, which was a checklist on every ledger of every month. A month has
-- one checklist now, on its primary ledger, and COMMIT closes with it.
select erp_test.repin_close_suite('erp_test.demonstration_catch_up_suite()', 'one checklist a month (20260929200000)', array[
$o$        and v_ties >= 4 * v_closed_periods;
$o$,
$n$        -- one checklist a month (20260929200000), on the primary ledger, and
        -- every closed period closed at the moment a checklist of its month did.
        and v_ties >= 4 * (select count(*) from erp.fiscal_period fp
                             join erp.ledger l on l.tenant_id = fp.tenant_id and l.id = fp.ledger_id
                            where fp.tenant_id = v_tenant and l.is_primary
                              and fp.status = 'closed'::erp.period_status)
        and not exists (
              select 1 from erp.fiscal_period fp
               where fp.tenant_id = v_tenant and fp.status = 'closed'::erp.period_status
                 and not exists (
                       select 1 from erp.fiscal_period s
                        where s.tenant_id = fp.tenant_id and s.starts_on = fp.starts_on
                          and s.closed_at = fp.closed_at
                          and exists (select 1 from erp.close_task ct
                                       where ct.tenant_id = s.tenant_id and ct.fiscal_period_id = s.id)));
$n$]);

drop function erp_test.repin_close_suite(text, text, text[]);

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The close, walked: erp_test.close_walk
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.close_walk()
returns jsonb
language plpgsql
set search_path = ''
as $function$
declare
  c_undo    constant text := 'CLOVEERP_CLOSE_WALK_UNDO';
  v_hex     text := substr(md5(gen_random_uuid()::text), 1, 8);
  v_code    text;
  a1        uuid := gen_random_uuid();   -- the administrator, who sets up
  s_ctl     uuid := gen_random_uuid();   -- the controller, who closes
  p_ctl     uuid;
  v_ctl     uuid;                      -- who the checklist says it was
  r         record;
  res       jsonb;
  v_role    jsonb;
  v_entity  uuid;
  v_gl      uuid;
  v_commit  uuid;
  v_uom     uuid;
  v_site    uuid;
  v_sup     uuid;
  v_item    uuid;
  v_po      uuid;
  v_pol     uuid;
  v_grn     uuid;
  v_p       uuid;
  v_c       uuid;
  v_steps   jsonb := '[]'::jsonb;
  v_subs    uuid[] := '{}';
  v_block   text;
  v_out     jsonb;
begin
  -- A month of one organisation closed by pressing (20260929200000): it
  -- bought and received on both ledgers, and somebody who is not an
  -- administrator closes it through the two doors the close screen presses.
  begin
    v_code := 'zzclose-' || v_hex;
    select * into r from erp.provision_tenant(
      v_code, 'Close walk', 'admin@' || v_code || '.test', 'Walk Admin');
    update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    perform erp.configure_finance();
    perform erp.configure_procurement(100000000);
    perform erp.configure_sales(15);
    perform erp.configure_inventory('average');
    perform erp.configure_procurement_controls();
    perform erp.configure_period_close();

    select l.entity_id, l.id into v_entity, v_gl
      from erp.ledger l where l.tenant_id = r.tenant_id and l.is_primary order by l.code limit 1;
    select l.id into v_commit from erp.ledger l
     where l.tenant_id = r.tenant_id and l.entity_id = v_entity and l.ledger_kind = 'management';
    select fp.id into v_p from erp.fiscal_period fp
     where fp.tenant_id = r.tenant_id and fp.ledger_id = v_gl
       and current_date between fp.starts_on and fp.ends_on;
    select fp.id into v_c from erp.fiscal_period fp
     where fp.tenant_id = r.tenant_id and fp.ledger_id = v_commit
       and current_date between fp.starts_on and fp.ends_on;

    -- The month's trading, as a fixture: an order committed on COMMIT and its
    -- receipt posted on GL.
    select u.id into v_uom from erp.uom u
     where u.tenant_id = r.tenant_id and u.is_base order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (r.tenant_id, 'ZZWEA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, v_entity, 'ZZW-S', 'Close walk site', 'warehouse', 'active')
    returning id into v_site;
    perform erp.create_location(v_site, 'ZZW-RECV', 'Goods in', 'receiving');
    perform erp.create_location(v_site, 'ZZW-BULK', 'Bulk', 'bulk');
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'ZZW-SUP', 'Close Walk Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'ZZW-W', 'Close Walk Widget', v_uom, 'active')
    returning id into v_item;
    v_po := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    v_pol := erp.add_document_line(v_po, v_item, 20, 1500, 'twenty widgets');
    perform erp.transition_document(v_po, 'submit', 'close walk');
    perform erp_test.approve_document(v_po, 'close walk');
    perform erp.transition_document(v_po, 'send', 'close walk');
    v_grn := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    perform erp.receive_against(v_grn, v_pol, 20, null);
    perform erp.transition_document(v_grn, 'post', 'close walk');

    -- The organisation's controller: a role that reads the books and closes
    -- them, saved as the Roles screen saves one, and somebody holding it.
    v_role := public.erp_save_role(null, 'controller', 'Controller', 'Reads the books and closes the month',
                                   array['finance.read', 'finance.close_period']);
    res := public.erp_invite_principal('controller@' || v_code || '.test', 'Cara Controller');
    p_ctl := (res ->> 'app_user_id')::uuid;
    perform erp.grant_role(p_ctl, 'controller', null, null, 'closes the month');
    perform set_config('request.jwt.claims', json_build_object('sub', s_ctl)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    v_ctl := erp.current_principal_id();
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    update erp.environment set is_live = true where tenant_id = r.tenant_id and is_self;

    -- ─────────────────────────────────────────────────────────────────────
    -- The close: Open the close, then Close the period.
    -- ─────────────────────────────────────────────────────────────────────
    perform set_config('request.jwt.claims', json_build_object('sub', s_ctl)::text, true);
    begin
      res := to_jsonb(public.erp_open_period_close(v_p));
      v_steps := v_steps || jsonb_build_object('door', 'erp_open_period_close', 'person', 'controller', 'result', res);
      v_subs := v_subs || s_ctl;
      perform public.erp_close_period(v_p);
      v_steps := v_steps || jsonb_build_object('door', 'erp_close_period', 'person', 'controller', 'result', 'closed');
      v_subs := v_subs || s_ctl;
    exception when others then
      v_block := format('press %s: %s', jsonb_array_length(v_steps) + 1, left(sqlerrm, 300));
    end;

    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_out := jsonb_build_object(
      'role_in_force', coalesce((v_role ->> 'in_force')::boolean, false),
      'live', erp.tenant_is_live(r.tenant_id),
      'presses', jsonb_array_length(v_steps),
      'people', (select count(distinct u) from unnest(v_subs) u),
      'administrators_pressing', (select count(*) from erp.organisation_administrators() a
                                   where a.app_user_id = p_ctl),
      'traded_gl', (select count(*) from erp.journal j
                     where j.tenant_id = r.tenant_id and j.fiscal_period_id = v_p and j.status = 'posted'),
      'traded_commit', (select count(*) from erp.journal j
                         where j.tenant_id = r.tenant_id and j.fiscal_period_id = v_c and j.status = 'posted'),
      'gl', (select fp.status::text from erp.fiscal_period fp where fp.id = v_p),
      'commit', (select fp.status::text from erp.fiscal_period fp where fp.id = v_c),
      'one_moment', (select count(distinct fp.closed_at) = 1 from erp.fiscal_period fp
                      where fp.id in (v_p, v_c) and fp.closed_at is not null),
      'tasks', (select count(*) from erp.close_task t where t.tenant_id = r.tenant_id and t.fiscal_period_id = v_p),
      'completed_by_controller', (select count(*) from erp.close_task t
                                  where t.tenant_id = r.tenant_id and t.fiscal_period_id = v_p
                                    and t.status = 'complete' and t.completed_by = v_ctl),
      'waived', (select count(*) from erp.close_task t
                  where t.tenant_id = r.tenant_id and t.fiscal_period_id = v_p and t.status = 'waived'),
      'blocked', v_block,
      'steps', v_steps);

    raise exception using message = c_undo;
  exception when others then
    if sqlerrm <> c_undo then
      v_out := jsonb_build_object('presses', 0, 'people', 0, 'blocked',
                 'setting up: ' || left(sqlerrm, 300), 'steps', v_steps);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return v_out;
end;
$function$;

revoke all on function erp_test.close_walk() from public, anon;

comment on function erp_test.close_walk() is
  'A traded month closed by pressing (20260929200000), in a live organisation, by a controller who is '
  'not an administrator: Open the close, then Close the period. Returns the presses, the people, both '
  'ledgers'' states and whether they closed at one moment, and who completed the checklist. Rolled back. '
  'For erp_test.step_budget_suite, case 13.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. step_budget_suite case 13, and the money cycle says where its close is
-- ═════════════════════════════════════════════════════════════════════════════

do $step_budget_suite$
declare
  v_sig constant text := 'erp_test.step_budget_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  c_expected constant integer := 12;
  v_cases   integer := 0;
$o$,
    $n$  c_expected constant integer := 13;
  v_cases   integer := 0;
$n$,
    $o$  v_xfer    jsonb;
begin
$o$,
    $n$  v_xfer    jsonb;
  v_close   jsonb;
begin
$n$,
    $o$  if v_cases <> c_expected then
$o$,
    $n$  -- ── 13. A month closed, walked ─────────────────────────────────────────
  --
  -- The plan's target is two (20260929200000), from eight a ledger. A
  -- controller who is not an administrator, in a live organisation that
  -- traded this month on both ledgers: Open the close, which runs every
  -- check and completes the checklist, then Close the period, which asks the
  -- checks again and closes GL and COMMIT at one moment.
  v_close := erp_test.close_walk();

  v_cases := v_cases + 1;
  case_name := 'a traded month is closed in two presses by a controller who is not an administrator, open and close, and both ledgers read closed at one moment with nothing waived';
  passed := coalesce(v_close ->> 'blocked' is null
            and (v_close ->> 'role_in_force')::boolean
            and (v_close ->> 'live')::boolean
            and (v_close ->> 'administrators_pressing')::integer = 0
            and (v_close ->> 'presses')::integer = 2
            and (v_close ->> 'people')::integer = 1
            and (v_close ->> 'traded_gl')::integer > 0
            and (v_close ->> 'traded_commit')::integer > 0
            and v_close ->> 'gl' = 'closed'
            and v_close ->> 'commit' = 'closed'
            and (v_close ->> 'one_moment')::boolean
            and (v_close ->> 'tasks')::integer = 6
            and (v_close ->> 'completed_by_controller')::integer = 6
            and (v_close ->> 'waived')::integer = 0, false);
  detail := coalesce('blocked at ' || (v_close ->> 'blocked') || '; ', '')
            || format('role in force %s, live %s, %s administrator(s) pressing; %s press(es) by %s person(s); %s GL and %s COMMIT journal(s) this month; GL %s, COMMIT %s, one moment %s; %s task(s), %s completed by the controller, %s waived',
                      coalesce(v_close ->> 'role_in_force', 'unknown'), coalesce(v_close ->> 'live', 'unknown'),
                      coalesce(v_close ->> 'administrators_pressing', 'an unknown number of'),
                      coalesce(v_close ->> 'presses', '0'), coalesce(v_close ->> 'people', '0'),
                      coalesce(v_close ->> 'traded_gl', '0'), coalesce(v_close ->> 'traded_commit', '0'),
                      coalesce(v_close ->> 'gl', 'unknown'), coalesce(v_close ->> 'commit', 'unknown'),
                      coalesce(v_close ->> 'one_moment', 'unknown'),
                      coalesce(v_close ->> 'tasks', '0'), coalesce(v_close ->> 'completed_by_controller', '0'),
                      coalesce(v_close ->> 'waived', 'unknown'));
  return next;

  if v_cases <> c_expected then
$n$];
  v_hits integer;
begin
  -- Applied already: the case is there.
  if position('erp_test.close_walk()' in v_def) > 0 then
    return;
  end if;
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$step_budget_suite$;

do $assert_step_budget_suite$
declare
  v_sig constant text := 'erp_test.assert_step_budget_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  -- Counting, walked, is case 11 (20260927400000); a transfer, walked,
  -- is case 12 (20260928400000).
  c_expected constant integer := 12;
$o$;
  v_new constant text := $n$  -- Counting, walked, is case 11 (20260927400000); a transfer, walked,
  -- is case 12 (20260928400000); a month closed, walked, is case 13
  -- (20260929200000).
  c_expected constant integer := 13;
$n$;
  v_hits integer;
begin
  if position(v_new in v_def) > 0 then
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % expected-count anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$assert_step_budget_suite$;

-- The money cycle keeps its numbers (9, 9, 7, 2): they are what the Finance
-- strip draws, and the close is not on the strip. Its rationale said the close
-- was sixteen to twenty-four actions a month; it says where it is walked.
do $money_budget$
declare
  v_n integer;
begin
  if exists (select 1 from erp_meta.flow_budget b
              where b.flow_code = 'money' and position('20260929200000' in b.rationale) > 0) then
    return;
  end if;
  update erp_meta.flow_budget b
     set rationale =
       'The nine actions over seven steps are what the Finance screen''s strip draws. The period close '
       'is not on the strip, and is walked by erp_test.step_budget_suite at two presses a month, open '
       'and close, for every ledger of the company together: opening runs every check and completes '
       'the checklist, closing asks the checks again and closes GL and COMMIT at one moment. A task '
       'that fails its check is one press more, to waive it with a reason (20260929200000).'
   where b.flow_code = 'money'
     and b.budget = 9 and b.decision_steps = 9 and b.stages = 7 and b.stages_without_a_list = 2
     and b.rationale = 'Today''s cost. Period close alone is sixteen to twenty-four actions a month and is not on this strip at all, so this number understates the cycle.';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: the money flow budget is not 9/9/7/2 with the rationale 20260921420000 wrote (% row(s))', v_n;
  end if;
end
$money_budget$;
-- The generators, which are idempotent and run at the end of every migration.

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
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
-- Every move every lifecycle declares still has something that fires it, in
-- whatever database this runs against, before it commits.
select erp.assert_every_transition_is_driven();
