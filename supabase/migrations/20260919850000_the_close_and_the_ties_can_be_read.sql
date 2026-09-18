-- The close and the ties can be read.
--
-- Two mechanisms in this database prove the accounts are right, and until this
-- migration a customer could not see either of them.
--
-- ── One: the close checklist had a reader nobody reads ────────────────────────
--
-- erp.close_task_template and erp.close_task have existed since 20260829300000.
-- erp.close_status(uuid) reads a period's checklist with every task, what is
-- blocking each one, whether its check would pass right now, and — since
-- 20260918400000 — whether it may be waived at all. public.erp_close_status()
-- is to_jsonb() over it and has been granted to authenticated the whole time.
--
-- Nothing calls it. The name appears in src exactly five times and every one is
-- an `invalidates:` key in src/lib/modules.tsx — the desk marks the read stale
-- after each close action and never performs it. public.erp_close_tasks() is
-- reached, and only as the options of one dropdown: a person completing a task
-- picks it from a list of code/status pairs across every period, with nothing
-- on the screen saying which period is closing, what is left, who did what, or
-- what the close is waiting for. The control existed; the checklist did not.
--
-- ── Two: the reconciliation had a reader, and it was the builder's ────────────
--
-- This half of the claim was half wrong, and the half that was right is worse
-- than it sounded. erp.platform_assurance() runs every row of
-- erp_meta.diagnostic_check, and a tenant-scoped row runs inside the caller's
-- own organisation, so the four ties ARE computed for a signed-in person today.
-- /operations/assurance renders them.
--
-- It renders them as the ninety-somethingth row of a table headed "Structural
-- assertions", between the scheduler's integrity and the German string
-- coverage, titled "Subledger reconciliation" and "Inventory valuation", under
-- a paragraph about erp.assert_diagnostics_registered(). It is the builder's
-- screen and reads like one: a wall of check names, on an operations path, that
-- says which assertion is violated and not what a finance person should now do
-- about it. Nothing in finance points at it.
--
-- So the correction is not a new computation. It is a reading: the four ties
-- the v1 Definition of Done names, in the words a finance person uses, for the
-- organisation they are signed in to, with the failing one named and the next
-- action beside it.
--
-- ── What is deliberately left alone ───────────────────────────────────────────
--
-- supabase/ops/ is the operator's runbook and stays one. 20260831_live_-
-- reconciliation.sql reads across organisations from a superuser connection;
-- erp.assert_whole_database_reconciles() walks every organisation from a
-- trusted session and is revoked from authenticated by name. Neither belongs
-- on a customer's screen and neither is exposed here: what a tenant may read is
-- its own books, which is what these two doors return and nothing else.
--
-- /operations/assurance keeps its wall. It is the right screen for the question
-- "is this deployment sound", and the answer to "are my books right" is now
-- somewhere else rather than buried in it.
--
-- ── The shape ─────────────────────────────────────────────────────────────────
--
-- The tie a finance person is shown is a property of the check, so it is held
-- on the check's own register row rather than in a list inside a function.
-- erp_meta.diagnostic_check gains the finance name and the next action; a row
-- carrying one carries both, by constraint. A tie added to the register
-- tomorrow appears on the screen without a deployment, which is the whole
-- reason that register exists (20260902100000).
--
-- Both doors are SECURITY INVOKER. Every assertion they run filters on
-- erp.require_tenant_id() or erp.current_tenant_id() in its own body and is
-- itself invoker, so row security is in force for the whole depth of the call:
-- a door that crossed organisations could not be written here by accident. The
-- one definer is erp.book_tie_register(), which reads the register and no
-- tenant data at all — erp_meta.diagnostic_check is platform_internal, with RLS
-- on, no policy, and a blanket revoke, so an invoker session cannot see the
-- list of ties it is being told about.
--
-- Both are VOLATILE because both authorise, and erp.authorise() writes the
-- access-log row that says who read the organisation's books
-- (erp.assert_authorising_doors_are_volatile, 20260904680000).

set lock_timeout = '30s';

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The register says which checks are ties, in finance's words
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp_meta.diagnostic_check
  add column if not exists book_tie_name text;

alter table erp_meta.diagnostic_check
  add column if not exists book_tie_next_action text;

comment on column erp_meta.diagnostic_check.book_tie_name is
  'What this check is called on the finance reconciliation screen, in the words '
  'a finance person uses rather than the name of the assertion. Null on a check '
  'that is not one of the ties the accounts are proved by — most of them are '
  'structural and belong on the assurance console, not in finance.';

comment on column erp_meta.diagnostic_check.book_tie_next_action is
  'What to do when this tie does not hold. A failing tie with no next action is '
  'a screen that tells a finance person their books are wrong and leaves them '
  'there, so the constraint below refuses the row.';

-- A tie names itself and says what to do about it, or it is not a tie.
do $constraint$
begin
  if not exists (select 1 from pg_catalog.pg_constraint
                  where conname = 'diagnostic_check_book_tie_complete'
                    and conrelid = 'erp_meta.diagnostic_check'::regclass) then
    alter table erp_meta.diagnostic_check
      add constraint diagnostic_check_book_tie_complete
      check ((book_tie_name is null) = (book_tie_next_action is null));
  end if;
