set lock_timeout = '30s';

-- Statements, at last: a period result and a position that balances.

create or replace function erp.statement_lines(
  p_from date,
  p_to date,
  p_ledger text,
  p_cost_centre text)
returns table (
  account_code text,
  account_name text,
  account_type text,
  currency text,
  debit_minor bigint,
  credit_minor bigint)
language sql
stable
set search_path to ''
as $$
  select a.code, a.name, a.account_type::text,
         coalesce(led.currency, l.currency),
         sum(l.base_debit_minor)::bigint,
         sum(l.base_credit_minor)::bigint
    from erp.journal_line l
    join erp.journal j on j.id = l.journal_id and j.status = 'posted'
    join erp.ledger led on led.id = j.ledger_id
    join erp.account a on a.id = l.account_id
   where l.tenant_id = erp.current_tenant_id()
     and (p_from is null or j.posting_date >= p_from)
     and (p_to is null or j.posting_date <= p_to)
     and (p_ledger is null or led.code = upper(btrim(p_ledger)))
     and (p_cost_centre is null
          or l.dimensions ->> 'COST_CENTRE' = upper(btrim(p_cost_centre)))
   group by a.code, a.name, a.account_type, coalesce(led.currency, l.currency)
$$;

comment on function erp.statement_lines is
  'Posted movement per account, narrowed by period, ledger and cost centre.';

create or replace function public.erp_profit_and_loss(
  p_from date default null,
  p_to date default null,
  p_ledger text default 'GL',
  p_cost_centre text default null)
returns jsonb
language plpgsql
stable
set search_path to ''
as $$
declare
  v_from date := coalesce(p_from, date_trunc('year', current_date)::date);
  v_to date := coalesce(p_to, current_date);
  v_lines jsonb;
  v_income bigint;
  v_expense bigint;
begin
  perform erp.authorise('finance.read');

  select coalesce(jsonb_agg(jsonb_build_object(
           'account', s.account_code,
           'name', s.account_name,
           'account_type', s.account_type,
           'currency', s.currency,
           'amount_minor', case when s.account_type = 'income'
                                then s.credit_minor - s.debit_minor
                                else s.debit_minor - s.credit_minor end)
           order by s.account_type, s.account_code), '[]'::jsonb),
         coalesce(sum(case when s.account_type = 'income'
                           then s.credit_minor - s.debit_minor else 0 end), 0),
         coalesce(sum(case when s.account_type = 'expense'
                           then s.debit_minor - s.credit_minor else 0 end), 0)
    into v_lines, v_income, v_expense
    from erp.statement_lines(v_from, v_to, p_ledger, p_cost_centre) s
   where s.account_type in ('income', 'expense');

  return jsonb_build_object(
    'from', v_from,
    'to', v_to,
    'ledger', upper(btrim(coalesce(p_ledger, ''))),
    'cost_centre', upper(btrim(coalesce(p_cost_centre, ''))),
    'lines', v_lines,
    'income_minor', v_income,
    'expense_minor', v_expense,
    'result_minor', v_income - v_expense);
end $$;

comment on function public.erp_profit_and_loss is
  'Income, expense and the result for a period, optionally for one cost centre.';

create or replace function public.erp_balance_sheet(
  p_as_at date default null,
  p_ledger text default 'GL',
  p_cost_centre text default null)
returns jsonb
language plpgsql
stable
set search_path to ''
as $$
declare
  v_as_at date := coalesce(p_as_at, current_date);
  v_lines jsonb;
  v_assets bigint;
  v_liabilities bigint;
  v_equity bigint;
  v_result bigint;
