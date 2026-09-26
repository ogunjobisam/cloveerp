set lock_timeout = '30s';

-- =============================================================================
-- 20260929400000  The close and the cash say what the doors will take
-- -----------------------------------------------------------------------------
-- PR12 M5 (docs/spec/simplification-review.md §7 Finance): the screens of F1,
-- F2, F3 and F4, on top of the part-paid invoice (20260929100000), the
-- two-press close (20260929200000) and the cash tolerance (20260929300000).
--
-- ── WHAT CHANGES, AND WHERE ──────────────────────────────────────────────────
--
-- The close screen (/finance/close) is two buttons, Open the close and Close
-- the period, drawn only where the doors would take them, with each task's
-- check, what it said, and a waiver for what failed. What it needs of the
-- database is one reader, replaced whole:
--
--   * public.erp_close_checklist() reads the month's checklist where it is.
--     A close is raised once a month, on whichever of the month's ledgers it
--     was opened from (20260929200000), so the checklist of COMMIT 2026-09
--     is usually GL 2026-09's, and the screen said "not opened" of a month
--     that was half closed. It now says which periods close together
--     (erp.period_siblings) and on which the checklist is kept.
--   * It says what the doors would take, for the reader: can_open, and
--     can_close made stricter (the reader holds finance.close_period, the
--     month still takes postings, every task is finished, a second checklist
--     on a sibling is finished too, and every completed task's check passes
--     now, because erp.close_period asks each again). Each task carries its
--     id, what its check says when it fails (check_failure), and
--     can_complete and can_waive by the rules erp.complete_close_task
--     applies: the reader may close, the month takes postings, the task is
--     not finished, nothing it depends on is open; Complete where the check
--     passes or there is none, Waive where it is waivable and the check does
--     not pass. The database refuses regardless; this keeps the screen from
--     drawing a refusal (X4).
--
-- Apply cash said "Cash applied to 2 open items" of a receipt that also
-- wrote a penny off or kept £100 on the customer's account (20260929300000).
-- erp.apply_cash() already decided both and returned neither. Its rows gain
-- two columns, written_off_minor and on_account_minor: on the item row whose
-- short the tolerance wrote off, and on the remainder row the over-payment
-- was credited or kept on. The decision is made once, where it was; the
-- short's write-off reads the figure the row carries. The dated form, the
-- undated form and public.erp_apply_cash() return the same shape; every
-- caller reads its columns by name or performs it, so nothing else moves.
--
-- The words the screens say, seeded in English so each can be renamed, and
-- the close's help, which described five steps and a tick per task.
--
-- ── WHAT IS NOT HERE, AND WHY ────────────────────────────────────────────────
--
--   * No new door, table, lifecycle, refusal or register row. The two
--     replaced doors keep their names, arguments, gates and allowances.
--   * Part paid needs no string: its state name is 20260929100000's, and a
--     list's pill words the code.
--   * The GRNI tile's wording is 20260929000000's.
--
-- Proved by erp_test.close_and_cash_screens_suite.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- A. The close checklist reads the month's checklist, and says what it takes
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Replaced whole, and only over the body 20260919850000 left.

do $anchor_checklist$
declare
  v_src text := (select p.prosrc from pg_catalog.pg_proc p
                  where p.oid = 'public.erp_close_checklist(uuid)'::regprocedure);
begin
  if position('erp.period_siblings(' in v_src) > 0 then
    raise notice 'public.erp_close_checklist(uuid) already reads the month''s checklist; replaced with the same body';
  elsif md5(v_src) <> '53956daecf3159bc36ead21760e1a7ff' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: public.erp_close_checklist(uuid) is not the body 20260919850000 left (md5 %)', md5(v_src);
  end if;
end
$anchor_checklist$;

create or replace function public.erp_close_checklist(p_fiscal_period_id uuid default null)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant   uuid;
  v_period   uuid := p_fiscal_period_id;
  v_set      uuid[];
  v_home     uuid;
  v_row      record;
  k          record;
  v_tasks    jsonb := '[]'::jsonb;
  v_open     integer := 0;
  v_failing  integer := 0;
  v_stale    integer := 0;
  v_elsewhere integer := 0;
  v_blocked  text;
  v_state    text;
  v_blocking text;
  v_status   text;
  v_may      boolean;
  v_takes    boolean;
  v_waiting  boolean;
  v_failure  text;
  v_out      text;
