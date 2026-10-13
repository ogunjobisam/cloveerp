-- A bank statement is reconciled.
--
-- Bank reconciliation, pull request 5 of 5 (owner, 13 October 2026). A
-- statement whose every line is matched or posted is reconciled: the bank's
-- closing balance, plus what the books hold that the bank has not yet shown,
-- comes to the books' balance on the statement's last day. A reconciled
-- statement is locked, and the close asks for it.
--
-- ── DECISIONS ────────────────────────────────────────────────────────────────
--
--   The owner's: the close task "bank reconciled" can be waived with a reason.
--
--   Mine, under the standing approval of 13 October:
--   * finance.post reconciles; reopening the latest reconciled statement of an
--     account is finance.close_period's, with a reason. Statements reconcile
--     in order, each after the one before.
--   * What the books hold from before an account's first statement is taken
--     to be in that statement's opening balance, unless it is matched to a
--     line. A difference left over — books that were wrong before the bank's
--     statements began — is reconciled only with a reason, which the
--     reconciliation and the close both show.
--   * The close task passes for a bank account no statement has been imported
--     into, and says so: its reconciliation has not begun, and a close cannot
--     wait for a habit the organisation has not started. Once an account has
--     statements, the period's last day must fall in a reconciled one with no
--     difference left over. The demonstration imports none yet, so its
--     monthly catch-up still closes its months.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.bank_reconciliation(statement): the statement's closing balance;
--      receipts and payments in the books the bank has not shown by its last
--      day, each listed; what the bank shows that the books date after it;
--      the books' balance on that day; the difference.
--      public.erp_bank_reconciliation reads it.
--   B. public.erp_reconcile_bank_statement (finance.post) refuses a statement
--      with a line unmatched, one whose predecessor is not reconciled, and a
--      difference without a reason; it keeps the figures it reconciled on.
--      public.erp_reopen_bank_statement (finance.close_period) reopens the
--      latest reconciled statement of an account, with a reason.
--   C. A reconciled statement is locked: its lines are not matched, unmatched
--      or posted, it is not withdrawn, and a bank entry on it is not reversed.
--   D. erp.assert_bank_reconciled and the close task bank_reconciled, after
--      the subledgers reconcile; period close version 4 brings it to every
--      organisation, and into the checklists of periods not yet closed.
--   E. erp_test.bank_reconciliation_suite proves A to D; five suites that
--      counted six close tasks count seven.

alter table erp.bank_statement
  add column if not exists book_minor          bigint,
  add column if not exists uncleared_in_minor  bigint,
  add column if not exists uncleared_out_minor bigint,
  add column if not exists ahead_minor         bigint,
  add column if not exists difference_minor    bigint,
  add column if not exists difference_reason   text;