begin
  perform erp.authorise('finance.read');

  select coalesce(jsonb_agg(jsonb_build_object(
           'account', s.account_code,
           'name', s.account_name,
           'account_type', s.account_type,
           'currency', s.currency,
           'amount_minor', case when s.account_type = 'asset'
                                then s.debit_minor - s.credit_minor
                                else s.credit_minor - s.debit_minor end)
           order by s.account_type, s.account_code), '[]'::jsonb),
         coalesce(sum(case when s.account_type = 'asset'
                           then s.debit_minor - s.credit_minor else 0 end), 0),
         coalesce(sum(case when s.account_type = 'liability'
                           then s.credit_minor - s.debit_minor else 0 end), 0),
         coalesce(sum(case when s.account_type = 'equity'
                           then s.credit_minor - s.debit_minor else 0 end), 0)
    into v_lines, v_assets, v_liabilities, v_equity
    from erp.statement_lines(null, v_as_at, p_ledger, p_cost_centre) s
   where s.account_type in ('asset', 'liability', 'equity');

  select coalesce(sum(case when s.account_type = 'income'
                           then s.credit_minor - s.debit_minor
                           else s.debit_minor - s.credit_minor end
                      * case when s.account_type = 'income' then 1 else -1 end), 0)
    into v_result
    from erp.statement_lines(null, v_as_at, p_ledger, p_cost_centre) s
   where s.account_type in ('income', 'expense');

  return jsonb_build_object(
    'as_at', v_as_at,
    'ledger', upper(btrim(coalesce(p_ledger, ''))),
    'cost_centre', upper(btrim(coalesce(p_cost_centre, ''))),
    'lines', v_lines,
    'assets_minor', v_assets,
    'liabilities_minor', v_liabilities,
    'equity_minor', v_equity,
    'result_minor', v_result,
    'balances', v_assets = v_liabilities + v_equity + v_result,
    'difference_minor', v_assets - (v_liabilities + v_equity + v_result));
end $$;

comment on function public.erp_balance_sheet is
  'Assets, liabilities, equity and the result to date, with the balance check made explicit.';

drop function if exists public.erp_trial_balance();

create or replace function public.erp_trial_balance(
  p_from date default null,
  p_to date default null,
  p_ledger text default null,
  p_cost_centre text default null)
returns jsonb
language plpgsql
stable
set search_path to ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('finance.read');
  select coalesce(jsonb_agg(jsonb_build_object(
           'ledger', upper(btrim(coalesce(p_ledger, 'ALL'))),
           'account', s.account_code,
           'name', s.account_name,
           'account_type', s.account_type,
           'currency', s.currency,
           'debit_minor', s.debit_minor,
           'credit_minor', s.credit_minor,
           'balance_minor', s.debit_minor - s.credit_minor)
           order by s.account_code), '[]'::jsonb)
    into v_out
    from erp.statement_lines(p_from, p_to, p_ledger, p_cost_centre) s;
  return v_out;
end $$;

comment on function public.erp_trial_balance is
  'The trial balance, optionally narrowed to a period, a ledger and a cost centre.';

revoke all on function public.erp_profit_and_loss(date, date, text, text) from public, anon;
grant execute on function public.erp_profit_and_loss(date, date, text, text) to authenticated, service_role;
revoke all on function public.erp_balance_sheet(date, text, text) from public, anon;
grant execute on function public.erp_balance_sheet(date, text, text) to authenticated, service_role;
revoke all on function public.erp_trial_balance(date, date, text, text) from public, anon;
grant execute on function public.erp_trial_balance(date, date, text, text) to authenticated, service_role;

-- Every posted journal balances, in base currency, for every organisation.
create or replace function erp.assert_posted_journals_balance()
returns text
language plpgsql
set search_path to ''
as $$
declare v_bad int;
begin
  select count(*) into v_bad from (
    select j.id
      from erp.journal j
      join erp.journal_line l on l.journal_id = j.id
     where j.status = 'posted'
     group by j.id
    having sum(l.base_debit_minor) <> sum(l.base_credit_minor)) s;

  if v_bad > 0 then
    raise exception 'CLOVEERP_ASSERTION: % posted journals do not balance', v_bad;
  end if;
  return 'posted journals balance';
end $$;

comment on function erp.assert_posted_journals_balance is
  'A posted journal whose debits and credits differ would make the balance sheet a fiction.';

select erp.assert_posted_journals_balance();

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();
select erp.assert_public_api_safe();