end
$constraint$;

-- The four ties the v1 Definition of Done names. Three register rows carry
-- four: erp.assert_ageing_equals_control() proves the receivables ageing
-- against debtors and the payables ageing against creditors in one pass, and
-- splitting it into two screen rows that can only ever agree would be two rows
-- saying one thing.
update erp_meta.diagnostic_check set
  book_tie_name = 'The trial balance balances',
  book_tie_next_action =
    'Open Profit and balance sheet, show the account detail, and narrow to the '
    'ledger and company the finding names. The difference is a journal that put '
    'one side on one company''s account and the other side on another''s. Post '
    'the correction; a ledger that does not balance is a wrong set of accounts, '
    'not a formality.'
 where code = 'trial_balance';

update erp_meta.diagnostic_check set
  book_tie_name = 'Every control account equals its detail',
  book_tie_next_action =
    'Open the account the finding names. The difference is a posting that '
    'reached the control account without reaching the detail behind it, or the '
    'other way round. Post the missing side, or reverse the posting that should '
    'not be there.'
 where code = 'subledger_reconciles';

update erp_meta.diagnostic_check set
  book_tie_name = 'The customer and supplier ageings equal their control accounts',
  book_tie_next_action =
    'Open the ageing for the company the finding names. Money on the ledger with '
    'nobody against it is listed as Unallocated: put it through the sales or '
    'purchase ledger against the customer or supplier it belongs to, or reverse '
    'it.'
 where code = 'ageing_equals_control';

update erp_meta.diagnostic_check set
  book_tie_name = 'The stock valuation equals the inventory account',
  book_tie_next_action =
    'Open Stock audit for the account the finding names and compare its value '
    'with the ledger. The difference is a movement valued differently from the '
    'journal it raised; post the correction so the valuation and the ledger say '
    'the same number.'
 where code = 'inventory_reconciles';

-- A tie that was not marked because its code was renamed under us would leave a
-- screen quietly showing three ties and calling them all of them, which is the
-- exact failure this migration exists to end. Refused here rather than
-- discovered on the screen.
do $ties$
declare
  v_missing text;
  v_marked  integer;
begin
  select string_agg(w.code, ', ' order by w.code) into v_missing
    from (values ('trial_balance'), ('subledger_reconciles'),
                 ('ageing_equals_control'), ('inventory_reconciles')) as w(code)
   where not exists (select 1 from erp_meta.diagnostic_check d
                      where d.code = w.code and d.book_tie_name is not null);
  if v_missing is not null then
    raise exception 'CLOVEERP_BOOK_TIE_NOT_REGISTERED: % is not a registered check, so the reconciliation screen would show fewer ties than the accounts are proved by', v_missing
      using errcode = '23503',
            hint = 'Name the register row the check actually has, or add the check to erp_meta.diagnostic_check first.';
  end if;

  select count(*) into v_marked from erp_meta.diagnostic_check where book_tie_name is not null;
  if v_marked <> 4 then
    raise exception 'CLOVEERP_BOOK_TIE_COUNT_WRONG: % tie(s) marked, expected 4', v_marked
      using errcode = '23514',
            hint = 'The Definition of Done names four ties across three checks. Moving that number is a decision, not a side effect.';
  end if;
end
$ties$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The register, readable by the door that runs it
-- ═════════════════════════════════════════════════════════════════════════════
--
-- erp_meta.diagnostic_check is platform_internal: row security on with no
-- policy, and execute and select revoked. That is right — the register names
-- every assertion the product runs against itself and a tenant has no business
-- reading the list. But the door below has to know which four rows to run, so
-- this returns those four and nothing else, from a definer that touches no
-- tenant data whatsoever.

create or replace function erp.book_tie_register()
returns table (code text, tie_name text, what_it_means text, next_action text,
               schema_name text, function_name text, arguments text, seq integer)
language sql
stable
security definer
set search_path = ''
as $$
  select d.code, d.book_tie_name, d.blurb, d.book_tie_next_action,
         d.schema_name, d.function_name, d.arguments, d.seq
    from erp_meta.diagnostic_check d
   where d.book_tie_name is not null
     and d.kind = 'assertion'
   order by d.seq, d.code
$$;

comment on function erp.book_tie_register is
  'The checks a finance person is shown as the ties their accounts are proved '
  'by, with the finance name, what each means and what to do when one does not '
  'hold. Definer because erp_meta.diagnostic_check is platform_internal; it '
  'returns product content and reaches no tenant row, so an organisation '
  'learns nothing from it but the names of its own four ties.';

