set lock_timeout = '30s';

-- =============================================================================
-- 20261006201000  A balance sheet reads its lines once
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-137). Typing a date
-- into Profit and balance sheet read the whole ledger again for every
-- keystroke of the year, and each read was slow:
--
--   (a) public.erp_balance_sheet read erp.statement_lines twice over the same
--       days, once for the balance sheet's own accounts and once for the
--       result to date.
--   (b) erp.statement_lines joined the journal, the ledger and the account by
--       id only. Each of them asks who is signed in (erp.current_tenant_id)
--       in its row policy, and with nothing else naming the organisation the
--       policy was checked row by row. Measured on a demonstration with a
--       month of trading (419 journal lines): 4,853 calls of
--       erp.current_tenant_id for one balance sheet.
--
-- The screen's half (the date is read when the field is left, on Enter, or
-- once it stands still, and the last statement stays on screen meanwhile) is
-- in src/routes/finance/statements.tsx.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp_test.statement_lines_reference and erp_test.balance_sheet_reference:
--      today's bodies, word for word, kept as the answer the new ones must
--      give.
--   B. erp.statement_lines, same signature, grants and answer: it asks for
--      the organisation once and names it on every table it reads, so the row
--      policies are met by the same condition rather than row by row. On the
--      same demonstration a balance sheet now asks four times. The profit and
--      loss, the reconciliation of goods received not invoiced and every other
--      reader of statement_lines read it this way too.
--   C. public.erp_balance_sheet, same signature, gate and answer: the lines
--      and the result to date come from one read of statement_lines.
--   D. erp_test.statements_read_once_suite, on a demonstration with ten days
--      of trading, cost centres grouped under a heading, a journal charged to
--      one of them and a second organisation that posted to a centre of the
--      same code: for every range, ledger and cost centre the lines are the
--      reference's, the balance sheet is the reference's (read by the suite's
--      owner and by a signed-in reader), the other organisation's postings
--      are in neither, and the two bodies read as described.
--
-- On production: one routine and one door are replaced and two references
-- added. No table is altered and no row is changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. Today's bodies, kept as the answer
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.statement_lines_reference(p_from date, p_to date, p_ledger text, p_cost_centre text)
returns table(account_code text, account_name text, account_type text, currency text, debit_minor bigint, credit_minor bigint)
language sql
stable
set search_path = ''
as $$
  with recursive beneath as (
    select dv.id, dv.code, 1 as depth
      from erp.dimension_value dv
      join erp.dimension dm on dm.tenant_id = dv.tenant_id and dm.id = dv.dimension_id
     where dv.tenant_id = erp.current_tenant_id()
       and dm.code = 'COST_CENTRE'
       and dv.code = upper(btrim(p_cost_centre))
    union all
    select child.id, child.code, beneath.depth + 1
      from erp.dimension_value child
      join beneath on child.parent_value_id = beneath.id
     where child.tenant_id = erp.current_tenant_id()
       -- A parent chain is a tree in the screen and nothing enforces that it is
       -- one in the table. Twenty levels is deeper than any chart of centres,
       -- and a loop stops rather than hanging the report.
       and beneath.depth < 20
  )
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
          -- The centre itself, whether or not finance ever declared it as a
          -- dimension value, and then everything grouped under it.
          or l.dimensions ->> 'COST_CENTRE' = upper(btrim(p_cost_centre))
          or l.dimensions ->> 'COST_CENTRE' in (select b.code from beneath b))
   group by a.code, a.name, a.account_type, coalesce(led.currency, l.currency)
$$;

revoke all on function erp_test.statement_lines_reference(date, date, text, text) from public, anon;

comment on function erp_test.statement_lines_reference(date, date, text, text) is
  'erp.statement_lines as it stood before 20261006201000, word for word: the answer the statement lines must '
  'still give (J-137). Read only by erp_test.statements_read_once_suite.';

create or replace function erp_test.balance_sheet_reference(p_as_at date default null, p_ledger text default 'GL', p_cost_centre text default null)
returns jsonb
language plpgsql
set search_path = ''
as $reference$
declare
  v_as_at date := coalesce(p_as_at, current_date);
  v_lines jsonb;
  v_assets bigint;
  v_liabilities bigint;
  v_equity bigint;
  v_result bigint;