begin
  -- Under whichever the caller holds: the close is worked by finance.close_-
  -- period and read by anybody in finance, which is how a controller sees where
  -- the month has got to without being able to tick anything.
  if erp.has_permission('finance.close_period') then
    perform erp.authorise('finance.close_period');
  elsif erp.has_permission('finance.read') then
    perform erp.authorise('finance.read');
  else
    perform erp.authorise('finance.close_period');
  end if;

  v_tenant := erp.require_tenant_id();
  v_may := erp.has_permission('finance.close_period');

  -- The period being closed, then the period we are in, then the last one open,
  -- then the most recent of any kind, the primary ledger first at every step.
  if v_period is null then
    select fp.id into v_period from erp.fiscal_period fp
      join erp.ledger lg on lg.tenant_id = fp.tenant_id and lg.id = fp.ledger_id
     where fp.tenant_id = v_tenant and fp.status = 'closing'
     order by lg.is_primary desc, fp.starts_on desc, fp.id limit 1;
  end if;
  if v_period is null then
    select fp.id into v_period from erp.fiscal_period fp
      join erp.ledger lg on lg.tenant_id = fp.tenant_id and lg.id = fp.ledger_id
     where fp.tenant_id = v_tenant and fp.status = 'open'
       and current_date between fp.starts_on and fp.ends_on
     order by lg.is_primary desc, fp.starts_on desc, fp.id limit 1;
  end if;
  if v_period is null then
    select fp.id into v_period from erp.fiscal_period fp
      join erp.ledger lg on lg.tenant_id = fp.tenant_id and lg.id = fp.ledger_id
     where fp.tenant_id = v_tenant and fp.status = 'open'
     order by lg.is_primary desc, fp.starts_on desc, fp.id limit 1;
  end if;
  if v_period is null then
    select fp.id into v_period from erp.fiscal_period fp
      join erp.ledger lg on lg.tenant_id = fp.tenant_id and lg.id = fp.ledger_id
     where fp.tenant_id = v_tenant
     order by lg.is_primary desc, fp.starts_on desc, fp.id limit 1;
  end if;

  if v_period is null then
    return jsonb_build_object(
      'period', null, 'tasks', '[]'::jsonb, 'state', 'no_period',
      'blocking', 'This organisation has no accounting periods yet, so there is '
                  'nothing to close.',
      'can_open', false, 'can_close', false, 'open_tasks', 0, 'failing_checks', 0,
      'siblings', '[]'::jsonb, 'checklist_period', null);
  end if;

  select fp.status::text into v_status
    from erp.fiscal_period fp where fp.tenant_id = v_tenant and fp.id = v_period;
  v_takes := erp.period_accepts_postings(v_period);

  -- The month: this period and the periods that close with it (20260929200000).
  v_set := array[v_period] || coalesce(array(
             select s.id from erp.period_siblings(v_period) s(id)), '{}'::uuid[]);

  -- The month's checklist, where erp.open_period_close raised it: on this
  -- period, or on the sibling the close was opened from.
  select ct.fiscal_period_id into v_home
    from erp.close_task ct
   where ct.tenant_id = v_tenant and ct.fiscal_period_id = any (v_set)
   order by array_position(v_set, ct.fiscal_period_id)
   limit 1;

  -- A second checklist, on a sibling that still takes postings, raised before
  -- the ledgers closed together: erp.close_period finishes it too.
  if v_home is not null then
    select count(*) into v_elsewhere
      from erp.close_task ct
     where ct.tenant_id = v_tenant
       and ct.fiscal_period_id = any (v_set) and ct.fiscal_period_id <> v_home
       and erp.period_accepts_postings(ct.fiscal_period_id)
       and ct.status not in ('complete', 'waived');
  end if;

  -- erp.close_status() is the governed reader and stays it; this joins what it
  -- returns to the task rows for the half it does not carry.
  for v_row in
    select ct.id as task_id, cs.code, cs.name, cs.seq, cs.status, cs.blocking_check,
           cs.is_waivable, cs.blocked_by, cs.check_passes,
           ct.completed_at, ct.waiver_reason, ct.check_output,
           u.display_name as completed_by,
           tm.owner_role_code
      from erp.close_status(v_home) cs
      join erp.close_task ct
        on ct.tenant_id = v_tenant and ct.fiscal_period_id = v_home
       and ct.code = cs.code
      left join erp.app_user u
        on u.tenant_id = v_tenant and u.id = ct.completed_by
      left join erp.close_task_template tm
        on tm.tenant_id = v_tenant and tm.code = ct.code
     where v_home is not null
     order by cs.seq, cs.code
  loop
    v_waiting := v_row.status not in ('complete', 'waived');

    -- What the check says when it does not pass, in its own words: asked
    -- again, because erp.close_status() answers only whether.
    v_failure := null;
    if v_row.check_passes is false then
      begin
        execute format('select %s', v_row.blocking_check) into v_out;
      exception when others then
        v_failure := sqlerrm;
      end;
    end if;

    if v_waiting then
      v_open := v_open + 1;
      if v_row.check_passes is false then
        v_failing := v_failing + 1;
      end if;
      if v_blocked is null then
        v_blocked := v_row.name;
      end if;
    elsif v_row.status = 'complete' and v_row.check_passes is false then
      -- Completed, and failing now: erp.close_period() asks it again and
      -- refuses.
      v_stale := v_stale + 1;
    end if;

    v_tasks := v_tasks || jsonb_build_array(jsonb_build_object(
      'task_id', v_row.task_id,
      'code', v_row.code, 'name', v_row.name, 'seq', v_row.seq,
      'status', v_row.status,
      'blocking_check', v_row.blocking_check,
      'is_waivable', v_row.is_waivable,
      'blocked_by', v_row.blocked_by,
      'check_passes', v_row.check_passes,
      'check_failure', v_failure,
      'completed_by', v_row.completed_by,
      'completed_at', v_row.completed_at,
      'waiver_reason', v_row.waiver_reason,
      'check_output', v_row.check_output,
      'owner_role_code', v_row.owner_role_code,
      -- erp.complete_close_task()'s own rules, for this reader: nothing it
      -- depends on open, a check that passes or none, and no waiver of a tie.
      'can_complete', v_may and v_takes and v_waiting and v_row.blocked_by is null
                      and v_row.check_passes is distinct from false,
      'can_waive', v_may and v_takes and v_waiting and v_row.blocked_by is null
                   and v_row.is_waivable and v_row.check_passes is distinct from true));
  end loop;

  -- And a completed task on that second checklist whose check fails now,
  -- which erp.close_period() asks again too.
  for k in
    select distinct nullif(btrim(coalesce(ct.blocking_check, '')), '') as check_call
      from erp.close_task ct
     where v_home is not null
       and ct.tenant_id = v_tenant
       and ct.fiscal_period_id = any (v_set) and ct.fiscal_period_id <> v_home
       and erp.period_accepts_postings(ct.fiscal_period_id)
       and ct.status = 'complete'
  loop
    continue when k.check_call is null;
    begin
      execute format('select %s', k.check_call) into v_out;
    exception when others then
      v_stale := v_stale + 1;
    end;
  end loop;

  v_state := case
               when v_status in ('closed', 'permanently_closed') then 'closed'
               when jsonb_array_length(v_tasks) = 0 then 'not_opened'
               when v_open = 0 then 'ready'
               else 'in_progress'
             end;

  v_blocking := case v_state
    when 'closed'     then null::text
    when 'not_opened' then 'The close has not been opened for this period, so no '
                           'checklist has been raised yet.'
    when 'ready'      then null::text
    else format('%s is not done yet%s.', v_blocked,
                case when v_failing > 0
                     then format(', and %s of the tasks left carry a check that does not pass right now', v_failing)
                     else '' end)
  end;

  return jsonb_build_object(
    'period', (select jsonb_build_object(
                 'fiscal_period_id', fp.id, 'code', fp.code,
                 'status', fp.status, 'starts_on', fp.starts_on,
                 'ends_on', fp.ends_on, 'ledger', lg.code,
                 'closed_at', fp.closed_at)
                 from erp.fiscal_period fp
                 join erp.ledger lg on lg.tenant_id = fp.tenant_id and lg.id = fp.ledger_id
                where fp.tenant_id = v_tenant and fp.id = v_period),
    'tasks', v_tasks,
    'state', v_state,
    'blocking', v_blocking,
    -- erp.open_period_close() raises the checklist, or runs the checks again
    -- over what it left open; it has nothing to do for a closed month.
    'can_open', v_may and v_takes and v_state <> 'closed'
                and (jsonb_array_length(v_tasks) > 0
                     or exists (select 1 from erp.close_task_template t
                                 where t.tenant_id = v_tenant and t.status = 'active')),
    -- erp.close_period() closes a month whose every task is finished, on
    -- every checklist of it, and whose completed tasks still pass.
    'can_close', v_may and v_takes and v_state = 'ready' and v_stale = 0 and v_elsewhere = 0,
    'open_tasks', v_open,
    'failing_checks', v_failing,
    'failing_since_completed', v_stale,
    'siblings', coalesce((
      select jsonb_agg(jsonb_build_object(
               'fiscal_period_id', fp.id, 'code', fp.code,
               'status', fp.status, 'ledger', lg.code)
             order by array_position(v_set, fp.id))
        from erp.fiscal_period fp
        join erp.ledger lg on lg.tenant_id = fp.tenant_id and lg.id = fp.ledger_id
       where fp.tenant_id = v_tenant and fp.id = any (v_set) and fp.id <> v_period), '[]'::jsonb),
    'checklist_period', (select jsonb_build_object(
                 'fiscal_period_id', fp.id, 'code', fp.code, 'ledger', lg.code)
                 from erp.fiscal_period fp
                 join erp.ledger lg on lg.tenant_id = fp.tenant_id and lg.id = fp.ledger_id
                where fp.tenant_id = v_tenant and fp.id = v_home));