revoke all on function erp.book_tie_register() from public, anon;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale)
values ('erp', 'book_tie_register',
        'Reads the four rows of erp_meta.diagnostic_check marked as book ties '
        'and returns their names, meanings and next actions. Argument-free, one '
        'platform_internal table of product content, no tenant data on any path; '
        'the checks it names are then run by the caller, under the caller''s own '
        'privileges and row security.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The reconciliation, for the organisation the caller is signed in to
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Three verdicts, not two. A check that could not be run is neither holding nor
-- broken, and reporting it as either is the lie: "holds" is a green tie nobody
-- proved, and "does not hold" sends a finance person hunting a difference that
-- may not exist. erp.close_status() collapses both into check_passes = false,
-- which is why this does not use it.

create or replace function public.erp_book_ties()
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_out     jsonb := '[]'::jsonb;
  v_tenant  uuid;
  r         record;
  v_summary text;
  v_verdict text;
  v_finding text;
  v_state   text;
  v_broken  integer := 0;
  v_unknown integer := 0;
  v_total   integer := 0;
begin
  -- Under whichever the caller holds: reading whether the books tie is a
  -- finance read, and whoever may close the period may certainly ask.
  if erp.has_permission('finance.read') then
    perform erp.authorise('finance.read');
  elsif erp.has_permission('finance.close_period') then
    perform erp.authorise('finance.close_period');
  else
    perform erp.authorise('finance.read');
  end if;

  v_tenant := erp.require_tenant_id();

  for r in select * from erp.book_tie_register() loop
    v_total := v_total + 1;
    begin
      execute format('select %I.%I(%s)::text', r.schema_name, r.function_name, r.arguments)
        into v_summary;
      v_verdict := 'holds';
      v_finding := null;
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      v_summary := null;
      -- 42501 insufficient_privilege, 42883 undefined_function, 3F000 invalid
      -- schema: the check did not answer, which is not the same as answering no.
      if v_state in ('42501', '42883', '3F000') then
        v_verdict := 'unknown';
        v_unknown := v_unknown + 1;
      else
        v_verdict := 'broken';
        v_broken := v_broken + 1;
      end if;
      v_finding := left(sqlerrm, 2000);
    end;

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'code', r.code,
      'tie', r.tie_name,
      'what_it_means', r.what_it_means,
      'verdict', v_verdict,
      'summary', v_summary,
      'finding', v_finding,
      -- Carried on every row and not only the failing one, so a screen that
      -- shows the next action beside a broken tie needs no second read.
      'next_action', r.next_action,
      'seq', r.seq));
  end loop;

  return jsonb_build_object(
    'checked_at', now(),
    'ties', v_out,
    'total', v_total,
    'broken', v_broken,
    'unknown', v_unknown,
    'all_hold', v_broken = 0 and v_unknown = 0);
end;
$$;

comment on function public.erp_book_ties() is
  'Whether this organisation''s books agree with themselves: the four ties the '
  'v1 Definition of Done names, run against the ledger now, each with what it '
  'means and what to do when it does not hold. Invoker, so every check runs '
  'under the caller''s own row security and answers for their organisation and '
  'no other. A check that could not be run is reported as unknown rather than '
  'as holding.';

revoke all on function public.erp_book_ties() from public, anon;
grant execute on function public.erp_book_ties() to authenticated, service_role;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The close checklist, as a person works it
-- ═════════════════════════════════════════════════════════════════════════════
--
-- erp.close_status() already answers the hard half — the dependency each task
-- is waiting on and whether its blocking check would pass right now. What it
-- does not carry is who did what: completed_by, completed_at, the waiver
-- reason and the check output are on erp.close_task and are the whole of "who
-- has done what". The period is resolved rather than demanded, because a
-- person opening this screen at month end does not know the identifier of the
-- period they are closing; naming one still works.

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
  v_row      record;
  v_tasks    jsonb := '[]'::jsonb;
  v_open     integer := 0;
  v_failing  integer := 0;
  v_blocked  text;
  v_state    text;
  v_blocking text;
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

  -- The period being closed, then the period we are in, then the last one open,
  -- then the most recent of any kind. Each step is what a person means by "the
  -- close" at a different point in the month.
  --
  -- The primary ledger first at every step: an organisation that keeps a second
  -- ledger has two periods covering today, and "the close" means the one the
  -- accounts are drawn from, not whichever the planner reached first.
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
      'can_close', false, 'open_tasks', 0, 'failing_checks', 0);
  end if;

  -- erp.close_status() is the governed reader and stays it; this joins what it
  -- returns to the task rows for the half it does not carry.
  for v_row in
    select cs.code, cs.name, cs.seq, cs.status, cs.blocking_check,
           cs.is_waivable, cs.blocked_by, cs.check_passes,
           ct.completed_at, ct.waiver_reason, ct.check_output,
           u.display_name as completed_by,
           tm.owner_role_code
      from erp.close_status(v_period) cs
      join erp.close_task ct
        on ct.tenant_id = v_tenant and ct.fiscal_period_id = v_period
       and ct.code = cs.code
      left join erp.app_user u
        on u.tenant_id = v_tenant and u.id = ct.completed_by
      left join erp.close_task_template tm
        on tm.tenant_id = v_tenant and tm.code = ct.code
     order by cs.seq, cs.code
  loop
    if v_row.status not in ('complete', 'waived') then
      v_open := v_open + 1;
      if v_row.check_passes is false then
        v_failing := v_failing + 1;
      end if;
      if v_blocked is null then
        v_blocked := v_row.name;
      end if;
    end if;

    v_tasks := v_tasks || jsonb_build_array(jsonb_build_object(
      'code', v_row.code, 'name', v_row.name, 'seq', v_row.seq,
      'status', v_row.status,
      'blocking_check', v_row.blocking_check,
      'is_waivable', v_row.is_waivable,
      'blocked_by', v_row.blocked_by,
      'check_passes', v_row.check_passes,
      'completed_by', v_row.completed_by,
      'completed_at', v_row.completed_at,
      'waiver_reason', v_row.waiver_reason,
      'check_output', v_row.check_output,
      'owner_role_code', v_row.owner_role_code));
  end loop;

  select case
           when fp.status = 'closed' then 'closed'
           when fp.status = 'permanently_closed' then 'closed'
           when jsonb_array_length(v_tasks) = 0 then 'not_opened'
           when v_open = 0 then 'ready'
           else 'in_progress'
         end
    into v_state
    from erp.fiscal_period fp
   where fp.tenant_id = v_tenant and fp.id = v_period;

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
    'can_close', v_state = 'ready',
    'open_tasks', v_open,
    'failing_checks', v_failing);