begin
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
    from erp_test.statement_lines_reference(null, v_as_at, p_ledger, p_cost_centre) s
   where s.account_type in ('asset', 'liability', 'equity');

  select coalesce(sum(case when s.account_type = 'income'
                           then s.credit_minor - s.debit_minor
                           else s.debit_minor - s.credit_minor end
                      * case when s.account_type = 'income' then 1 else -1 end), 0)
    into v_result
    from erp_test.statement_lines_reference(null, v_as_at, p_ledger, p_cost_centre) s
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
end
$reference$;

revoke all on function erp_test.balance_sheet_reference(date, text, text) from public, anon;

comment on function erp_test.balance_sheet_reference(date, text, text) is
  'public.erp_balance_sheet as it stood before 20261006201000, word for word after its authorise call and '
  'reading erp_test.statement_lines_reference: the answer the balance sheet must still give (J-137). Read only '
  'by erp_test.statements_read_once_suite.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The statement lines ask for the organisation once
-- ─────────────────────────────────────────────────────────────────────────────

do $guard$
declare
  v_sig constant text := 'erp.statement_lines(date,date,text,text)';
  v_src text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
begin
  if strpos(v_src, '20261006201000') > 0 then
    raise notice '% already asks for the organisation once; written again as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'c7cb183aa239e5747667bdb7eb247135' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006201000 expects (md5 %)', v_sig, md5(v_src);
  end if;
end
$guard$;

create or replace function erp.statement_lines(p_from date, p_to date, p_ledger text, p_cost_centre text)
returns table(account_code text, account_name text, account_type text, currency text, debit_minor bigint, credit_minor bigint)
language plpgsql
stable
set search_path = ''
as $$
#variable_conflict use_column
declare
  -- Asked once (20261006201000, J-137). Every table below names it, so the
  -- row policy each of them carries is met by the same condition instead of
  -- asking who is signed in for every row it reads.
  v_tenant uuid := erp.current_tenant_id();
begin
  return query
  with recursive beneath as (
    select dv.id, dv.code, 1 as depth
      from erp.dimension_value dv
      join erp.dimension dm on dm.tenant_id = dv.tenant_id and dm.id = dv.dimension_id
     where dv.tenant_id = v_tenant
       and dm.tenant_id = v_tenant
       and dm.code = 'COST_CENTRE'
       and dv.code = upper(btrim(p_cost_centre))
    union all
    select child.id, child.code, beneath.depth + 1
      from erp.dimension_value child
      join beneath on child.parent_value_id = beneath.id
     where child.tenant_id = v_tenant
       -- A parent chain is a tree in the screen and nothing enforces that it is
       -- one in the table. Twenty levels is deeper than any chart of centres,
       -- and a loop stops rather than hanging the report.
       and beneath.depth < 20
  )
  select a.code::text, a.name::text, a.account_type::text,
         coalesce(led.currency, l.currency)::text,
         sum(l.base_debit_minor)::bigint,
         sum(l.base_credit_minor)::bigint
    from erp.journal_line l
    join erp.journal j on j.tenant_id = v_tenant and j.id = l.journal_id and j.status = 'posted'
    join erp.ledger led on led.tenant_id = v_tenant and led.id = j.ledger_id
    join erp.account a on a.tenant_id = v_tenant and a.id = l.account_id
   where l.tenant_id = v_tenant
     and (p_from is null or j.posting_date >= p_from)
     and (p_to is null or j.posting_date <= p_to)
     and (p_ledger is null or led.code = upper(btrim(p_ledger)))
     and (p_cost_centre is null
          -- The centre itself, whether or not finance ever declared it as a
          -- dimension value, and then everything grouped under it.
          or l.dimensions ->> 'COST_CENTRE' = upper(btrim(p_cost_centre))
          or l.dimensions ->> 'COST_CENTRE' in (select b.code from beneath b))
   group by a.code, a.name, a.account_type, coalesce(led.currency, l.currency);
end
$$;