comment on column erp.bank_statement.difference_minor is
  'The books'' balance on the statement''s last day less the bank''s closing balance adjusted for what the bank had '
  'not yet shown, as it stood when the statement was reconciled (20261013050000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The reconciliation
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.bank_reconciliation(p_statement_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- The bank's closing balance and the books' on the statement's last day,
  -- reconciled by what the books hold that the bank had not shown by then:
  -- bank items posted on or before that day, since the account's first
  -- statement began, not matched to a line of this statement or an earlier
  -- one of the account (20261013050000). Items from before the first
  -- statement are in its opening balance unless a line matched them.
  with s as (
    select x.*, b.account_id, b.entity_id, b.currency, b.name as bank_account
      from erp.bank_statement x
      join erp.bank_account b on b.tenant_id = x.tenant_id and b.id = x.bank_account_id
     where x.tenant_id = erp.current_tenant_id() and x.id = p_statement_id
  ), start as (
    select min(f.starts_on) as on_
      from s join erp.bank_statement f on f.tenant_id = s.tenant_id and f.bank_account_id = s.bank_account_id
  ), uncleared as (
    select si.id, si.debit_minor - si.credit_minor as net, si.posting_date,
           coalesce(d.document_number, j.journal_number, j.description) as what,
           (select pt.name from erp.party pt where pt.tenant_id = si.tenant_id and pt.id = d.party_id) as party
      from s
      cross join start
      join erp.subledger_item si
        on si.tenant_id = s.tenant_id and si.entity_id = s.entity_id and si.control_kind = 'bank'
       and si.control_account_id = s.account_id and si.posting_date <= s.ends_on and si.posting_date >= start.on_
      join erp.journal j on j.tenant_id = si.tenant_id and j.id = si.journal_id and j.status = 'posted'
      left join erp.document d on d.tenant_id = j.tenant_id and d.id = j.document_id
     where not exists (select 1 from erp.bank_match_item mi
                         join erp.bank_match_line ml on ml.tenant_id = mi.tenant_id and ml.match_id = mi.match_id
                         join erp.bank_statement_line l on l.tenant_id = ml.tenant_id and l.id = ml.line_id
                         join erp.bank_statement e on e.tenant_id = l.tenant_id and e.id = l.statement_id
                        where mi.tenant_id = si.tenant_id and mi.subledger_item_id = si.id
                          and (e.id = s.id or e.ends_on < s.ends_on
                               or (e.ends_on = s.ends_on and e.created_at < s.created_at)))
  ), ahead as (
    -- On the bank by the statement's last day, in the books after it: a line
    -- of this statement or an earlier one matched to an item dated later.
    select si.id, si.debit_minor - si.credit_minor as net, si.posting_date,
           coalesce(d.document_number, j.journal_number, j.description) as what
      from s
      join erp.bank_statement e on e.tenant_id = s.tenant_id and e.bank_account_id = s.bank_account_id
                               and (e.id = s.id or e.ends_on < s.ends_on
                                    or (e.ends_on = s.ends_on and e.created_at < s.created_at))
      join erp.bank_statement_line l on l.tenant_id = e.tenant_id and l.statement_id = e.id
      join erp.bank_match_line ml on ml.tenant_id = l.tenant_id and ml.line_id = l.id
      join erp.bank_match_item mi on mi.tenant_id = ml.tenant_id and mi.match_id = ml.match_id
      join erp.subledger_item si on si.id = mi.subledger_item_id and si.posting_date > s.ends_on
      join erp.journal j on j.tenant_id = si.tenant_id and j.id = si.journal_id
      left join erp.document d on d.tenant_id = j.tenant_id and d.id = j.document_id
  ), book as (
    select coalesce(sum(jl.debit_minor - jl.credit_minor), 0)::bigint as minor
      from s
      join erp.journal_line jl on jl.tenant_id = s.tenant_id and jl.account_id = s.account_id
      join erp.journal j on j.tenant_id = jl.tenant_id and j.id = jl.journal_id
                        and j.status = 'posted' and j.posting_date <= s.ends_on
  )
  select jsonb_build_object(
           'statement_id', s.id, 'bank_account', s.bank_account, 'currency', s.currency,
           'starts_on', s.starts_on, 'ends_on', s.ends_on, 'status', s.status,
           'closing_minor', s.closing_minor,
           'unmatched_lines', (select count(*) from erp.bank_statement_line l
                                where l.tenant_id = s.tenant_id and l.statement_id = s.id and l.status = 'unmatched'),
           'uncleared_in_minor', coalesce((select sum(u.net) from uncleared u where u.net > 0), 0)::bigint,
           'uncleared_out_minor', coalesce((select -sum(u.net) from uncleared u where u.net < 0), 0)::bigint,
           'ahead_minor', coalesce((select sum(a.net) from ahead a), 0)::bigint,
           'book_minor', (select minor from book),
           'difference_minor', (select minor from book)
                               - (s.closing_minor + coalesce((select sum(u.net) from uncleared u), 0)
                                  - coalesce((select sum(a.net) from ahead a), 0))::bigint,
           'ahead', coalesce((select jsonb_agg(jsonb_build_object(
                                       'posted_on', a.posting_date, 'what', a.what, 'amount_minor', a.net)
                                       order by a.posting_date, a.what)
                                from ahead a), '[]'::jsonb),
           'uncleared', coalesce((select jsonb_agg(jsonb_build_object(
                                           'posted_on', u.posting_date, 'what', u.what, 'party', u.party,
                                           'amount_minor', u.net) order by u.posting_date, u.what)
                                    from uncleared u), '[]'::jsonb),
           'difference_reason', s.difference_reason, 'reconciled_at', s.reconciled_at)
    from s
$$;
revoke all on function erp.bank_reconciliation(uuid) from public, anon;

create or replace function public.erp_bank_reconciliation(p_statement_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$ select erp.bank_reconciliation(p_statement_id) $$;
revoke all on function public.erp_bank_reconciliation(uuid) from public, anon;
grant execute on function public.erp_bank_reconciliation(uuid) to authenticated, service_role;
comment on function public.erp_bank_reconciliation(uuid) is
  'A bank statement''s reconciliation: its closing balance, what the books hold that the bank had not shown by its '
  'last day, the books'' balance that day and the difference (20261013050000). Reads only.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. Reconciling and reopening
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.reconcile_bank_statement(p_statement_id uuid, p_difference_reason text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  s        erp.bank_statement%rowtype;
  b        erp.bank_account%rowtype;
  r        jsonb;
  v_reason text := nullif(btrim(coalesce(p_difference_reason, '')), '');
begin
  select x.* into s from erp.bank_statement x where x.tenant_id = v_tenant and x.id = p_statement_id for update;
  select x.* into b from erp.bank_account x where x.tenant_id = v_tenant and x.id = s.bank_account_id;
  perform erp.authorise('finance.post', b.entity_id, null, null, 'bank_statement', p_statement_id, null);
  if s.id is null or s.status <> 'imported' then
    raise exception 'CLOVEERP_BANK_STATEMENT_NOT_RECONCILABLE: only an imported statement not yet reconciled is reconciled'
      using errcode = '23514', hint = 'Refresh the statements and choose again.';
  end if;
  if exists (select 1 from erp.bank_statement e
              where e.tenant_id = v_tenant and e.bank_account_id = s.bank_account_id and e.id <> s.id
                and e.status <> 'reconciled'
                and (e.ends_on < s.ends_on or (e.ends_on = s.ends_on and e.created_at < s.created_at))) then
    raise exception 'CLOVEERP_BANK_STATEMENT_OUT_OF_ORDER: an earlier statement of this account is not reconciled'
      using errcode = '23514', hint = 'Reconcile the account''s statements in order, the earliest first.';
  end if;

  r := erp.bank_reconciliation(s.id);
  if (r ->> 'unmatched_lines')::integer > 0 then
    raise exception 'CLOVEERP_BANK_STATEMENT_LINES_OPEN: % line(s) of the statement are neither matched nor posted', r ->> 'unmatched_lines'
      using errcode = '23514', hint = 'Match each line, post it by rule or by hand, or receive it as cash; an entry waiting for approval must be approved first.';
  end if;
  if (r ->> 'difference_minor')::bigint <> 0 and v_reason is null then
    raise exception 'CLOVEERP_BANK_RECONCILIATION_DIFFERENCE: the books come to % and the bank, with what it has not yet shown, to %',
      r ->> 'book_minor', ((r ->> 'book_minor')::bigint - (r ->> 'difference_minor')::bigint)
      using errcode = '23514',
            hint = 'Read the reconciliation for what is uncleared; correct the books, or reconcile with a reason saying why the difference stands.';
  end if;

  update erp.bank_statement x
     set status = 'reconciled', reconciled_at = now(), reconciled_by = erp.current_principal_id(),
         book_minor = (r ->> 'book_minor')::bigint,
         uncleared_in_minor = (r ->> 'uncleared_in_minor')::bigint,
         uncleared_out_minor = (r ->> 'uncleared_out_minor')::bigint,
         ahead_minor = (r ->> 'ahead_minor')::bigint,
         difference_minor = (r ->> 'difference_minor')::bigint,
         difference_reason = case when (r ->> 'difference_minor')::bigint <> 0 then v_reason end,
         updated_at = now()
   where x.tenant_id = v_tenant and x.id = s.id;
  return erp.bank_reconciliation(s.id);
end;
$$;
revoke all on function erp.reconcile_bank_statement(uuid, text) from public, anon;

create or replace function public.erp_reconcile_bank_statement(p_statement_id uuid, p_difference_reason text default null)
returns jsonb
language sql
set search_path = ''
as $$ select erp.reconcile_bank_statement(p_statement_id, p_difference_reason) $$;
revoke all on function public.erp_reconcile_bank_statement(uuid, text) from public, anon;
grant execute on function public.erp_reconcile_bank_statement(uuid, text) to authenticated, service_role;
comment on function public.erp_reconcile_bank_statement(uuid, text) is
  'Reconciles a bank statement whose every line is matched or posted, in order, keeping the figures it reconciled on; '
  'a difference needs a reason (20261013050000). Authorises finance.post.';

create or replace function erp.reopen_bank_statement(p_statement_id uuid, p_reason text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  s        erp.bank_statement%rowtype;
  b        erp.bank_account%rowtype;
begin
  select x.* into s from erp.bank_statement x where x.tenant_id = v_tenant and x.id = p_statement_id for update;
  select x.* into b from erp.bank_account x where x.tenant_id = v_tenant and x.id = s.bank_account_id;
  perform erp.authorise('finance.close_period', b.entity_id, null, null, 'bank_statement', p_statement_id, null);
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'CLOVEERP_BANK_STATEMENT_REOPEN_NEEDS_A_REASON: reopening a reconciled statement needs a reason'
      using errcode = '23514', hint = 'Say what was wrong with the reconciliation, so the auditor can read it.';
  end if;
  if s.id is null or s.status <> 'reconciled'
     or exists (select 1 from erp.bank_statement later
                 where later.tenant_id = v_tenant and later.bank_account_id = s.bank_account_id and later.id <> s.id
                   and later.status = 'reconciled'
                   and (later.ends_on > s.ends_on or (later.ends_on = s.ends_on and later.created_at > s.created_at))) then
    raise exception 'CLOVEERP_BANK_STATEMENT_NOT_REOPENABLE: only the latest reconciled statement of an account is reopened'
      using errcode = '23514', hint = 'Reopen the later reconciled statements first.';
  end if;

  perform erp.append_event('bank_statement.reopened', 'bank_statement', s.id,
                           jsonb_build_object('bank_account', b.name, 'ends_on', s.ends_on,
                                              'difference_minor', s.difference_minor, 'reason', btrim(p_reason)),
                           b.entity_id);
  update erp.bank_statement x
     set status = 'imported', reconciled_at = null, reconciled_by = null, book_minor = null,
         uncleared_in_minor = null, uncleared_out_minor = null, ahead_minor = null, difference_minor = null,
         difference_reason = null,
         updated_at = now()
   where x.tenant_id = v_tenant and x.id = s.id;
  return jsonb_build_object('statement_id', s.id, 'reopened', true);
end;
$$;
revoke all on function erp.reopen_bank_statement(uuid, text) from public, anon;

create or replace function public.erp_reopen_bank_statement(p_statement_id uuid, p_reason text)
returns jsonb
language sql
set search_path = ''
as $$ select erp.reopen_bank_statement(p_statement_id, p_reason) $$;
revoke all on function public.erp_reopen_bank_statement(uuid, text) from public, anon;
grant execute on function public.erp_reopen_bank_statement(uuid, text) to authenticated, service_role;
comment on function public.erp_reopen_bank_statement(uuid, text) is
  'Reopens the latest reconciled statement of a bank account, with a reason (20261013050000). Authorises finance.close_period.';

-- The statements, now with what each reconciled on.
create or replace function public.erp_bank_statements(p_bank_account_id uuid default null)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by x->>'ends_on' desc, x->>'created_at' desc), '[]'::jsonb) from (
    select jsonb_build_object(
      'statement_id', s.id, 'bank_account_id', s.bank_account_id, 'bank_account', b.name,
      'format', s.format, 'source', s.source, 'starts_on', s.starts_on, 'ends_on', s.ends_on,
      'opening_minor', s.opening_minor, 'closing_minor', s.closing_minor, 'currency', b.currency,
      'line_count', s.line_count, 'status', s.status, 'created_at', s.created_at,
      'reconciled_at', s.reconciled_at, 'difference_minor', s.difference_minor,
      'difference_reason', s.difference_reason,
      'unmatched', (select count(*) from erp.bank_statement_line l
                     where l.tenant_id = s.tenant_id and l.statement_id = s.id and l.status = 'unmatched')) as x
      from erp.bank_statement s
      join erp.bank_account b on b.tenant_id = s.tenant_id and b.id = s.bank_account_id
     where s.tenant_id = erp.current_tenant_id()
       and (p_bank_account_id is null or s.bank_account_id = p_bank_account_id)) t
$$;
revoke all on function public.erp_bank_statements(uuid) from public, anon;
grant execute on function public.erp_bank_statements(uuid) to authenticated, service_role;
comment on function public.erp_bank_statements(uuid) is
  'The organisation''s bank statements, newest first, with their unmatched lines counted and what each reconciled on '
  '(20261013020000, 20261013050000). Reads only.';

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
values
  ('bank_statement.reopened', 1, 'bank_statement', 'finance', 'event.bank_statement.reopened',
   'A reconciled bank statement was reopened, with a reason.',
   '{"type":"object","required":["bank_account","ends_on","reason"],"properties":{"bank_account":{"type":"string"},"ends_on":{"type":"string"},"difference_minor":{"type":["integer","null"]},"reason":{"type":"string"}}}'::jsonb, true)
on conflict do nothing;

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('event.bank_statement.reopened', 'en', 'Bank statement reopened', 'finance',
   'Event raised when a reconciled bank statement is reopened.'),
  ('event.bank_statement.reopened', 'de', 'Kontoauszug wieder geöffnet', 'finance',
   'Ereignis, wenn ein abgestimmter Kontoauszug wieder geöffnet wird.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. Locked
-- ─────────────────────────────────────────────────────────────────────────────

-- Matching, unmatching, posting and withdrawing already ask for a statement
-- that is imported. A bank entry's reversal is the one route left: it would
-- take the match off a reconciled line.
do $lock$
declare
  v_sig  constant text := 'erp.bank_entry_follows_journal()';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  else
    delete from erp.bank_match m$o$;
  v_new  constant text := $n$  else
    -- A reconciled statement is locked (20261013050000).
    if exists (select 1 from erp.bank_statement s
                where s.tenant_id = l.tenant_id and s.id = l.statement_id and s.status <> 'imported') then
      raise exception 'CLOVEERP_BANK_MATCH_RECONCILED: the line''s statement is reconciled, and its matches stand'
        using errcode = '23514', hint = 'Reopen the statement on the Bank screen first, or correct the books with a new entry on the next statement.';
    end if;
    delete from erp.bank_match m$n$;
  v_hits integer := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
begin
  if position('20261013050000' in v_def) > 0 then
    return;
  end if;
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % reversal anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$lock$;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The close asks for it
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.assert_bank_reconciled()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.current_tenant_id();
  r         record;
  v_fail    text[] := '{}';
  v_begun   integer := 0;
  v_not     integer := 0;
  v_periods integer := 0;
begin
  -- For each period being closed (20261013050000): every open bank account
  -- of its company that has statements has its last day inside a reconciled
  -- statement that left no difference. An account no statement has been
  -- imported into has not begun to be reconciled, and is said, not failed.
  -- With no period being closed there is nothing to ask.
  for r in
    select fp.id as period_id, fp.code, fp.ends_on, b.id as bank_id, b.name,
           exists (select 1 from erp.bank_statement s where s.tenant_id = b.tenant_id and s.bank_account_id = b.id) as begun,
           exists (select 1 from erp.bank_statement s
                    where s.tenant_id = b.tenant_id and s.bank_account_id = b.id and s.status = 'reconciled'
                      and s.starts_on <= fp.ends_on and s.ends_on >= fp.ends_on
                      and coalesce(s.difference_minor, 0) = 0) as covered
      from erp.fiscal_period fp
      join erp.ledger lg on lg.tenant_id = fp.tenant_id and lg.id = fp.ledger_id and lg.is_primary
      join erp.bank_account b on b.tenant_id = lg.tenant_id and b.entity_id = lg.entity_id and b.status = 'open'
     where fp.tenant_id = v_tenant and fp.status = 'closing'
  loop
    if not r.begun then
      v_not := v_not + 1;
    else
      v_begun := v_begun + 1;
      if not r.covered then
        v_fail := v_fail || format('%s on %s', r.name, r.ends_on);
      end if;
    end if;
  end loop;
  select count(*) into v_periods from erp.fiscal_period fp where fp.tenant_id = v_tenant and fp.status = 'closing';

  if cardinality(v_fail) > 0 then
    raise exception 'CLOVEERP_BANK_NOT_RECONCILED: % has no reconciled statement covering the period''s last day without a difference',
      array_to_string(v_fail, ', ')
      using errcode = '23514',
            hint = 'Import the statement that reaches the period''s last day and reconcile it on the Bank screen, or waive the task with a reason.';
  end if;
  return format('bank reconciled: %s period(s) being closed; %s bank account(s) reconciled to the last day, %s with no statement imported yet',
                v_periods, v_begun, v_not);
end;
$$;
revoke all on function erp.assert_bank_reconciled() from public, anon;

-- A report, as the goods received not invoiced check is: the check on the
-- close's bank task, where a reason waives it; not a gate on the platform.
insert into erp_meta.diagnostic_check (code, title, kind, scope, schema_name, function_name, blurb, runs_in_ci, seq)
values ('bank_reconciled', 'The bank reconciled to the period''s last day', 'report', 'tenant', 'erp', 'assert_bank_reconciled',
        'For each period being closed, every bank account with statements has a reconciled one covering the period''s last '
        'day with no difference left over; an account no statement has been imported into is said, not failed. The check '
        'on the close''s bank task, waived with a reason where a difference is understood.', false, 45)
on conflict (code) do nothing;

create or replace function erp.close_shipped_check(p_task_code text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case lower(btrim(coalesce(p_task_code, '')))
           when 'grni_reviewed' then 'erp.assert_grni_reconciles()'
           -- The bank reconciled to the period's last day (20261013050000).
           when 'bank_reconciled' then 'erp.assert_bank_reconciled()'
         end
$$;

do $configure$
declare
  v_sig  constant text := 'erp.configure_period_close()';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$      jsonb_build_object('kind','close_task','key','trial_balance','payload',$o$;
  v_new  constant text := $n$      -- The bank reconciled to the period's last day; waivable with a
      -- reason (20261013050000).
      jsonb_build_object('kind','close_task','key','bank_reconciled','payload',
        jsonb_build_object(
          'code','bank_reconciled','name','Bank reconciled to the last day of the period',
          'seq',45, 'depends_on', jsonb_build_array('subledgers_reconcile'),
          'blocking_check','erp.assert_bank_reconciled()')),
      jsonb_build_object('kind','close_task','key','trial_balance','payload',$n$;
  v_hits integer := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
begin
  if position('bank_reconciled' in v_def) > 0 then
    return;
  end if;
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % trial balance anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$configure$;

-- The organisations already configured, as 20260918500000 did for the ageing:
-- the register records the version, and the sweep does the work once.
update erp_ref.module_installer
   set current_version = 4,
       description = description
         || ' Version 4 (20261013050000): the bank reconciled to the last day of the period, waivable with a reason.'
 where install_code = 'period-close' and current_version = 3;

insert into erp.close_task_template
  (tenant_id, code, name, seq, depends_on, blocking_check, status)
select t.tenant_id, 'bank_reconciled', 'Bank reconciled to the last day of the period', 45,
       array['subledgers_reconcile'], 'erp.assert_bank_reconciled()', 'active'
  from erp.close_task_template t
 where t.code = 'subledgers_reconcile' and t.status = 'active'
on conflict (tenant_id, code) do nothing;

insert into erp.close_task
  (tenant_id, fiscal_period_id, code, name, seq, depends_on, blocking_check, is_waivable)
select ct.tenant_id, ct.fiscal_period_id, tt.code, tt.name, tt.seq, tt.depends_on, tt.blocking_check, tt.is_waivable
  from erp.close_task ct
  join erp.fiscal_period fp on fp.tenant_id = ct.tenant_id and fp.id = ct.fiscal_period_id
  join erp.close_task_template tt
    on tt.tenant_id = ct.tenant_id and tt.code = 'bank_reconciled' and tt.status = 'active'
 where ct.code = 'subledgers_reconcile'
   and fp.status in ('future', 'open', 'closing')
on conflict (tenant_id, fiscal_period_id, code) do nothing;

update erp.module_installation i
   set installer_version = 4, upgraded_at = now(), updated_at = now()
 where i.install_code = 'period-close' and i.installer_version < 4;

do $swept$
declare
  v_left integer;
begin
  if (select current_version from erp_ref.module_installer where install_code = 'period-close') is distinct from 4 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: the period-close installer is not at version 4';
  end if;
  select count(*) into v_left
    from erp.close_task_template t
   where t.code = 'subledgers_reconcile' and t.status = 'active'
     and not exists (select 1 from erp.close_task_template a
                      where a.tenant_id = t.tenant_id and a.code = 'bank_reconciled'
                        and a.status = 'active' and a.is_waivable
                        and a.blocking_check = 'erp.assert_bank_reconciled()');
  if v_left > 0 then
    raise exception 'CLOVEERP_BANK_CLOSE_TASK_NOT_SWEPT: % organisation(s) hold the close checklist without the waivable bank task', v_left;
  end if;
end
$swept$;

-- ─────────────────────────────────────────────────────────────────────────────
-- E. The suites that counted six close tasks count seven
-- ─────────────────────────────────────────────────────────────────────────────

do $counts$
declare
  r      record;
  v_def  text;
  n      integer;
  i      integer;
begin
  for r in
    select * from (values
      ('erp_test.finance_depth_suite()', array[
         $o$      where t.tenant_id = r.tenant_id and t.status='active') = 6,$o$,
         $n$      where t.tenant_id = r.tenant_id and t.status='active') = 7,  -- Re-pinned by 20261013050000: bank_reconciled.$n$,
         $o$    v_n = 6
$o$,
         $n$    v_n = 7
$n$,
         $o$            and ct.check_output is not null) = 6,$o$,
         $n$            and ct.check_output is not null) = 7,$n$,
         $o$      where cs.check_passes is not null) = 6,$o$,
         $n$      where cs.check_passes is not null) = 7,$n$]),
      ('erp_test.trial_balance_tie_suite()', array[
         $o$          and v_raised = 6;$o$,
         $n$          and v_raised = 7;  -- Re-pinned by 20261013050000: bank_reconciled.$n$]),
      ('erp_test.ageing_tie_suite()', array[
         $o$          and v_raised = 6
$o$,
         $n$          and v_raised = 7  -- Re-pinned by 20261013050000: bank_reconciled.
$n$]),
      ('erp_test.period_close_suite()', array[
         $o$          and v_raised = 6
$o$,
         $n$          and v_raised = 7  -- Re-pinned by 20261013050000: bank_reconciled.
$n$,
         $o$                  and t.check_output is not null) = 6$o$,
         $n$                  and t.check_output is not null) = 7$n$,
         $o$          and (select count(*) from erp.close_task t where t.fiscal_period_id = v_p1) = 6$o$,
         $n$          and (select count(*) from erp.close_task t where t.fiscal_period_id = v_p1) = 7$n$,
         $o$          and (select count(*) from erp.close_task t where t.fiscal_period_id = v_g1) = 6$o$,
         $n$          and (select count(*) from erp.close_task t where t.fiscal_period_id = v_g1) = 7$n$]),
      ('erp_test.step_budget_suite()', array[
         $o$            and (v_close ->> 'tasks')::integer = 6$o$,
         $n$            and (v_close ->> 'tasks')::integer = 7  -- Re-pinned by 20261013050000: bank_reconciled.$n$,
         $o$            and (v_close ->> 'completed_by_controller')::integer = 6$o$,
         $n$            and (v_close ->> 'completed_by_controller')::integer = 7$n$])
    ) v(sig, pairs)
  loop
    v_def := pg_get_functiondef(r.sig::regprocedure);
    if position('Re-pinned by 20261013050000' in v_def) > 0 then
      continue;
    end if;
    for i in 1 .. array_length(r.pairs, 1) / 2 loop
      n := (length(v_def) - length(replace(v_def, r.pairs[2 * i - 1], ''))) / length(r.pairs[2 * i - 1]);
      if n <> 1 then
        raise exception 'CLOVEERP_ANCHOR_MOVED: % count anchor % found % time(s)', r.sig, i, n;
      end if;
      v_def := replace(v_def, r.pairs[2 * i - 1], r.pairs[2 * i]);
    end loop;
    execute v_def;
  end loop;