end;
$$;

comment on function public.erp_close_checklist(uuid) is
  'The period close as a person works it: the period being closed, every task '
  'with its state, who completed or waived it and when, the dependency it is '
  'waiting on, whether its blocking check would pass right now, and the one '
  'sentence saying what is stopping the close. Resolves the period when none is '
  'named — the one being closed, then the one we are in, then the last open '
  'one. Invoker throughout, so it answers for the caller''s organisation only.';

revoke all on function public.erp_close_checklist(uuid) from public, anon;
grant execute on function public.erp_close_checklist(uuid) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_book_ties', 'erp.authorise',
   'Reads whether this organisation''s four ties hold, under finance.read or '
   'finance.close_period. Writes only the access-log row erp.authorise() '
   'raises, which is the record of who read the organisation''s books.'),
  ('erp_close_checklist', 'erp.authorise',
   'Reads the period close checklist under finance.close_period, or under '
   'finance.read for somebody who may see the close without working it. Writes '
   'only the access-log row erp.authorise() raises.')
on conflict (function_name) do update set
  gate = excluded.gate, rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The two screens: their names, their help, and the words on them
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('nav.finance_close', 'en', 'Closing the month', 'finance',
   'Navigation key for /finance/close, the period close checklist.'),
  ('nav.finance_close', 'de', 'Monatsabschluss', 'finance',
   'Navigation key for /finance/close, the period close checklist.'),
  ('nav.finance_reconciliation', 'en', 'Do the books tie', 'finance',
   'Navigation key for /finance/reconciliation, the four ties the accounts are proved by.'),
  ('nav.finance_reconciliation', 'de', 'Stimmen die Bücher', 'finance',
   'Navigation key for /finance/reconciliation, the four ties the accounts are proved by.')
on conflict (key, locale) do update set
  value = excluded.value, module_code = excluded.module_code,
  description = excluded.description;

insert into erp_ref.help_topic (screen_path, nav_key, module_code, summary, steps, next_action, actions) values
  ('/finance/close', 'nav.finance_close', 'finance',
   'The checklist that has to be true before a month''s books are closed, for the period being closed right now. Every task shows its state, who completed or waived it, and the check it carries — run against the ledger as the screen is read, so a task is known to be unfinishable before anybody tries it. Three of the tasks carry one of the four ties the accounts are proved by and cannot be waived at all.',
   '["Open the close for the period. That raises this organisation''s checklist from its template.","Work down the list. A task waiting on another says which one, and a task whose check does not pass says so before you try it.","Complete each task. The check runs again as you do, so it cannot be ticked past.","Waive a task that is a judgement rather than a tie, with a reason that will be read at audit. The three tie tasks refuse a waiver by name.","Close the period once nothing is left. Nothing more posts into it unless it is reopened."]',
   'Open the close, then work down the list until nothing is left open.',
   '{erp_close_checklist,erp_open_period_close,erp_complete_close_task,erp_close_period,erp_close_status,erp_fiscal_periods}'),
  ('/finance/reconciliation', 'nav.finance_reconciliation', 'finance',
   'Whether this organisation''s books agree with themselves, checked against the ledger at the moment the screen is opened rather than read from a stored result. Four ties: the trial balance, the two ageings against their control accounts, every control account against its detail, and the stock valuation against the inventory account. The same checks the build runs on every deployment, for your organisation and no other.',
   '["Read the verdict at the top. Four ties hold, or one of them is named.","Open a tie that does not hold. The finding names the ledger, company or account that is out, and by how much.","Follow the next action beside it. Each says where to go and what to post.","Come back and read it again: the checks run afresh every time, so a correction shows immediately.","Go to Closing the month when all four hold; three of the close tasks carry these ties and will not complete until they do."]',
   'Read the verdict; if a tie does not hold, follow the next action beside it.',
   '{erp_book_ties}')