end;
$$;

comment on function public.erp_close_checklist(uuid) is
  'The period close as a person works it: the period being closed, the periods that close with it '
  '(erp.period_siblings), the month''s checklist wherever it was raised, every task with its state, who '
  'completed or waived it and when, the dependency it is waiting on, whether its blocking check would '
  'pass right now and what it says when it does not, and the one sentence saying what is stopping the '
  'close. Says what the doors would take for this reader: can_open, can_close, and each task''s '
  'can_complete and can_waive, by the rules erp.open_period_close, erp.close_period and '
  'erp.complete_close_task apply. Resolves the period when none is named. Invoker throughout, so it '
  'answers for the caller''s organisation only (20260929400000).';

revoke all on function public.erp_close_checklist(uuid) from public, anon;
grant execute on function public.erp_close_checklist(uuid) to authenticated, service_role;

-- The close's help described a tick per task.
update erp_ref.help_topic
   set summary = 'The close of the month being closed right now, on every ledger that closes with it. Opening the close runs every task''s check and completes each one that passes; what fails is shown with what its check said. Closing asks the checks again and closes the month''s ledgers, GL and COMMIT, at one moment. Three of the tasks carry one of the four ties the accounts are proved by and cannot be waived at all.',
       steps = '["Open the close. Every task''s check runs, and each task that passes is completed as you.","Read what is left. A task whose check fails says what the check said; a task waiting on another says which.","Fix the difference a check names and run the checks again, or waive a task that is a judgement rather than a tie, with a reason that will be read at audit. The tie tasks refuse a waiver by name.","Close the period once nothing is left. The checks are asked again, and the month closes on every ledger together. Nothing more posts into it unless it is reopened."]',
       next_action = 'Open the close, deal with what fails, then close the period.'
 where screen_path = '/finance/close';

-- ═════════════════════════════════════════════════════════════════════════════
-- B. Apply cash says what it wrote off and what it kept on account
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The dated form is edited, not rewritten: five anchors over the body
-- 20260929300000 left. A set-returning function's columns are part of its
-- type, so the three forms are dropped and made again with the same
-- arguments, owner, grants and comments, in one block, so the raises of the
-- dated form stay where erp.refusal_report() and preflight rule B read them. Every caller reads them by name or
-- performs them; public.erp_apply_cash() keeps its allowance, which is by
-- name.

do $apply_cash$
declare
  v_sig  constant text := 'erp.apply_cash(uuid,bigint,character,text,date)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$RETURNS TABLE(subledger_item_id uuid, applied_minor bigint, remaining_minor bigint)$o$,
    $n$RETURNS TABLE(subledger_item_id uuid, applied_minor bigint, remaining_minor bigint, written_off_minor bigint, on_account_minor bigint)$n$,

    $o$  v_applied     bigint := 0;