end
$counts$;

-- period_close_suite's "v_again = 6" occurs twice, both the count of tasks a
-- reopened period raises again; both become seven.
do $again$
declare
  v_def text := pg_get_functiondef('erp_test.period_close_suite()'::regprocedure);
  v_old constant text := $o$          and v_again = 6$o$;
  n     integer := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
begin
  if n = 0 and position('v_again = 7' in v_def) > 0 then
    return;
  end if;
  if n <> 2 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: period_close_suite v_again anchor found % time(s)', n;
  end if;
  execute replace(v_def, v_old, $n$          and v_again = 7$n$);
end
$again$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Governance
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_reconcile_bank_statement', 'erp.reconcile_bank_statement',
   'Reconciles a bank statement whose lines are all matched or posted, in order, keeping its figures; authorises finance.post.'),
  ('erp_reopen_bank_statement', 'erp.reopen_bank_statement',
   'Reopens the latest reconciled statement of a bank account, with a reason; authorises finance.close_period.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp.register_refusal('CLOVEERP_BANK_STATEMENT_NOT_RECONCILABLE',
  'Reconciling a statement that is not imported, or is reconciled already.',
  'A statement is reconciled once; reconciling it again would hide what changed since.',
  'Refresh the statements and choose again.');
select erp.register_refusal('CLOVEERP_BANK_STATEMENT_OUT_OF_ORDER',
  'Reconciling a statement while an earlier one of the same account is not reconciled.',
  'Each reconciliation starts from the one before it; out of order, a line could be left out of both.',
  'Reconcile the account''s statements in order, the earliest first.');