on conflict (screen_path) do update set
  nav_key = excluded.nav_key, module_code = excluded.module_code,
  summary = excluded.summary, steps = excluded.steps,
  next_action = excluded.next_action, actions = excluded.actions;

-- The words the two screens say, each with a row a tenant can rename it by.
insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'Screen string of the period close checklist or the reconciliation screen.'
  from (values
    ('All four ties hold.'),
    ('Blocked'),
    ('Cannot be waived'),
    ('Checked against the ledger just now.'),
    ('Complete'),
    ('Could not be checked'),
    ('Does not hold'),
    ('Holds'),
    ('Nothing is stopping the close.'),
    ('Nothing on this period''s checklist yet.'),
    ('Open'),
    ('Reading the close…'),
    ('Reading the ledger…'),
    ('State'),
    ('Task'),
    ('The check does not pass yet'),
    ('The close has not been opened for this period yet.'),
    ('This period is closed.'),
    ('Waited on by'),
    ('Waived'),
    ('Waiting on'),
    ('What is needed'),
    ('What to do'),
    ('Who and when'),
    ('Working the close')
  ) as v(text)
on conflict (key, locale) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Four claims, and the third is the one worth the fixture: a tie that is
-- actually broken is reported as broken, by name, with its next action — not
-- omitted, not swallowed, not reported as holding. The organisation is broken
-- deliberately with a one-sided journal line written straight onto the table,
-- because there is no door that will post one; that is the point.

create or replace function erp_test.close_and_ties_read_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $suite$
declare
  c_expected constant integer := 10;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  a2       uuid := gen_random_uuid();
  a3       uuid := gen_random_uuid();
  rb       record;
  rb2      record;
  v_step   text := 'provisioning';
  v_state  text;
  v_tenant uuid;
  v_other  uuid;
  v_entity uuid; v_ledger uuid; v_period uuid; v_ccy char(3);
  v_ar uuid; v_ap uuid; v_rev uuid; v_cos uuid;
  v_j      uuid;
  v_res    jsonb;
  v_res2   jsonb;
  v_tie    jsonb;
  v_hold   jsonb;
  v_task   jsonb;
  v_denied text;
  v_closed text;
  v_ties   text;
  v_stranger uuid;
  v_tmpl   integer;
  v_other_period text;