comment on function erp.statement_lines(date, date, text, text) is
  'Posted movement per account, narrowed by period, ledger and cost centre. A cost centre carries what was '
  'posted to it and to every centre grouped beneath it, so a heading reads as the heading its parent field made '
  'it. The organisation is asked for once and named on every table read (20261006201000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The balance sheet reads its lines once
-- ─────────────────────────────────────────────────────────────────────────────

do $sheet$
declare
  v_sig  constant text := 'public.erp_balance_sheet(date,text,text)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  select coalesce(jsonb_agg(jsonb_build_object(
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
   where s.account_type in ('income', 'expense');$o$;
  v_new  constant text := $n$  -- One read of the lines (20261006201000, J-137): the balance sheet's own
  -- accounts and the result to date come from the same pass.
  select coalesce(jsonb_agg(jsonb_build_object(
           'account', s.account_code,
           'name', s.account_name,
           'account_type', s.account_type,
           'currency', s.currency,
           'amount_minor', case when s.account_type = 'asset'
                                then s.debit_minor - s.credit_minor
                                else s.credit_minor - s.debit_minor end)
           order by s.account_type, s.account_code)
           filter (where s.account_type in ('asset', 'liability', 'equity')), '[]'::jsonb),
         coalesce(sum(case when s.account_type = 'asset'
                           then s.debit_minor - s.credit_minor else 0 end), 0),
         coalesce(sum(case when s.account_type = 'liability'
                           then s.credit_minor - s.debit_minor else 0 end), 0),
         coalesce(sum(case when s.account_type = 'equity'
                           then s.credit_minor - s.debit_minor else 0 end), 0),
         coalesce(sum(case when s.account_type = 'income'
                           then s.credit_minor - s.debit_minor
                           else s.debit_minor - s.credit_minor end
                      * case when s.account_type = 'income' then 1 else -1 end)
                  filter (where s.account_type in ('income', 'expense')), 0)
    into v_lines, v_assets, v_liabilities, v_equity, v_result
    from erp.statement_lines(null, v_as_at, p_ledger, p_cost_centre) s
   where s.account_type in ('asset', 'liability', 'equity', 'income', 'expense');$n$;
begin
  if strpos(v_src, '20261006201000') > 0 then
    raise notice '% already reads its lines once; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'a13e0d3bf2cde70b5a43078b25627ede' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006201000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$sheet$;

comment on function public.erp_balance_sheet(date, text, text) is
  'Assets, liabilities, equity and the result to date, with the balance check made explicit. The lines and '
  'the result come from one read of erp.statement_lines (20261006201000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.statements_read_once_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 4;
  c_amount   constant bigint := 75000;
  c_other    constant bigint := 1234500;
  v_cases    integer := 0;
  v_tag      text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1         uuid := gen_random_uuid();
  a2         uuid := gen_random_uuid();
  v_owner    text := current_user;
  v_step     text := 'provisioning';
  v_state    text;
  rb         record;
  r2         record;
  v_day0     date := (date_trunc('month', current_date) - interval '3 months')::date;
  v_ledger   uuid;
  v_entity   uuid;
  v_ccy      char(3);
  v_expense  uuid;
  v_asset    uuid;
  v_journal  uuid;
  v_from     date;
  v_to       date;
  v_led      text;
  v_cc       text;
  v_new      jsonb;
  v_ref      jsonb;
  v_combos   integer := 0;
  v_rows     integer := 0;
  v_differ   text := '';
  v_sheets   integer := 0;
  v_signed   jsonb;
  v_signed_ref jsonb;
  v_mine     bigint;
  v_theirs   bigint;
  v_heading  jsonb;
  v_src_bs   text;
  v_src_sl   text;