select erp.register_refusal('CLOVEERP_BANK_STATEMENT_LINES_OPEN',
  'Reconciling a statement with a line neither matched nor posted.',
  'A line the books do not account for is a difference the reconciliation would hide.',
  'Match each line, post it by rule or by hand, or receive it as cash.');
select erp.register_refusal('CLOVEERP_BANK_RECONCILIATION_DIFFERENCE',
  'Reconciling a statement whose books and bank, after what the bank has not yet shown, do not agree, without a reason.',
  'A difference reconciled without a word is a difference nobody will look for again.',
  'Correct the books, or reconcile with a reason saying why the difference stands.');
select erp.register_refusal('CLOVEERP_BANK_STATEMENT_REOPEN_NEEDS_A_REASON',
  'Reopening a reconciled statement without a reason.',
  'A reconciliation the close relied on is being undone; the auditor needs to read why.',
  'Say what was wrong with the reconciliation.');
select erp.register_refusal('CLOVEERP_BANK_STATEMENT_NOT_REOPENABLE',
  'Reopening a statement that is not reconciled, or is not the latest reconciled one of its account.',
  'Reopening an earlier one would leave a later reconciliation standing on figures that may change.',
  'Reopen the later reconciled statements first.');

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Reconciling a bank statement (20261013050000).'
  from (values
    ('Reconcile'),
    ('Reconcile this statement'),
    ('Every line is matched or posted. The statement is locked once it is reconciled; somebody who may close periods can reopen the latest one with a reason.'),
    ('Why the difference stands'),
    ('Needed only when the books and the bank do not agree.'),
    ('Books wrong before the bank statements began'),
    ('Reconciliation'),
    ('Show the reconciliation'),
    ('Hide the reconciliation'),
    ('Balance per bank statement'),
    ('Add: receipts the bank has not shown'),
    ('Less: payments the bank has not shown'),
    ('Less: on the bank, in the books after this day'),
    ('Adjusted bank balance'),
    ('Balance per books'),
    ('Difference'),
    ('Not yet on the bank'),
    ('Reconciled'),
    ('Reopen'),
    ('Reopen this statement'),
    ('The statement is unlocked so its lines can be matched or posted again. Only the latest reconciled statement of an account is reopened.'),
    ('Why it is reopened'),
    ('A receipt was matched to the wrong line'),
    ('Kept with the statement for the auditor.')) v(text)