begin
  begin
    -- ── The fixture ──────────────────────────────────────────────────────────
    v_step := 'an organisation configured as the demonstration is, with a close template';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzcls-' || v_tag, 'Close Reading Suite',
      'admin@zzcls-' || v_tag || '.test', 'Close Admin');
    v_tenant := rb.tenant_id;
    update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzcls-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(v_tenant, rb.admin_user_id);
    perform erp.configure_period_close();

    select l.entity_id, l.id, l.currency into v_entity, v_ledger, v_ccy
      from erp.ledger l where l.tenant_id = v_tenant and l.is_primary order by l.code limit 1;
    select fp.id into v_period from erp.fiscal_period fp
     where fp.tenant_id = v_tenant and fp.ledger_id = v_ledger
       and current_date between fp.starts_on and fp.ends_on;
    select a.id into strict v_ar from erp.account a
     where a.tenant_id = v_tenant and a.entity_id = v_entity and a.control_kind = 'receivable'
       and a.status = 'active' and a.is_postable order by a.code limit 1;
    select a.id into strict v_ap from erp.account a
     where a.tenant_id = v_tenant and a.entity_id = v_entity and a.control_kind = 'payable'
       and a.status = 'active' and a.is_postable order by a.code limit 1;
    select a.id into strict v_rev from erp.account a
     where a.tenant_id = v_tenant and a.entity_id = v_entity
       and a.code = erp.tenant_account_code('revenue');
    select a.id into strict v_cos from erp.account a
     where a.tenant_id = v_tenant and a.entity_id = v_entity
       and a.code = erp.tenant_account_code('cost_of_sales');

    -- ── 1. The ties read, in finance's words, for this organisation ──────────
    v_step := 'the ties read on an organisation whose books tie';
    v_res := public.erp_book_ties();
    select t into v_hold from jsonb_array_elements(v_res -> 'ties') t
     where t ->> 'code' = 'trial_balance';

    v_cases := v_cases + 1;
    case_name := 'the reconciliation names four ties in words a finance person uses, each with what to do about it';
    passed := coalesce(v_state is null
          and jsonb_array_length(v_res -> 'ties') = 4
          -- Not a wall of check names: no row is titled after its assertion.
          and not exists (select 1 from jsonb_array_elements(v_res -> 'ties') t
                           where coalesce(t ->> 'tie', '') = '' or t ->> 'tie' like '%assert%')
          -- The next action travels with every tie, not only the failing one.
          and not exists (select 1 from jsonb_array_elements(v_res -> 'ties') t
                           where coalesce(t ->> 'next_action', '') = ''
                              or coalesce(t ->> 'what_it_means', '') = '')
          -- And no verdict is left unsaid.
          and not exists (select 1 from jsonb_array_elements(v_res -> 'ties') t
                           where t ->> 'verdict' not in ('holds', 'broken', 'unknown'))
          -- On a freshly configured organisation with no postings, the two the
          -- ledger decides hold, which is how we know "holds" is reachable.
          and v_hold ->> 'verdict' = 'holds'
          and (select t ->> 'verdict' from jsonb_array_elements(v_res -> 'ties') t
                where t ->> 'code' = 'subledger_reconciles') = 'holds', false);
    detail := coalesce(v_state, format('%s tie(s): %s',
      jsonb_array_length(v_res -> 'ties'),
      (select string_agg(format('%s [%s]', t ->> 'tie', t ->> 'verdict'), '; '
                         order by (t ->> 'seq')::integer)
         from jsonb_array_elements(v_res -> 'ties') t)), 'no answer');
    return next;

    -- ── 2. A tie that does not hold is named, not omitted ────────────────────
    --
    -- Money on the debtors and creditors control accounts that no invoice, bill
    -- or payment put there: the journal balances, the company is right, and the
    -- detail behind the control accounts does not exist. The ageing tie and the
    -- subledger tie both break; the trial balance does not. This is the
    -- falsification erp_test.ageing_tie_suite() uses, run through the reader a
    -- person actually opens.
    v_step := 'postings on the control accounts with no detail behind them';
    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date,
                             description, status, manual_reason)
    values (v_tenant, v_entity, v_ledger, 'manual', current_date, 'ZZCLS-BREAK', 'draft',
            'suite: money the ageing cannot see')
    returning id into v_j;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor,
                                  credit_minor, currency, base_debit_minor, base_credit_minor,
                                  exchange_rate)
    values (v_tenant, v_j, 1, v_ar, 1234, 0, v_ccy, 1234, 0, 1),
           (v_tenant, v_j, 2, v_rev, 0, 1234, v_ccy, 0, 1234, 1),
           (v_tenant, v_j, 3, v_cos, 555, 0, v_ccy, 555, 0, 1),
           (v_tenant, v_j, 4, v_ap, 0, 555, v_ccy, 0, 555, 1);
    update erp.journal set status = 'posted', posted_at = now(),
                           posted_by = erp.current_principal_id() where id = v_j;

    v_res := public.erp_book_ties();
    select t into v_tie from jsonb_array_elements(v_res -> 'ties') t
     where t ->> 'code' = 'ageing_equals_control';
    select t into v_hold from jsonb_array_elements(v_res -> 'ties') t
     where t ->> 'code' = 'trial_balance';

    v_cases := v_cases + 1;
    case_name := 'a tie that does not hold is reported as broken, named, quoting the finding and what to do next';
    passed := coalesce(v_state is null
          and v_tie ->> 'verdict' = 'broken'
          and not (v_res ->> 'all_hold')::boolean
          and v_tie ->> 'finding' like '%1234%'
          and v_tie ->> 'finding' like '%555%'
          and v_tie ->> 'next_action' like '%Unallocated%', false);
    detail := coalesce(v_state, format('%s [%s]: %s', v_tie ->> 'tie', v_tie ->> 'verdict',
      left(coalesce(v_tie ->> 'finding', 'no finding'), 160)), 'no answer');
    return next;

    v_cases := v_cases + 1;
    case_name := 'the failing ties are counted and the sound ones still say they hold — none is silently omitted';
    passed := coalesce(v_state is null
          and jsonb_array_length(v_res -> 'ties') = 4
          -- Both ties this posting breaks are named, and neither is reported as
          -- a check that could not be run.
          and (select t ->> 'verdict' from jsonb_array_elements(v_res -> 'ties') t
                where t ->> 'code' = 'subledger_reconciles') = 'broken'
          and (v_res ->> 'unknown')::integer = 0
          -- The one it does not break still says so.
          and v_hold ->> 'verdict' = 'holds'
          -- And the count agrees with the rows, so nothing is counted and hidden.
          and (v_res ->> 'broken')::integer =
              (select count(*) from jsonb_array_elements(v_res -> 'ties') t
                where t ->> 'verdict' = 'broken')
          and (v_res ->> 'broken')::integer >= 2, false);
    detail := coalesce(v_state, format('%s listed, %s broken, %s unknown; trial balance %s, subledger %s',
      jsonb_array_length(v_res -> 'ties'), v_res ->> 'broken', v_res ->> 'unknown',
      v_hold ->> 'verdict',
      (select t ->> 'verdict' from jsonb_array_elements(v_res -> 'ties') t
        where t ->> 'code' = 'subledger_reconciles')), 'no answer');
    return next;

    -- ── 3. The close, before it is opened ────────────────────────────────────
    v_step := 'the close checklist with no period named and no close opened';
    v_res := public.erp_close_checklist(null);

    v_cases := v_cases + 1;
    case_name := 'the checklist resolves the period without being told one, and says the close has not been opened';
    passed := coalesce(v_state is null
          and v_res -> 'period' ->> 'fiscal_period_id' = v_period::text
          and v_res ->> 'state' = 'not_opened'
          and v_res ->> 'blocking' like '%has not been opened%'
          and not (v_res ->> 'can_close')::boolean, false);
    detail := coalesce(v_state, format('period %s, state %s: %s',
      v_res -> 'period' ->> 'code', v_res ->> 'state',
      left(coalesce(v_res ->> 'blocking', 'nothing'), 80)), 'no answer');
    return next;

    -- ── 4. The close, worked ─────────────────────────────────────────────────
    v_step := 'the close opened and read';
    perform public.erp_open_period_close(v_period);
    select count(*) into v_tmpl from erp.close_task_template
     where tenant_id = v_tenant and status = 'active'::erp.record_status;
    v_res := public.erp_close_checklist(v_period);
    select t into v_task from jsonb_array_elements(v_res -> 'tasks') t
     where t ->> 'code' = 'trial_balance';

    v_cases := v_cases + 1;
    case_name := 'the opened checklist lists every task, what each waits on, and which cannot be waived at all';
    passed := coalesce(v_state is null
          and jsonb_array_length(v_res -> 'tasks') = v_tmpl
          and v_tmpl > 0
          and v_res ->> 'state' = 'in_progress'
          and (v_res ->> 'open_tasks')::integer = v_tmpl
          and v_task ->> 'is_waivable' = 'false'
          and coalesce(v_task ->> 'blocked_by', '') <> ''
          and coalesce(v_res ->> 'blocking', '') <> ''
          and not (v_res ->> 'can_close')::boolean, false);
    detail := coalesce(v_state, format('%s of %s task(s) listed, %s open; the trial balance waits on %s and is waivable %s; blocking: %s',
      jsonb_array_length(v_res -> 'tasks'), v_tmpl, v_res ->> 'open_tasks',
      v_task ->> 'blocked_by', v_task ->> 'is_waivable',
      left(coalesce(v_res ->> 'blocking', 'nothing'), 60)), 'no answer');
    return next;

    v_cases := v_cases + 1;
    case_name := 'a task whose check cannot pass says so on the screen before anybody presses it';
    passed := coalesce(v_state is null
          and (v_res ->> 'failing_checks')::integer >= 1
          and (select (t ->> 'check_passes')::boolean
                 from jsonb_array_elements(v_res -> 'tasks') t
                where t ->> 'code' = 'subledgers_reconcile') is false, false);
    detail := coalesce(v_state, format('%s failing check(s); the subledger task passes %s',
      v_res ->> 'failing_checks',
      coalesce((select t ->> 'check_passes' from jsonb_array_elements(v_res -> 'tasks') t
                 where t ->> 'code' = 'subledgers_reconcile'), 'no verdict')), 'no answer');
    return next;

    -- ── 5. Who did what ──────────────────────────────────────────────────────
    v_step := 'a task completed, and the checklist asked who did it';
    perform public.erp_complete_close_task(
      (select ct.id from erp.close_task ct
        where ct.tenant_id = v_tenant and ct.fiscal_period_id = v_period
          and ct.code = 'stock_reconciles'), null);
    v_res := public.erp_close_checklist(v_period);
    select t into v_task from jsonb_array_elements(v_res -> 'tasks') t
     where t ->> 'code' = 'stock_reconciles';

    v_cases := v_cases + 1;
    case_name := 'a completed task carries who completed it and when';
    passed := coalesce(v_state is null
          and v_task ->> 'status' = 'complete'
          and v_task ->> 'completed_by' = 'Close Admin'
          and v_task ->> 'completed_at' is not null
          and (v_res ->> 'open_tasks')::integer = v_tmpl - 1, false);
    detail := coalesce(v_state, format('%s by %s at %s, %s still open', v_task ->> 'status',
      coalesce(v_task ->> 'completed_by', 'nobody'),
      left(coalesce(v_task ->> 'completed_at', 'never'), 19), v_res ->> 'open_tasks'), 'no answer');
    return next;

    -- ── 6. Neither door answers for another organisation ─────────────────────
    v_step := 'a second organisation reads its own books, not the first''s';
    perform set_config('request.jwt.claims', '', true);
    select * into rb2 from erp.provision_tenant(
      'zzcl2-' || v_tag, 'Close Reading Suite Two',
      'admin@zzcl2-' || v_tag || '.test', 'Other Admin');
    v_other := rb2.tenant_id;
    update erp.environment set is_live = false where tenant_id = v_other and is_self;
    insert into auth.users (id, email) values (a2, 'admin@zzcl2-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(rb2.admin_token);
    perform erp.ensure_demo_configuration(v_other, rb2.admin_user_id);

    v_res2 := public.erp_book_ties();
    v_other_period := public.erp_close_checklist(null) -> 'period' ->> 'fiscal_period_id';

    v_cases := v_cases + 1;
    case_name := 'the second organisation''s books tie although the first''s do not, and its close is its own period';
    passed := coalesce(v_state is null
          and jsonb_array_length(v_res2 -> 'ties') = 4
          -- The two the first organisation broke hold here.
          and (select t ->> 'verdict' from jsonb_array_elements(v_res2 -> 'ties') t
                where t ->> 'code' = 'ageing_equals_control') = 'holds'
          and (select t ->> 'verdict' from jsonb_array_elements(v_res2 -> 'ties') t
                where t ->> 'code' = 'subledger_reconciles') = 'holds'
          -- Not one figure of the first organisation's difference reaches it.
          and not exists (select 1 from jsonb_array_elements(v_res2 -> 'ties') t
                           where coalesce(t ->> 'finding', '') like '%1234%'
                              or coalesce(t ->> 'finding', '') like '%555%')
          -- And its close is its own period.
          and v_other_period is not null
          and v_other_period <> v_period::text, false);
    detail := coalesce(v_state, format('second organisation: %s of %s tie(s) broken (ageing %s, subledger %s); its period %s, the first''s %s',
      v_res2 ->> 'broken', jsonb_array_length(v_res2 -> 'ties'),
      (select t ->> 'verdict' from jsonb_array_elements(v_res2 -> 'ties') t
        where t ->> 'code' = 'ageing_equals_control'),
      (select t ->> 'verdict' from jsonb_array_elements(v_res2 -> 'ties') t
        where t ->> 'code' = 'subledger_reconciles'),
      left(coalesce(v_other_period, 'none'), 8), left(v_period::text, 8)), 'no answer');
    return next;

    -- ── 7. A principal holding neither permission is refused ─────────────────
    v_step := 'a principal of the first organisation holding no finance permission';
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email)
    values (v_tenant, a3, 'person', 'active', 'No Finance',
            'nofinance@zzcls-' || v_tag || '.test')
    returning id into v_stranger;

    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    begin
      perform public.erp_close_checklist(v_period);
      v_denied := 'the close checklist answered a principal holding no finance permission';
    exception when others then
      v_closed := sqlerrm;
    end;
    begin
      perform public.erp_book_ties();
      v_denied := coalesce(v_denied,
        'the reconciliation answered a principal holding no finance permission');
    exception when others then
      v_ties := sqlerrm;
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_cases := v_cases + 1;
    case_name := 'a principal holding neither finance permission is refused both doors by the database';
    passed := coalesce(v_state is null
          and v_denied is null
          and coalesce(v_closed, '') <> ''
          and coalesce(v_ties, '') <> ''
          -- The refusal is the gate's, not a missing grant or a null.
          and v_closed like '%finance.close_period%'
          and v_ties like '%finance.read%', false);
    detail := coalesce(v_state, coalesce(v_denied,
      format('close: %s / ties: %s', left(coalesce(v_closed, 'nothing'), 90),
             left(coalesce(v_ties, 'nothing'), 90))), 'no answer');
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
  passed := coalesce(v_state is null
        and not exists (select 1 from erp.tenant t
                         where t.code in ('zzcls-' || v_tag, 'zzcl2-' || v_tag))
        and not exists (select 1 from auth.users u where u.id in (a1, a2)), false);
  detail := coalesce(v_state, 'zzcls and zzcl2 rolled back with their journals, periods and close tasks');
  return next;

  -- The count guard says what stopped the fixture, so the message this suite
  -- caught — and the step that produced it — reaches the build log.
  if v_cases <> c_expected then
    raise exception 'CLOVEERP_CLOSE_READING_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$suite$;