$o$,
    $n$  v_applied     bigint := 0;
  -- What the receipt wrote off within the tolerance, short on its last item or
  -- over after every item, and what it kept on the customer's account: said
  -- on the row they belong to (20260929400000).
  v_short_written bigint := 0;
  v_over_written  bigint := 0;
  v_kept          bigint := 0;
$n$,

    $o$    applied_minor := v_take;
    v_left := v_left - v_take;
    remaining_minor := v_left;
    return next;
$o$,
    $n$    applied_minor := v_take;
    v_left := v_left - v_take;
    remaining_minor := v_left;
    -- The receipt ends on this item, and short of it by no more than the
    -- tolerance: the rest is written off after the loop, and this row says
    -- so. Decided here, once, and read there (20260929400000).
    if v_left = 0 and v_last_short > 0
       and v_last_short <= erp.settlement_tolerance_minor(v_last_entity, v_last_gross) then
      v_short_written := v_last_short;
    end if;
    written_off_minor := v_short_written;
    on_account_minor := 0;
    return next;
$n$,

    $o$  if v_left = 0 and v_last_short > 0
     and v_last_short <= erp.settlement_tolerance_minor(v_last_entity, v_last_gross) then
    perform erp.post_settlement_difference(v_last, v_last_short, p_received_on, p_reference);
  elsif v_left > 0 then
    if v_left <= erp.settlement_tolerance_minor(v_last_entity, v_applied) then
      perform erp.post_settlement_difference(v_last, -v_left, p_received_on, p_reference);
    else
      perform erp.post_cash_on_account(v_last, v_left, p_received_on, p_reference);
    end if;
  end if;
$o$,
    $n$  if v_short_written > 0 then
    perform erp.post_settlement_difference(v_last, v_short_written, p_received_on, p_reference);
  elsif v_left > 0 then
    if v_left <= erp.settlement_tolerance_minor(v_last_entity, v_applied) then
      perform erp.post_settlement_difference(v_last, -v_left, p_received_on, p_reference);
      v_over_written := v_left;
    else
      perform erp.post_cash_on_account(v_last, v_left, p_received_on, p_reference);
      v_kept := v_left;
    end if;
  end if;
$n$,

    $o$    applied_minor := 0;
    remaining_minor := v_left;
    return next;
$o$,
    $n$    applied_minor := 0;
    remaining_minor := v_left;
    written_off_minor := v_over_written;
    on_account_minor := v_kept;
    return next;
$n$];
  v_hits integer;
begin
  if pg_catalog.pg_get_function_result(v_sig::regprocedure) like '%on_account_minor%' then
    raise notice '% already says what it wrote off and kept; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'd9407c45cf1d9cf729c306adcf172504' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20260929300000 left (md5 %)', v_sig, md5(v_src);
  end if;
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;

  drop function public.erp_apply_cash(uuid, bigint, character, text);
  drop function erp.apply_cash(uuid, bigint, character, text);
  drop function erp.apply_cash(uuid, bigint, character, text, date);
  execute v_def;

  -- The undated form and the desk's door, as they were, in the new shape.
  -- Made here, with the dated form, because each is dropped with it and a
  -- second run of this migration finds all three made already.
  execute $w$
    create function erp.apply_cash(
      p_party_id uuid, p_amount_minor bigint, p_currency character, p_reference text default null)
    returns table(subledger_item_id uuid, applied_minor bigint, remaining_minor bigint,
                  written_off_minor bigint, on_account_minor bigint)
    language sql
    set search_path = ''
    as $b$
      select * from erp.apply_cash(p_party_id, p_amount_minor, p_currency, p_reference, current_date);
    $b$
  $w$;
  execute $w$
    create function public.erp_apply_cash(
      p_party_id uuid, p_amount_minor bigint, p_currency character, p_reference text default null)
    returns table(subledger_item_id uuid, applied_minor bigint, remaining_minor bigint,
                  written_off_minor bigint, on_account_minor bigint)
    language sql
    set search_path = ''
    as $b$ select * from erp.apply_cash(p_party_id, p_amount_minor, p_currency, p_reference) $b$
  $w$;
end
$apply_cash$;

comment on function erp.apply_cash(uuid, bigint, character, text, date) is
  'Applies a receipt against a party''s open receivables, oldest first across every company the party '
  'owes. Each company''s share is posted in that company''s ledger against its own bank account, because '
  'cash banked in another company''s name is a receipt that reconciles nowhere. A document the receipt '
  'leaves owing nothing is settled in the same transaction (20260919200000). The whole receipt is '
  'banked, and the settlement tolerance decides the rest (20260929300000). A row per item it reached, '
  'and one for a remainder; written_off_minor on the item row whose short was written off within the '
  'tolerance, or on the remainder row credited to settlement differences, and on_account_minor on the '
  'remainder row kept on the customer''s account (20260929400000).';

comment on function erp.apply_cash(uuid, bigint, character, text) is
  'erp.apply_cash() dated today. The form every existing caller uses; the dated form is the one that does the work.';

revoke all on function erp.apply_cash(uuid, bigint, character, text, date) from public, anon;
revoke all on function erp.apply_cash(uuid, bigint, character, text) from public, anon;
revoke all on function public.erp_apply_cash(uuid, bigint, character, text) from public, anon;
grant execute on function erp.apply_cash(uuid, bigint, character, text, date) to authenticated, service_role;
grant execute on function erp.apply_cash(uuid, bigint, character, text) to authenticated, service_role;
grant execute on function public.erp_apply_cash(uuid, bigint, character, text) to authenticated, service_role;