on conflict do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- E. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.bank_reconciliation_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 7;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_tenant uuid;
  v_ent    uuid;
  v_ccy    character(3);
  v_site   uuid;
  v_item   uuid;
  v_uom    uuid;
  v_bank   uuid;
  v_fees   uuid;
  v_inv    uuid;
  v_cust   uuid;
  v_s1     uuid;
  v_s2     uuid;
  v_ln     uuid[];
  v_period uuid;
  v_book0  bigint;
  v_rev    uuid;
  x        jsonb;
  v_ok     boolean;
  v_msg    text;
begin
  begin
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzbrc' || v_tag, 'Bank Reconciliation Suite',
      'admin@demo-zzbrc' || v_tag || '.test', 'Reconciliation Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzbrc' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    v_tenant := rb.tenant_id;

    v_step := 'a company, its bank, a customer who paid twice';
    select e.id, e.base_currency into v_ent, v_ccy from erp.entity e
     where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;
    select b.id into v_bank from erp.bank_account b where b.tenant_id = v_tenant and b.entity_id = v_ent and b.is_default;
    v_fees := erp.settlement_difference_account(v_ent);
    select s.id into v_site from erp.site s
     where s.tenant_id = v_tenant and s.entity_id = v_ent and s.status = 'active'
     order by (s.site_type = 'warehouse') desc, s.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = v_tenant order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (v_tenant, 'ZBRWID', 'Bank Reconciliation Widget', v_uom, 'active') returning id into v_item;
    v_inv := erp_test.cash_tolerance_customer_invoice(v_ent, v_site, v_item, v_ccy, 'ZBR1' || v_tag, 50000);
    select d.party_id into v_cust from erp.document d where d.id = v_inv;
    -- The books' bank balance before the statements begin is the statement's
    -- opening balance.
    select coalesce(sum(jl.debit_minor - jl.credit_minor), 0) into v_book0
      from erp.journal_line jl join erp.journal j on j.id = jl.journal_id
      join erp.bank_account b on b.account_id = jl.account_id
     where b.id = v_bank and j.status = 'posted';
    -- Three receipts, banked today: the first on yesterday's statement (the
    -- bank was a day ahead of the books), the second on today's, the third
    -- never on the bank.
    perform public.erp_apply_cash(v_cust, 7000, v_ccy, 'ZBR-R1', array[v_inv]);
    perform public.erp_apply_cash(v_cust, 3000, v_ccy, 'ZBR-R2', array[v_inv]);
    perform public.erp_apply_cash(v_cust, 4000, v_ccy, 'ZBR-R3', array[v_inv]);

    v_step := 'a statement showing one of the receipts and a fee';
    x := public.erp_import_bank_statement(v_bank, 'csv', 'natwest', md5('r1' || v_tag) || md5('r1b' || v_tag),
           v_book0 + 7000 - 500,
           jsonb_build_array(
             jsonb_build_object('booked_on', current_date - 1, 'amount_minor', 7000, 'description', 'ZBR-R1 TRANSFER'),
             jsonb_build_object('booked_on', current_date - 1, 'amount_minor', -500, 'description', 'SERVICE CHARGE')),
           v_book0);
    v_s1 := (x ->> 'statement_id')::uuid;
    select array_agg(l.id order by l.line_no) into v_ln from erp.bank_statement_line l where l.statement_id = v_s1;

    -- ── 1. Not with a line open ─────────────────────────────────────────────
    v_step := 'reconciling with a line open';
    perform public.erp_auto_match_bank_statement(v_s1);
    begin
      perform public.erp_reconcile_bank_statement(v_s1);
      v_ok := false; v_msg := 'reconciled with the fee unposted';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_BANK_STATEMENT_LINES_OPEN%'; v_msg := left(sqlerrm, 100);
    end;
    v_cases := v_cases + 1;
    case_name := 'a statement with a line neither matched nor posted is not reconciled';
    passed := v_state is null and v_ok;
    detail := coalesce(v_state, v_msg);
    return next;

    -- ── 2. The reconciliation's figures ─────────────────────────────────────
    v_step := 'the fee posted by rule, and the reconciliation read';
    perform public.erp_define_bank_rule('Service charge', 'service charge', v_fees, 'out');
    perform public.erp_apply_bank_rules(v_s1);
    x := public.erp_bank_reconciliation(v_s1);
    v_cases := v_cases + 1;
    case_name := 'the reconciliation takes off what the bank showed before the books dated it, and the books agree with the bank';
    passed := v_state is null
          and (x ->> 'unmatched_lines')::integer = 0
          and (x ->> 'uncleared_in_minor')::bigint = 0
          and (x ->> 'ahead_minor')::bigint = 7000
          and (x ->> 'book_minor')::bigint = v_book0 - 500
          and (x ->> 'difference_minor')::bigint = 0
          and jsonb_array_length(x -> 'ahead') = 1;
    detail := coalesce(v_state, x::text);
    return next;

    -- ── 3. Reconciled and locked ────────────────────────────────────────────
    v_step := 'reconciled, then tried again';
    x := public.erp_reconcile_bank_statement(v_s1);
    begin
      perform public.erp_unmatch_bank_line(v_ln[1], 'second thoughts');
      v_ok := false; v_msg := 'unmatched on a reconciled statement';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_BANK_MATCH_RECONCILED%'; v_msg := left(sqlerrm, 80);
    end;
    begin
      perform public.erp_withdraw_bank_statement(v_s1, 'gone');
      v_ok := false; v_msg := v_msg || ' | withdrawn';
    exception when others then
      v_ok := v_ok and sqlerrm like 'CLOVEERP_BANK_STATEMENT_CANNOT_WITHDRAW%';
    end;
    begin
      perform public.erp_reverse_journal((select be.journal_id from erp.bank_entry be where be.line_id = v_ln[2]),
                                         'not a fee', current_date);
      select j.id into v_rev from erp.journal j
       where j.reverses_journal_id = (select be.journal_id from erp.bank_entry be where be.line_id = v_ln[2]);
      if erp.journal_state(v_rev) = 'draft' then
        perform erp.submit_journal(v_rev);
      end if;
      perform public.erp_approve_journal(v_rev);
      v_ok := false; v_msg := v_msg || ' | entry reversed';
    exception when others then
      v_ok := v_ok and sqlerrm like 'CLOVEERP_BANK_MATCH_RECONCILED%'; v_msg := v_msg || ' | ' || left(sqlerrm, 60);
    end;
    v_cases := v_cases + 1;
    case_name := 'a reconciled statement keeps its figures, and is not unmatched, withdrawn, or changed by reversing its entry';
    passed := v_state is null and v_ok
          and (select s.status = 'reconciled' and s.difference_minor = 0 and s.ahead_minor = 7000
                 from erp.bank_statement s where s.id = v_s1);
    detail := coalesce(v_state, v_msg);
    return next;

    -- ── 4. In order, and a difference needs a reason ────────────────────────
    v_step := 'a second statement, with a line the books never held';
    x := public.erp_import_bank_statement(v_bank, 'csv', 'natwest', md5('r2' || v_tag) || md5('r2b' || v_tag),
           v_book0 + 7000 - 500 + 3000 + 1,
           jsonb_build_array(
             jsonb_build_object('booked_on', current_date, 'amount_minor', 3000, 'description', 'ZBR-R2 TRANSFER'),
             jsonb_build_object('booked_on', current_date, 'amount_minor', 1, 'description', 'ROUNDING')));
    v_s2 := (x ->> 'statement_id')::uuid;
    perform public.erp_auto_match_bank_statement(v_s2);
    perform public.erp_reopen_bank_statement(v_s1, 'checking the order');
    begin
      perform public.erp_reconcile_bank_statement(v_s2);
      v_ok := false; v_msg := 'reconciled before the first';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_BANK_STATEMENT_OUT_OF_ORDER%'; v_msg := left(sqlerrm, 80);
    end;
    -- Reconciled again: what the later statement matched changes nothing as
    -- at the first's last day.
    perform public.erp_reconcile_bank_statement(v_s1);
    -- The penny the books never held is posted by a rule.
    perform public.erp_define_bank_rule('Rounding', 'rounding', v_fees, 'in');
    perform public.erp_apply_bank_rules(v_s2);
    x := public.erp_bank_reconciliation(v_s2);
    v_cases := v_cases + 1;
    case_name := 'statements reconcile in order, and the second agrees once its last line is posted, with the receipt never banked uncleared';
    passed := v_state is null and v_ok and (x ->> 'difference_minor')::bigint = 0
          and (x ->> 'uncleared_in_minor')::bigint = 4000
          and (x ->> 'ahead_minor')::bigint = 0
          and (x -> 'uncleared' -> 0 ->> 'amount_minor')::bigint = 4000;
    detail := coalesce(v_state, v_msg || ' ' || x::text);
    return next;

    -- ── 5. A difference needs a reason ──────────────────────────────────────
    v_step := 'a difference, reconciled';
    -- A bank balance a pound away from the books, as a statement whose
    -- printed closing the bank later corrected would be; set straight on the
    -- row, since an import refuses lines that do not add up.
    update erp.bank_statement s set closing_minor = s.closing_minor + 100 where s.id = v_s2;
    begin
      perform public.erp_reconcile_bank_statement(v_s2);
      v_ok := false; v_msg := 'reconciled with a difference and no reason';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_BANK_RECONCILIATION_DIFFERENCE%'; v_msg := left(sqlerrm, 120);
    end;
    x := public.erp_reconcile_bank_statement(v_s2, 'the bank''s figure includes a credit it reversed the next day');
    v_cases := v_cases + 1;
    case_name := 'a reconciliation that does not agree needs a reason, which it keeps with the difference';
    passed := v_state is null and v_ok
          and (select s.difference_minor = -100 and s.difference_reason like 'the bank%' from erp.bank_statement s where s.id = v_s2);
    detail := coalesce(v_state, v_msg);
    return next;

    -- ── 6. Reopened: the latest only, with a reason ─────────────────────────
    v_step := 'reopening';
    begin
      perform public.erp_reopen_bank_statement(v_s1, 'earlier');
      v_ok := false; v_msg := 'an earlier one reopened';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_BANK_STATEMENT_NOT_REOPENABLE%'; v_msg := left(sqlerrm, 80);
    end;
    begin
      perform public.erp_reopen_bank_statement(v_s2, ' ');
      v_ok := false; v_msg := v_msg || ' | reopened without a reason';
    exception when others then
      v_ok := v_ok and sqlerrm like 'CLOVEERP_BANK_STATEMENT_REOPEN_NEEDS_A_REASON%';
    end;
    v_cases := v_cases + 1;
    case_name := 'only the latest reconciled statement is reopened, and only with a reason';
    passed := v_state is null and v_ok;
    detail := coalesce(v_state, v_msg);
    return next;

    -- ── 7. The close asks for it ────────────────────────────────────────────
    v_step := 'the close of this month';
    select fp.id into v_period
      from erp.fiscal_period fp join erp.ledger lg on lg.id = fp.ledger_id and lg.is_primary and lg.entity_id = v_ent
     where fp.tenant_id = v_tenant and current_date between fp.starts_on and fp.ends_on
     order by fp.starts_on limit 1;
    update erp.fiscal_period set status = 'closing' where id = v_period;
    begin
      perform erp.assert_bank_reconciled();
      v_ok := false; v_msg := 'passed with the month''s end not reached';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_BANK_NOT_RECONCILED%'; v_msg := left(sqlerrm, 120);
    end;
    -- An account with no statement is said, not failed.
    perform public.erp_define_bank_account(v_ent, '1010', 'Savings', null, null, false);
    update erp.bank_statement s set ends_on = (select fp.ends_on from erp.fiscal_period fp where fp.id = v_period),
                                    difference_minor = 0
     where s.id = v_s2;
    v_cases := v_cases + 1;
    case_name := 'the close''s bank task fails until a reconciled statement with no difference reaches the month''s end, and passes an account not begun';
    passed := v_state is null and v_ok
          and erp.assert_bank_reconciled() like '%1 bank account(s) reconciled to the last day, 1 with no statement imported yet'
          and exists (select 1 from erp.close_task_template t
                       where t.tenant_id = v_tenant and t.code = 'bank_reconciled' and t.is_waivable
                         and t.blocking_check = 'erp.assert_bank_reconciled()');
    detail := coalesce(v_state, v_msg || ' | ' || coalesce(erp.assert_bank_reconciled(), ''));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_BANK_RECONCILIATION_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;
revoke all on function erp_test.bank_reconciliation_suite() from public, anon, authenticated;

create or replace function erp_test.assert_bank_reconciliation_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 7;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _bank_reconciliation on commit drop as
    select * from erp_test.bank_reconciliation_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _bank_reconciliation;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_BANK_RECONCILIATION_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_BANK_RECONCILIATION_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('bank reconciliation: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_bank_reconciliation_suite() from public, anon, authenticated;

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
select erp.assert_invoker_doors_executable();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
select erp.assert_personal_data_register_sound();
select erp.assert_write_only_columns();