revoke all on function erp_test.close_and_ties_read_suite() from public, anon;

comment on function erp_test.close_and_ties_read_suite() is
  'The close and the ties, read. Four ties in finance''s words on a sound '
  'organisation; a deliberately one-sided posted journal line makes the trial '
  'balance broken and the reader names it, quotes the finding and carries the '
  'next action while the other three still say they hold; the close checklist '
  'resolves its period, says what is stopping the close, marks the tie tasks '
  'unwaivable and names who completed one; a second organisation reads its own '
  'books and its own period; and a principal holding neither finance permission '
  'is refused both doors. Rolls back everything it made.';

create or replace function erp_test.assert_close_and_ties_read_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $wrap$
declare
  c_expected constant integer := 10;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _close_read on commit drop as
    select * from erp_test.close_and_ties_read_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _close_read;
  drop table _close_read;
  if v_fail > 0 then
    raise exception E'CLOVEERP_CLOSE_READING_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_CLOSE_READING_SUITE_SHRANK: % case(s), expected %', v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('the close and the ties can be read: %s/%s cases passed', v_all, v_all);
end;
$wrap$;

revoke all on function erp_test.assert_close_and_ties_read_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The generators, then the checks that read what changed
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
select erp.assert_authorise_codes_exist();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_guidance_sound();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();

select erp_test.assert_close_and_ties_read_suite();