begin
  begin
    -- ── A demonstration with ten days of trading ────────────────────────────
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzst' || v_tag, 'Statements Suite', 'admin@demo-zzst' || v_tag || '.test', 'Statements Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzst' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    v_step := 'ten days of trading three months back';
    perform erp_test.build_demo_days(v_day0, v_day0 + 9);

    -- ── Cost centres under a heading, and a journal charged to one ─────────
    v_step := 'the cost centres and a journal charged to one of them';
    perform erp.ensure_cost_centre_dimension();
    perform erp.upsert_dimension_value('COST_CENTRE', 'ZZ-HEAD', 'Operations, all of it');
    perform erp.upsert_dimension_value('COST_CENTRE', 'ZZ-LEEDS', 'Leeds operations', 'ZZ-HEAD');
    perform erp.upsert_dimension_value('COST_CENTRE', 'ZZ-ELSEWHERE', 'Somewhere else entirely');
    select l.id, l.entity_id, l.currency into v_ledger, v_entity, v_ccy
      from erp.ledger l where l.tenant_id = rb.tenant_id and l.is_primary order by l.code limit 1;
    select a.id into v_expense from erp.account a
     where a.tenant_id = rb.tenant_id and a.entity_id = v_entity and a.is_postable
       and a.status = 'active' and a.account_type = 'expense' order by a.code limit 1;
    select a.id into v_asset from erp.account a
     where a.tenant_id = rb.tenant_id and a.entity_id = v_entity and a.is_postable
       and a.status = 'active' and a.account_type = 'asset' order by a.code limit 1;
    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date,
                             description, status, manual_reason)
    values (rb.tenant_id, v_entity, v_ledger, 'manual', current_date,
            'statements read once suite', 'draft', 'the suite is proving the statements')
    returning id into v_journal;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor,
                                  credit_minor, currency, base_debit_minor, base_credit_minor,
                                  exchange_rate, dimensions)
    values (rb.tenant_id, v_journal, 1, v_expense, c_amount, 0, v_ccy, c_amount, 0, 1,
            jsonb_build_object('COST_CENTRE', 'ZZ-LEEDS')),
           (rb.tenant_id, v_journal, 2, v_asset, 0, c_amount, v_ccy, 0, c_amount, 1,
            jsonb_build_object('COST_CENTRE', 'ZZ-LEEDS'));
    update erp.journal set status = 'posted', posted_at = now() where id = v_journal;

    -- ── A second organisation that posted to a centre of the same code ─────
    v_step := 'a second organisation';
    perform set_config('request.jwt.claims', '', true);
    select * into r2 from erp.provision_tenant(
      'zzst2-' || v_tag, 'Statements Elsewhere', 'admin@zzst2-' || v_tag || '.test', 'Elsewhere Admin');
    update erp.environment set is_live = false where tenant_id = r2.tenant_id and is_self;
    insert into auth.users (id, email) values (a2, 'admin@zzst2-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(r2.admin_token);
    perform erp.ensure_demo_configuration(r2.tenant_id, r2.admin_user_id);
    perform erp.ensure_cost_centre_dimension();
    perform erp.upsert_dimension_value('COST_CENTRE', 'ZZ-LEEDS', 'Leeds, elsewhere');
    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date,
                             description, status, manual_reason)
    select r2.tenant_id, l.entity_id, l.id, 'manual', current_date,
           'statements read once suite, elsewhere', 'draft', 'the suite is proving the statements'
      from erp.ledger l where l.tenant_id = r2.tenant_id and l.is_primary order by l.code limit 1
    returning id into v_journal;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor,
                                  credit_minor, currency, base_debit_minor, base_credit_minor,
                                  exchange_rate, dimensions)
    select r2.tenant_id, v_journal, x.n, a.id,
           case when x.n = 1 then c_other else 0 end, case when x.n = 2 then c_other else 0 end,
           l.currency,
           case when x.n = 1 then c_other else 0 end, case when x.n = 2 then c_other else 0 end,
           1, jsonb_build_object('COST_CENTRE', 'ZZ-LEEDS')
      from erp.journal j
      join erp.ledger l on l.id = j.ledger_id
      cross join (values (1, 'expense'), (2, 'asset')) as x(n, kind)
      cross join lateral (select a.id from erp.account a
                           where a.tenant_id = r2.tenant_id and a.entity_id = j.entity_id
                             and a.is_postable and a.status = 'active'
                             and a.account_type::text = x.kind
                           order by a.code limit 1) a
     where j.id = v_journal;
    update erp.journal set status = 'posted', posted_at = now() where id = v_journal;
    select coalesce(sum(s.debit_minor), 0) into v_theirs
      from erp.statement_lines(null, null, null, 'ZZ-LEEDS') s;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    -- ── 1. The lines, for every range, ledger and cost centre ──────────────
    v_step := 'the lines read every way';
    for v_from, v_to in
      select * from (values (null::date, current_date), (null, v_day0 + 4), (v_day0, v_day0 + 9),
                            (v_day0 + 5, current_date), (current_date, current_date),
                            (null, v_day0 - 1), (null, null)) as d(f, t)
    loop
      foreach v_led in array array['GL', ' gl ', null] loop
        foreach v_cc in array array[null, 'ZZ-HEAD', ' zz-leeds', 'ZZ-ELSEWHERE', 'ZZ-NOWHERE'] loop
          v_combos := v_combos + 1;
          select coalesce(jsonb_agg(to_jsonb(s) order by s.account_code, s.currency), '[]'::jsonb)
            into v_new from erp.statement_lines(v_from, v_to, v_led, v_cc) s;
          select coalesce(jsonb_agg(to_jsonb(s) order by s.account_code, s.currency), '[]'::jsonb)
            into v_ref from erp_test.statement_lines_reference(v_from, v_to, v_led, v_cc) s;
          v_rows := v_rows + jsonb_array_length(v_ref);
          if v_new is distinct from v_ref then
            v_differ := v_differ || format('%s..%s %s %s; ', v_from, v_to, v_led, v_cc);
          end if;
        end loop;
      end loop;
    end loop;
    select coalesce(sum(s.debit_minor), 0) into v_mine
      from erp.statement_lines(null, null, null, 'ZZ-HEAD') s;
    v_cases := v_cases + 1;
    case_name := 'the statement lines are what they were, for every range, ledger and cost centre';
    passed := v_differ = '' and v_combos = 105 and v_rows > 100 and v_mine = c_amount;
    detail := format('%s reading(s), %s line(s) in all, %s under the heading; differing: %s',
                     v_combos, v_rows, v_mine, coalesce(nullif(v_differ, ''), 'none'));
    return next;

    -- ── 2. The balance sheet, by the suite's owner and by its reader ───────
    v_step := 'the balance sheet read every way';
    v_differ := '';
    for v_to in select unnest(array[current_date, v_day0 + 4, v_day0 + 9, v_day0 - 1, null]) loop
      foreach v_led in array array['GL', null] loop
        foreach v_cc in array array[null, 'ZZ-HEAD', 'ZZ-ELSEWHERE'] loop
          v_sheets := v_sheets + 1;
          v_new := public.erp_balance_sheet(v_to, v_led, v_cc);
          v_ref := erp_test.balance_sheet_reference(v_to, v_led, v_cc);
          if v_new is distinct from v_ref then
            v_differ := v_differ || format('%s %s %s; ', v_to, v_led, v_cc);
          end if;
        end loop;
      end loop;
    end loop;
    v_signed_ref := erp_test.balance_sheet_reference(null, 'GL', null);
    v_heading := erp_test.balance_sheet_reference(null, 'GL', 'ZZ-HEAD');
    -- Read as the screen reads it: signed in, under the row policies.
    v_step := 'the balance sheet read by a signed-in reader';
    set local role authenticated;
    v_signed := public.erp_balance_sheet(null, 'GL', null);
    execute format('set local role %I', v_owner);
    v_cases := v_cases + 1;
    case_name := 'the balance sheet is what it was, as at every date, ledger and cost centre, and as a signed-in reader reads it';
    passed := v_differ = '' and v_sheets = 30
          and v_signed = v_signed_ref
          and (v_signed ->> 'balances')::boolean
          and jsonb_array_length(v_signed -> 'lines') > 0
          and (v_signed ->> 'result_minor')::bigint <> 0
          and (v_heading ->> 'result_minor')::bigint = -c_amount
          and (v_heading ->> 'assets_minor')::bigint = -c_amount;
    detail := format('%s balance sheet(s); signed in: assets %s, result %s, balances %s; under the heading: result %s; differing: %s',
                     v_sheets, v_signed ->> 'assets_minor', v_signed ->> 'result_minor',
                     v_signed ->> 'balances', v_heading ->> 'result_minor',
                     coalesce(nullif(v_differ, ''), 'none'));
    return next;

    -- ── 3. Another organisation's postings ──────────────────────────────────
    v_step := 'another organisation''s postings';
    v_new := public.erp_balance_sheet(null, null, 'ZZ-LEEDS');
    v_cases := v_cases + 1;
    case_name := 'another organisation''s postings to a centre of the same code are in neither read';
    passed := v_theirs = c_other
          and v_mine = c_amount
          and (v_new ->> 'assets_minor')::bigint = -c_amount
          and (v_new ->> 'result_minor')::bigint = -c_amount;
    detail := format('here %s, there %s; the balance sheet under ZZ-LEEDS: assets %s, result %s',
                     v_mine, v_theirs, v_new ->> 'assets_minor', v_new ->> 'result_minor');
    return next;

    -- ── 4. The bodies ───────────────────────────────────────────────────────
    v_step := 'reading the bodies';
    select p.prosrc into v_src_bs from pg_catalog.pg_proc p
     where p.oid = 'public.erp_balance_sheet(date,text,text)'::regprocedure;
    select p.prosrc into v_src_sl from pg_catalog.pg_proc p
     where p.oid = 'erp.statement_lines(date,date,text,text)'::regprocedure;
    v_cases := v_cases + 1;
    case_name := 'the balance sheet reads the lines once, and the lines ask for the organisation once and name it on every table';
    passed := (length(v_src_bs) - length(replace(v_src_bs, 'erp.statement_lines(', ''))) / length('erp.statement_lines(') = 1
          and (length(v_src_bs) - length(replace(v_src_bs, 'erp.authorise(', ''))) / length('erp.authorise(') = 1
          and (length(v_src_sl) - length(replace(v_src_sl, 'erp.current_tenant_id(', ''))) / length('erp.current_tenant_id(') = 1
          and strpos(v_src_sl, 'l.tenant_id = v_tenant') > 0
          and strpos(v_src_sl, 'j.tenant_id = v_tenant') > 0
          and strpos(v_src_sl, 'led.tenant_id = v_tenant') > 0
          and strpos(v_src_sl, 'a.tenant_id = v_tenant') > 0
          and strpos(v_src_sl, 'child.tenant_id = v_tenant') > 0
          and strpos(v_src_sl, 'dv.tenant_id = v_tenant') > 0;
    detail := format('%s and %s characters', length(v_src_bs), length(v_src_sl));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  execute format('set local role %I', v_owner);
  perform set_config('request.jwt.claims', '', true);

  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_STATEMENTS_ONCE_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the fixture stopped; a case that cannot run is a case that fails.';
  end if;
  if exists (select 1 from erp.tenant t where t.code in ('demo-zzst' || v_tag, 'zzst2-' || v_tag))
     or exists (select 1 from auth.users u where u.id in (a1, a2)) then
    raise exception 'CLOVEERP_STATEMENTS_ONCE_SUITE_LEAKED: the fixture was not undone'
      using hint = 'The suite must raise CLOVEERP_SUITE_UNDO inside its block so everything it made rolls back.';
  end if;
end;
$$;

revoke all on function erp_test.statements_read_once_suite() from public, anon;

comment on function erp_test.statements_read_once_suite() is
  'A balance sheet reads its lines once (20261006201000, J-137): on a demonstration with ten days of trading, '
  'cost centres under a heading and a second organisation, the statement lines and the balance sheet are '
  'the references'' for every range, ledger and cost centre, signed in too; the other organisation''s postings '
  'are in neither; and the bodies read the lines once and ask for the organisation once.';

create or replace function erp_test.assert_statements_read_once_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)), count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.statements_read_once_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_STATEMENTS_ONCE_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'The statements would say otherwise than before, or read the ledger twice again. Read the case that failed.';
  end if;
  if v_total <> 4 then
    raise exception 'CLOVEERP_STATEMENTS_ONCE_SUITE_SHRANK: % case(s), expected 4', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('statements read once: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_statements_read_once_suite() from public, anon;

comment on function erp_test.assert_statements_read_once_suite() is
  'The statements say what they said before, and a balance sheet reads its lines once (20261006201000).';

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
select erp.assert_personal_data_register_sound();