-- ═════════════════════════════════════════════════════════════════════════════
-- C. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.close_and_cash_screens_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 14;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  s_read   uuid := gen_random_uuid();
  rb       record;
  res      jsonb;
  v_step   text := 'provisioning';
  v_state  text;
  v_owner  text := current_user;
  v_entity uuid; v_site uuid; v_uom uuid; v_ccy char(3); v_item uuid;
  v_gl uuid; v_commit uuid; v_gl_code text;
  v_p uuid; v_c uuid;
  v_raised integer;
  v_gl_read jsonb; v_c_read jsonb; v_reader jsonb; v_ready jsonb; v_stale jsonb;
  v_closed_gl jsonb; v_closed_c jsonb;
  v_grni jsonb; v_own jsonb; v_none jsonb; v_after jsonb;
  v_t_grni uuid; v_t_own uuid; v_t_none uuid; v_t_after uuid;
  v_inv uuid; v_cust uuid; v_gross bigint;
  v_rows jsonb;
begin
  begin
    -- ── The fixture: an organisation configured as the demonstration is ─────
    v_step := 'an organisation that invoices, banks a receipt and closes its months';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzccs-' || v_tag, 'Close And Cash Screens Suite',
      'admin@zzccs-' || v_tag || '.test', 'Close Screens Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@zzccs-' || v_tag || '.test'),
           (s_read, 'reader@zzccs-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    perform erp.configure_period_close();

    v_step := 'a person who may read the books but not close them';
    res := public.erp_invite_principal('reader@zzccs-' || v_tag || '.test', 'Rhea Reader');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'observer', null, null, 'reads the books');
    perform set_config('request.jwt.claims', json_build_object('sub', s_read)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_step := 'its company, ledgers, a month and its sibling, a site and a product';
    select e.id, e.base_currency into v_entity, v_ccy
      from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select l.id, l.code into strict v_gl, v_gl_code from erp.ledger l
     where l.tenant_id = rb.tenant_id and l.entity_id = v_entity and l.is_primary;
    select l.id into strict v_commit from erp.ledger l
     where l.tenant_id = rb.tenant_id and l.entity_id = v_entity and l.ledger_kind = 'management'
       and l.status = 'active';
    -- A month that is not this one, so the receipts below have a month to post in.
    select fp.id into strict v_p from erp.fiscal_period fp
     where fp.tenant_id = rb.tenant_id and fp.ledger_id = v_gl
       and not (current_date between fp.starts_on and fp.ends_on)
       and erp.period_accepts_postings(fp.id)
     order by fp.starts_on limit 1;
    select s.id into strict v_c from erp.fiscal_period s join erp.fiscal_period fp on fp.id = v_p
     where s.tenant_id = rb.tenant_id and s.ledger_id = v_commit and s.starts_on = fp.starts_on;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    if v_site is null then
      insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
      values (rb.tenant_id, v_entity, 'ZSMAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    end if;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (rb.tenant_id, 'ZSEA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZSWID', 'Close Screens Widget', v_uom, 'active') returning id into v_item;

    -- ── 1. Not opened ───────────────────────────────────────────────────────
    v_step := 'the month read before its close is opened';
    v_gl_read := public.erp_close_checklist(v_p);
    v_cases := v_cases + 1;
    case_name := 'before the close is opened the month offers Open and not Close, and names the COMMIT month that closes with it';
    passed := v_state is null
          and v_gl_read ->> 'state' = 'not_opened'
          and (v_gl_read ->> 'can_open')::boolean
          and not (v_gl_read ->> 'can_close')::boolean
          and jsonb_typeof(v_gl_read -> 'checklist_period') = 'null'
          and jsonb_array_length(v_gl_read -> 'siblings') = 1
          and v_gl_read -> 'siblings' -> 0 ->> 'fiscal_period_id' = v_c::text;
    detail := coalesce(v_state, left(format('state %s, open %s, close %s, siblings %s',
      v_gl_read ->> 'state', v_gl_read ->> 'can_open', v_gl_read ->> 'can_close', v_gl_read -> 'siblings'), 300));
    return next;

    -- ── 2. Opened from GL, read from COMMIT ─────────────────────────────────
    v_step := 'the close opened on GL and read from COMMIT';
    v_raised := erp.open_period_close(v_p);
    v_c_read := public.erp_close_checklist(v_c);
    v_cases := v_cases + 1;
    case_name := 'a close opened on GL reads from COMMIT as GL''s checklist, every task done on clean books, ready to close from either ledger';
    passed := v_state is null
          and v_c_read ->> 'state' = 'ready'
          and v_c_read -> 'checklist_period' ->> 'fiscal_period_id' = v_p::text
          and v_c_read -> 'checklist_period' ->> 'ledger' = v_gl_code
          and jsonb_array_length(v_c_read -> 'tasks') = v_raised
          and (v_c_read ->> 'can_close')::boolean
          and v_c_read -> 'siblings' -> 0 ->> 'fiscal_period_id' = v_p::text
          and not exists (select 1 from jsonb_array_elements(v_c_read -> 'tasks') t
                           where (t ->> 'can_complete')::boolean or (t ->> 'can_waive')::boolean
                              or t ->> 'task_id' is null);
    detail := coalesce(v_state, left(format('state %s on %s, %s task(s) of %s raised, close %s',
      v_c_read ->> 'state', v_c_read -> 'checklist_period', jsonb_array_length(v_c_read -> 'tasks'),
      v_raised, v_c_read ->> 'can_close'), 300));
    return next;

    -- ── 3. What fails, and what may be done about it ────────────────────────
    -- A waivable task whose check fails, a check of the organisation's own
    -- that may not be waived, and a task nothing checks.
    v_step := 'three tasks that are not done';
    select t.id into strict v_t_grni from erp.close_task t
     where t.fiscal_period_id = v_p and t.code = 'grni_reviewed';
    update erp.close_task
       set status = 'open', completed_at = null, completed_by = null, check_output = null,
           blocking_check = '(select 1/0)'
     where id = v_t_grni;
    insert into erp.close_task (tenant_id, fiscal_period_id, code, name, seq, depends_on,
                                blocking_check, is_waivable)
    values (rb.tenant_id, v_p, 'zz_own_check', 'Our own check', 91, '{}', '(select 1/0)', false)
    returning id into v_t_own;
    insert into erp.close_task (tenant_id, fiscal_period_id, code, name, seq, depends_on,
                                blocking_check, is_waivable)
    values (rb.tenant_id, v_p, 'zz_no_check', 'Nothing checks this', 92, '{}', null, true)
    returning id into v_t_none;
    insert into erp.close_task (tenant_id, fiscal_period_id, code, name, seq, depends_on,
                                blocking_check, is_waivable)
    values (rb.tenant_id, v_p, 'zz_after', 'Read after the goods received', 93, '{grni_reviewed}',
            '(select 1)', true)
    returning id into v_t_after;

    v_gl_read := public.erp_close_checklist(v_p);
    select t into v_grni from jsonb_array_elements(v_gl_read -> 'tasks') t where t ->> 'code' = 'grni_reviewed';
    select t into v_own from jsonb_array_elements(v_gl_read -> 'tasks') t where t ->> 'code' = 'zz_own_check';
    select t into v_none from jsonb_array_elements(v_gl_read -> 'tasks') t where t ->> 'code' = 'zz_no_check';
    select t into v_after from jsonb_array_elements(v_gl_read -> 'tasks') t where t ->> 'code' = 'zz_after';
    v_cases := v_cases + 1;
    case_name := 'a failing waivable task says what its check said and offers Waive, not Complete; a check that may not be waived offers neither; a task nothing checks offers both; a task waiting on another offers nothing, though its own check passes';
    passed := v_state is null
          and v_grni ->> 'task_id' = v_t_grni::text
          and not (v_grni ->> 'check_passes')::boolean
          and v_grni ->> 'check_failure' like '%division by zero%'
          and (v_grni ->> 'can_waive')::boolean and not (v_grni ->> 'can_complete')::boolean
          and v_own ->> 'check_failure' like '%division by zero%'
          and not (v_own ->> 'can_waive')::boolean and not (v_own ->> 'can_complete')::boolean
          and jsonb_typeof(v_none -> 'check_failure') = 'null'
          and (v_none ->> 'can_complete')::boolean and (v_none ->> 'can_waive')::boolean
          and v_after ->> 'blocked_by' = 'grni_reviewed' and (v_after ->> 'check_passes')::boolean
          and not (v_after ->> 'can_complete')::boolean and not (v_after ->> 'can_waive')::boolean;
    detail := coalesce(v_state, left(format('grni %s; own %s; none %s; after %s', v_grni, v_own, v_none, v_after), 800));
    return next;

    v_cases := v_cases + 1;
    case_name := 'while tasks are left the month is in progress: the checks can be run again, and Close is not offered';
    passed := v_state is null
          and v_gl_read ->> 'state' = 'in_progress'
          and (v_gl_read ->> 'can_open')::boolean
          and not (v_gl_read ->> 'can_close')::boolean
          and (v_gl_read ->> 'open_tasks')::integer = 4
          and (v_gl_read ->> 'failing_checks')::integer = 2;
    detail := coalesce(v_state, format('state %s, open %s, close %s, %s open, %s failing',
      v_gl_read ->> 'state', v_gl_read ->> 'can_open', v_gl_read ->> 'can_close',
      v_gl_read ->> 'open_tasks', v_gl_read ->> 'failing_checks'));
    return next;

    -- ── 4. The reader ───────────────────────────────────────────────────────
    v_step := 'the same month read by somebody who may not close it';
    perform set_config('request.jwt.claims', json_build_object('sub', s_read)::text, true);
    v_reader := public.erp_close_checklist(v_p);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'finance.read sees the same checklist and is offered nothing: no Open, no Close, no Complete and no Waive';
    passed := v_state is null
          and v_reader ->> 'state' = 'in_progress'
          and jsonb_array_length(v_reader -> 'tasks') = jsonb_array_length(v_gl_read -> 'tasks')
          and not (v_reader ->> 'can_open')::boolean
          and not (v_reader ->> 'can_close')::boolean
          and not exists (select 1 from jsonb_array_elements(v_reader -> 'tasks') t
                           where (t ->> 'can_complete')::boolean or (t ->> 'can_waive')::boolean);
    detail := coalesce(v_state, left(format('state %s, open %s, close %s', v_reader ->> 'state',
      v_reader ->> 'can_open', v_reader ->> 'can_close'), 300));
    return next;

    -- ── 5. Dealt with, it is ready ──────────────────────────────────────────
    v_step := 'the failure waived, the own check fixed, and the unchecked and the waiting tasks completed';
    perform public.erp_complete_close_task(v_t_grni, 'Reviewed with the buyer: a planted difference');
    update erp.close_task set blocking_check = '(select 1)' where id = v_t_own;
    perform public.erp_complete_close_task(v_t_own, null);
    perform public.erp_complete_close_task(v_t_none, null);
    perform public.erp_complete_close_task(v_t_after, null);
    v_ready := public.erp_close_checklist(v_c);
    v_cases := v_cases + 1;
    case_name := 'what the screen offered the doors took: the waiver, then Complete, and the task that waited on the waiver; the month is ready and offers Close';
    passed := v_state is null
          and v_ready ->> 'state' = 'ready'
          and (v_ready ->> 'can_close')::boolean
          and (select t.status from erp.close_task t where t.id = v_t_grni) = 'waived'
          and (select t.status from erp.close_task t where t.id = v_t_own) = 'complete';
    detail := coalesce(v_state, format('state %s, close %s', v_ready ->> 'state', v_ready ->> 'can_close'));
    return next;

    -- ── 6. Completed, and failing since ─────────────────────────────────────
    v_step := 'a completed task whose check fails now';
    update erp.close_task set blocking_check = '(select 1/0)' where id = v_t_own;
    v_stale := public.erp_close_checklist(v_p);
    update erp.close_task set blocking_check = '(select 1)' where id = v_t_own;
    v_cases := v_cases + 1;
    case_name := 'a task completed whose check fails now keeps the month ready and withholds Close, because erp.close_period asks it again';
    passed := v_state is null
          and v_stale ->> 'state' = 'ready'
          and not (v_stale ->> 'can_close')::boolean
          and (v_stale ->> 'failing_since_completed')::integer = 1;
    detail := coalesce(v_state, format('state %s, close %s, %s failing since completed',
      v_stale ->> 'state', v_stale ->> 'can_close', v_stale ->> 'failing_since_completed'));
    return next;

    -- ── 7. Closed from COMMIT ───────────────────────────────────────────────
    v_step := 'the month closed from COMMIT';
    perform public.erp_close_period(v_c);
    v_closed_gl := public.erp_close_checklist(v_p);
    v_closed_c := public.erp_close_checklist(v_c);
    v_cases := v_cases + 1;
    case_name := 'closed from COMMIT, both ledgers read closed on the one checklist, and nothing is offered on either';
    passed := v_state is null
          and v_closed_gl ->> 'state' = 'closed' and v_closed_c ->> 'state' = 'closed'
          and v_closed_c -> 'checklist_period' ->> 'fiscal_period_id' = v_p::text
          and not (v_closed_gl ->> 'can_open')::boolean and not (v_closed_gl ->> 'can_close')::boolean
          and not (v_closed_c ->> 'can_open')::boolean and not (v_closed_c ->> 'can_close')::boolean
          and not exists (select 1 from jsonb_array_elements(v_closed_c -> 'tasks') t
                           where (t ->> 'can_complete')::boolean or (t ->> 'can_waive')::boolean);
    detail := coalesce(v_state, format('GL %s, COMMIT %s', v_closed_gl ->> 'state', v_closed_c ->> 'state'));
    return next;

    -- ── 8. Apply cash, a penny short ────────────────────────────────────────
    v_step := 'an invoice paid a penny short through the desk''s door';
    v_inv := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZSC8', 50000);
    select dv.gross_minor::bigint, d.party_id into v_gross, v_cust
      from erp.document_view dv join erp.document d on d.id = dv.id where dv.id = v_inv;
    select jsonb_agg(to_jsonb(x)) into v_rows
      from public.erp_apply_cash(v_cust, v_gross - 1, v_ccy, 'ZSC8-RECEIPT') x;
    v_cases := v_cases + 1;
    case_name := 'a penny short at £1: the item''s row says the penny was written off, nothing was kept on account, and there is no remainder row';
    passed := v_state is null
          and jsonb_array_length(v_rows) = 1
          and (v_rows -> 0 ->> 'written_off_minor')::bigint = 1
          and (v_rows -> 0 ->> 'on_account_minor')::bigint = 0
          and (v_rows -> 0 ->> 'applied_minor')::bigint = v_gross - 1
          and erp.object_current_state('document', v_inv) = 'paid';
    detail := coalesce(v_state, left(coalesce(v_rows::text, 'no rows'), 300));
    return next;

    -- ── 9. £100 over ────────────────────────────────────────────────────────
    v_step := 'an invoice paid £100 over';
    v_inv := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZSC9', 50000);
    select dv.gross_minor::bigint, d.party_id into v_gross, v_cust
      from erp.document_view dv join erp.document d on d.id = dv.id where dv.id = v_inv;
    select jsonb_agg(to_jsonb(x)) into v_rows
      from public.erp_apply_cash(v_cust, v_gross + 10000, v_ccy, 'ZSC9-RECEIPT') x;
    v_cases := v_cases + 1;
    case_name := '£100 over: the item row writes nothing off, and the remainder row says £100 was kept on the customer''s account';
    passed := v_state is null
          and jsonb_array_length(v_rows) = 2
          and (v_rows -> 0 ->> 'written_off_minor')::bigint = 0
          and jsonb_typeof(v_rows -> 1 -> 'subledger_item_id') = 'null'
          and (v_rows -> 1 ->> 'on_account_minor')::bigint = 10000
          and (v_rows -> 1 ->> 'written_off_minor')::bigint = 0;
    detail := coalesce(v_state, left(coalesce(v_rows::text, 'no rows'), 300));
    return next;

    -- ── 10. A penny over ────────────────────────────────────────────────────
    v_step := 'an invoice paid a penny over';
    v_inv := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZSC10', 50000);
    select dv.gross_minor::bigint, d.party_id into v_gross, v_cust
      from erp.document_view dv join erp.document d on d.id = dv.id where dv.id = v_inv;
    select jsonb_agg(to_jsonb(x)) into v_rows
      from public.erp_apply_cash(v_cust, v_gross + 1, v_ccy, 'ZSC10-RECEIPT') x;
    v_cases := v_cases + 1;
    case_name := 'a penny over at £1: the remainder row says the penny was written off within the tolerance, and nothing was kept on account';
    passed := v_state is null
          and jsonb_array_length(v_rows) = 2
          and (v_rows -> 1 ->> 'written_off_minor')::bigint = 1
          and (v_rows -> 1 ->> 'on_account_minor')::bigint = 0;
    detail := coalesce(v_state, left(coalesce(v_rows::text, 'no rows'), 300));
    return next;

    -- ── 11. Short beyond the tolerance ──────────────────────────────────────
    v_step := 'an invoice paid £1.01 short';
    v_inv := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZSC11', 50000);
    select dv.gross_minor::bigint, d.party_id into v_gross, v_cust
      from erp.document_view dv join erp.document d on d.id = dv.id where dv.id = v_inv;
    select jsonb_agg(to_jsonb(x)) into v_rows
      from public.erp_apply_cash(v_cust, v_gross - 101, v_ccy, 'ZSC11-RECEIPT') x;
    v_cases := v_cases + 1;
    case_name := 'short by £1.01 is outside £1: the row writes nothing off and keeps nothing, and the invoice is Part paid';
    passed := v_state is null
          and jsonb_array_length(v_rows) = 1
          and (v_rows -> 0 ->> 'written_off_minor')::bigint = 0
          and (v_rows -> 0 ->> 'on_account_minor')::bigint = 0
          and (v_rows -> 0 ->> 'remaining_minor')::bigint = 0
          and erp.object_current_state('document', v_inv) = 'part_paid';
    detail := coalesce(v_state, left(coalesce(v_rows::text, 'no rows'), 300));
    return next;

    -- ── 12. One shape ───────────────────────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'the dated form, the undated form and the desk''s door answer in the same five columns';
    passed := v_state is null
          and pg_catalog.pg_get_function_result('erp.apply_cash(uuid,bigint,character,text,date)'::regprocedure)
            = pg_catalog.pg_get_function_result('erp.apply_cash(uuid,bigint,character,text)'::regprocedure)
          and pg_catalog.pg_get_function_result('erp.apply_cash(uuid,bigint,character,text)'::regprocedure)
            = pg_catalog.pg_get_function_result('public.erp_apply_cash(uuid,bigint,character,text)'::regprocedure)
          and pg_catalog.pg_get_function_result('public.erp_apply_cash(uuid,bigint,character,text)'::regprocedure)
            like '%written_off_minor bigint, on_account_minor bigint)';
    detail := coalesce(v_state, pg_catalog.pg_get_function_result('public.erp_apply_cash(uuid,bigint,character,text)'::regprocedure));
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
        and not exists (select 1 from erp.tenant t where t.code = 'zzccs-' || v_tag)
        and not exists (select 1 from auth.users u where u.id in (a1, s_read))
        and current_user = v_owner;
  detail := coalesce(v_state, 'zzccs rolled back with its invoices, receipts, periods and close');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_CLOSE_AND_CASH_SCREENS_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.close_and_cash_screens_suite() from public, anon;

comment on function erp_test.close_and_cash_screens_suite() is
  'What the close and Apply cash screens read (20260929400000). The checklist of a COMMIT month is '
  'its GL month''s; Open, Close, Complete and Waive are offered by the rules the doors apply, to '
  'somebody who may close and to nobody who may only read; a completed check failing since withholds '
  'Close; a closed month offers nothing. Apply cash says on its rows what it wrote off within the '
  'tolerance, short or over, and what it kept on the customer''s account, in one shape across its '
  'three forms.';

create or replace function erp_test.assert_close_and_cash_screens_suite()
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
    from erp_test.close_and_cash_screens_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_CLOSE_AND_CASH_SCREENS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'The close screen or Apply cash would draw what a door refuses, or hide what it did. Read the case that failed.';
  end if;
  if v_total <> 14 then
    raise exception 'CLOVEERP_CLOSE_AND_CASH_SCREENS_SUITE_SHRANK: % case(s), expected 14', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('close and cash screens: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_close_and_cash_screens_suite() from public, anon;

comment on function erp_test.assert_close_and_cash_screens_suite() is
  'The close screen offers what its doors take, reading the month''s checklist from either ledger, and '
  'Apply cash says what it wrote off and kept on account (20260929400000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- D. The words the screens say
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). The period close in two presses, its waiver, and the period close verbs (20260929400000).'
  from (values
    ('A check that passed when its task was completed fails now. Run the checks again.'),
    ('Another period'),
    ('Asks every completed task''s check again, then closes the month on every ledger that closes with it. Nothing more is posted into it unless it is reopened.'),
    ('Check fails'),
    ('Close the period'),
    ('Closes together with'),
    ('Fix what the check names, then run the checks again'),
    ('For a task opening the close left open: waive one whose check fails, with the reason it is passed, or complete one nothing checks by leaving the reason empty. The four ties cannot be waived.'),
    ('Nothing checks this task'),
    ('Open the close'),
    ('Open the close, which runs every check; waive what fails with a reason; close the period, and its ledgers close together. At the end of the year close the year for good.'),
    ('Opens the month on every ledger that closes with it, runs every task''s check, and completes each one that passes. What fails is left for a waiver.'),
    ('Read at audit, beside what the check said.'),
    ('Read at audit. Leave it empty only to complete a task nothing checks.'),
    ('Run the checks again'),
    ('The month''s checklist is kept on'),
    ('The same three doors, with the period or task chosen: for a month other than the one above.'),
    ('The task is passed without its check, and the reason is kept with it for audit. Closing does not ask a waived task again.'),
    ('Waive'),
    ('Waive a close task'),
    ('What the check said'),
    ('Why it is passed')
  ) as v(text)
on conflict (key, locale) do nothing;

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
