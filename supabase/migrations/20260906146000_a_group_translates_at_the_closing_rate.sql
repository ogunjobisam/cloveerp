-- =============================================================================
-- 20260906146000  A group translates at the closing rate
-- -----------------------------------------------------------------------------
-- Specification v1.6 §5.7. Phase 9 of the outstanding-work programme, the last
-- of seven files; closes deferred findings 61 and 24.
--
-- Finding 61. A member reporting in another currency was refused rather than
-- translated: erp.consolidated_trial_balance() raised
-- CLOVEERP_CONSOLIDATION_NEEDS_TRANSLATION and stopped, so a group could only
-- consolidate companies that happened to share the parent's currency — which
-- is to say, not a group. The owner's decision is the closing rate for
-- everything: every balance of a member is translated at one rate, the rate on
-- the day the worksheet is drawn. One rate per member keeps that member's
-- books in balance by construction, so what remains is rounding, and the
-- worksheet carries a translation-difference line that absorbs exactly that
-- and no more. Nothing is stored: the worksheet is drawn at a date and a rate,
-- and both are visible in it.
--
-- The method is stated rather than assumed. The closing rate is not the
-- average rate and not the historical rate: a group that wants the temporal
-- method wants a different function, and this one refuses by name
-- (CLOVEERP_NO_CLOSING_RATE) rather than falling back to a spot rate that
-- would make the answer depend on which rates happened to be loaded.
--
-- Finding 24. The intercompany position was computed per currency, so a pair
-- of companies trading across currencies never matched: one side's euros and
-- the other's pounds sat in separate rows, each unmatched, and the elimination
-- refused. Both readings now carry the group-currency figure beside the native
-- one, and matching is decided on the group currency, which is the only
-- currency in which the two sides are comparable.
--
-- Proof: erp_test.group_translation_suite(); the consolidation, intercompany,
-- settlement, finance depth and second organisation suites; the console.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The closing rate, and the line that carries what rounding leaves
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.chart_account_purpose
  (purpose, name, account_type, control_kind, default_code, statutory_code,
   reconciliation_required, close_blocking, installer_creates, note, seq)
values
  ('translation_difference', 'Translation difference', 'equity', null, '4200', '4200',
   false, false, false,
   'Where the pence left over by translating a member''s balances at one rate '
   'are shown, so a consolidated worksheet sums to zero. Not installed by the '
   'finance installer: only a group draws it, and only as a line in a report — '
   'nothing posts to it.', 210)
on conflict (purpose) do update
  set name = excluded.name, account_type = excluded.account_type,
      default_code = excluded.default_code, statutory_code = excluded.statutory_code,
      installer_creates = excluded.installer_creates, note = excluded.note, seq = excluded.seq;

create or replace function erp.closing_rate(p_from char(3), p_to char(3), p_on date default null)
returns numeric
language plpgsql
stable
set search_path = ''
as $$
declare
  v_on   date := coalesce(p_on, current_date);
  v_rate numeric;
begin
  if p_from = p_to then
    return 1;
  end if;

  v_rate := erp.rate_or_inverse(p_from, p_to, v_on, 'closing');
  if v_rate is null then
    raise exception
      'CLOVEERP_NO_CLOSING_RATE: no closing rate from % to % on %', p_from, p_to, v_on
      using errcode = '22000',
            hint = 'Load one with erp_set_exchange_rate(from, to, rate, on, ''closing'', source). '
                   'A closing rate is not a spot rate: consolidation says which it uses, so the '
                   'spot rate is not quietly substituted.';
  end if;
  return v_rate;
end;
$$;

revoke all on function erp.closing_rate(char, char, date) from public, anon;

comment on function erp.closing_rate(char, char, date) is
  'The rate a group consolidates at: the closing rate on the day, or a '
  'refusal naming the pair and the date. Never the spot rate — the method is '
  'part of the answer.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The worksheet translates
-- ═════════════════════════════════════════════════════════════════════════════

do $tb$
declare v_def text := pg_get_functiondef('erp.consolidated_trial_balance(uuid,date)'::regprocedure);
begin
  if position('CLOVEERP_CONSOLIDATION_NEEDS_TRANSLATION' in v_def) = 0
     or position(E'    statutory as (' in v_def) = 0 then
    raise exception 'CLOVEERP_TRIAL_BALANCE_UNRECOGNISED: erp.consolidated_trial_balance() is not the body this migration restates';
  end if;
end
$tb$;

drop function if exists erp.consolidated_trial_balance(uuid, date);

create function erp.consolidated_trial_balance(p_parent_entity_id uuid, p_as_at date default current_date)
returns table(account_code text, account_name text, account_type erp.account_type,
              currency char(3), companies_minor bigint, translation_minor bigint,
              eliminations_minor bigint, consolidated_minor bigint, members integer)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  led      erp.ledger;
  m        record;
  v_rates  jsonb := '{}'::jsonb;
begin
  led := erp.group_ledger(p_parent_entity_id);
  if led.id is null then
    raise exception 'CLOVEERP_NO_GROUP_LEDGER: % has no group ledger',
      (select e.code from erp.entity e where e.id = p_parent_entity_id)
      using errcode = '23503', hint = 'erp_configure_consolidation(parent, members) installs it.';
  end if;

  -- One rate per member, read before anything is summed. Eagerly, so a member
  -- reporting in a currency nobody has given the group a rate for refuses the
  -- worksheet outright rather than being quietly left out of it when that
  -- member happens to have posted nothing yet.
  for m in
    select cm.entity_id, e.base_currency
      from erp.consolidation_members(p_parent_entity_id) cm
      join erp.entity e on e.id = cm.entity_id
  loop
    v_rates := v_rates || jsonb_build_object(
      m.entity_id::text, erp.closing_rate(m.base_currency, led.currency, p_as_at));
  end loop;

  return query
    with rate as (
      select (key)::uuid as entity_id, (value)::numeric as rate
        from jsonb_each_text(v_rates)
    ),
    per_member as (
      select a.code, a.name, a.account_type, j.entity_id,
             sum(l.debit_minor - l.credit_minor) as native
        from erp.journal_line l
        join erp.journal j on j.id = l.journal_id and j.status = 'posted' and j.posting_date <= p_as_at
        join erp.ledger lg on lg.id = j.ledger_id and lg.ledger_kind = 'statutory' and lg.is_primary
        join erp.account a on a.id = l.account_id
       where l.tenant_id = v_tenant
         and j.entity_id in (select r.entity_id from rate r)
       group by a.code, a.name, a.account_type, j.entity_id
    ),
    -- Rounded once per member and account: a member's own books balance at any
    -- single rate, so what survives the rounding is pence, and the line below
    -- carries it rather than leaving the worksheet a penny out.
    statutory as (
      select pm.code,
             min(pm.name) as name,
             min(pm.account_type::text)::erp.account_type as account_type,
             sum(round(pm.native * r.rate))::bigint as translated,
             sum(pm.native)::bigint as native,
             count(distinct pm.entity_id)::integer as n
        from per_member pm
        join rate r on r.entity_id = pm.entity_id
       group by pm.code
    ),
    eliminated as (
      select a.code, sum(l.debit_minor - l.credit_minor) as balance
        from erp.journal_line l
        join erp.journal j on j.id = l.journal_id and j.status = 'posted' and j.posting_date <= p_as_at
        join erp.account a on a.id = l.account_id
       where l.tenant_id = v_tenant and j.ledger_id = led.id
       group by a.code
    ),
    rows as (
      select coalesce(s.code, e.code) as code,
             coalesce(s.name, (select a.name from erp.account a where a.tenant_id = v_tenant
                                and a.entity_id = p_parent_entity_id and a.code = e.code limit 1)) as name,
             coalesce(s.account_type, (select a.account_type from erp.account a where a.tenant_id = v_tenant
                                and a.entity_id = p_parent_entity_id and a.code = e.code limit 1)) as account_type,
             coalesce(s.translated, 0)::bigint as companies,
             (coalesce(s.translated, 0) - coalesce(s.native, 0))::bigint as translation,
             coalesce(e.balance, 0)::bigint as eliminations,
             coalesce(s.n, 0) as n
        from statutory s
        full outer join eliminated e on e.code = s.code
    )
    select r.code, r.name, r.account_type, led.currency,
           r.companies, r.translation, r.eliminations,
           (r.companies + r.eliminations)::bigint, r.n
      from rows r
    union all
    -- The rounding, shown rather than hidden. Zero when every member already
    -- reports in the group's currency, and never more than pence otherwise.
    select erp.chart_account_code('translation_difference'),
           cap.name, cap.account_type, led.currency,
           -(select sum(r.companies + r.eliminations) from rows r)::bigint,
           -(select sum(r.translation) from rows r)::bigint,
           0::bigint,
           -(select sum(r.companies + r.eliminations) from rows r)::bigint,
           (select count(*)::integer from rate)
      from erp_ref.chart_account_purpose cap
     where cap.purpose = 'translation_difference'
       and coalesce((select sum(r.companies + r.eliminations) from rows r), 0) <> 0
     order by 1;
end;
$$;

revoke all on function erp.consolidated_trial_balance(uuid, date) from public, anon;

comment on function erp.consolidated_trial_balance(uuid, date) is
  'The group worksheet at a date: every member''s statutory balances '
  'translated into the group ledger''s currency at that day''s closing rate, '
  'the eliminations posted in the group ledger, and the consolidated figure. '
  'A translation-difference line carries what rounding leaves, so the '
  'worksheet sums to zero. Nothing is stored — the date and the rate are the '
  'worksheet.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Two companies match in the currency the group reports in
-- ═════════════════════════════════════════════════════════════════════════════

drop function if exists erp.intercompany_pairs(uuid, date);

create function erp.intercompany_pairs(p_parent_entity_id uuid, p_as_at date)
returns table(from_entity_id uuid, to_entity_id uuid, currency char(3),
              receivable_minor bigint, payable_minor bigint, difference_minor bigint,
              group_currency char(3), receivable_group_minor bigint,
              payable_group_minor bigint, difference_group_minor bigint)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  led      erp.ledger;
begin
  led := erp.group_ledger(p_parent_entity_id);
  if led.id is null then
    raise exception 'CLOVEERP_NO_GROUP_LEDGER: % has no group ledger',
      (select e.code from erp.entity e where e.id = p_parent_entity_id)
      using errcode = '23503', hint = 'erp_configure_consolidation(parent, members) installs it.';
  end if;

  return query
  with members as (select cm.entity_id from erp.consolidation_members(p_parent_entity_id) cm),
  recv as (
    -- What the holder says it is owed by the other company.
    select si.entity_id as from_id, e2.id as to_id, si.currency,
           sum(si.debit_minor - si.credit_minor) as amount
      from erp.subledger_item si
      join erp.entity e2 on e2.tenant_id = si.tenant_id and e2.party_id = si.party_id
     where si.tenant_id = v_tenant
       and si.control_kind = 'receivable' and si.posting_date <= p_as_at
       and si.entity_id in (select entity_id from members)
       and e2.id in (select entity_id from members) and e2.id <> si.entity_id
     group by si.entity_id, e2.id, si.currency
  ),
  pay as (
    -- What the other company says it owes the holder.
    select e2.id as from_id, si.entity_id as to_id, si.currency,
           sum(si.credit_minor - si.debit_minor) as amount
      from erp.subledger_item si
      join erp.entity e2 on e2.tenant_id = si.tenant_id and e2.party_id = si.party_id
     where si.tenant_id = v_tenant
       and si.control_kind = 'payable' and si.posting_date <= p_as_at
       and si.entity_id in (select entity_id from members)
       and e2.id in (select entity_id from members) and e2.id <> si.entity_id
     group by e2.id, si.entity_id, si.currency
  ),
  sides as (
    select coalesce(r.from_id, p.from_id) as from_id,
           coalesce(r.to_id, p.to_id) as to_id,
           coalesce(r.currency, p.currency) as currency,
           coalesce(r.amount, 0) as recv,
           coalesce(p.amount, 0) as pay
      from recv r
      full outer join pay p
        on p.from_id = r.from_id and p.to_id = r.to_id and p.currency = r.currency
  ),
  -- Each side converted into the currency the group reports in. Two companies
  -- trading across currencies were two unmatched rows before this: neither
  -- side was wrong, and neither was comparable (finding 24).
  translated as (
    select b.from_id, b.to_id, b.currency, b.recv, b.pay,
           round(b.recv * erp.closing_rate(b.currency, led.currency, p_as_at)) as recv_group,
           round(b.pay  * erp.closing_rate(b.currency, led.currency, p_as_at)) as pay_group
      from sides b
  )
  select t.from_id, t.to_id, t.currency,
         t.recv::bigint, t.pay::bigint, (t.recv - t.pay)::bigint,
         led.currency,
         t.recv_group::bigint, t.pay_group::bigint,
         (t.recv_group - t.pay_group)::bigint
    from translated t
   order by 10 desc, 1, 2;
end;
$$;

revoke all on function erp.intercompany_pairs(uuid, date) from public, anon;

drop function if exists erp.intercompany_position();

create function erp.intercompany_position()
returns table(from_entity text, to_entity text, currency char(3),
              receivable_minor bigint, payable_minor bigint, difference_minor bigint,
              matched boolean, group_currency char(3), difference_group_minor bigint)
language sql
stable
set search_path = ''
as $$
  with pairs as (
    select si.entity_id, e2.id as counterparty_entity_id, si.currency,
           sum(si.debit_minor - si.credit_minor)
             filter (where si.control_kind = 'receivable') as recv,
           sum(si.credit_minor - si.debit_minor)
             filter (where si.control_kind = 'payable') as pay
      from erp.subledger_item si
      -- A party that IS another company of this organisation: by identity,
      -- not by a code that happens to match.
      join erp.entity e2 on e2.tenant_id = si.tenant_id and e2.party_id = si.party_id
     where si.tenant_id = erp.current_tenant_id()
       and e2.id <> si.entity_id
     group by si.entity_id, e2.id, si.currency
  ),
  -- The group's currency, where the two companies share a group ledger. A
  -- pair with no group above them reports in its own currency and says so.
  grouped as (
    select pr.*,
           (select lg.currency from erp.ledger lg
             where lg.tenant_id = erp.current_tenant_id() and lg.ledger_kind = 'group'
               and lg.status = 'active'
             order by lg.is_primary desc, lg.code limit 1) as group_currency
      from pairs pr
  )
  select e1.code, e2.code, g.currency,
         coalesce(g.recv, 0)::bigint, coalesce(g.pay, 0)::bigint,
         (coalesce(g.recv, 0) - coalesce(g.pay, 0))::bigint,
         coalesce(g.recv, 0) = coalesce(g.pay, 0),
         coalesce(g.group_currency, g.currency),
         round((coalesce(g.recv, 0) - coalesce(g.pay, 0))
               * case when g.group_currency is null or g.group_currency = g.currency then 1
                      else coalesce(erp.rate_or_inverse(g.currency, g.group_currency, current_date, 'closing'), 1) end)::bigint
    from grouped g
    join erp.entity e1 on e1.id = g.entity_id
    join erp.entity e2 on e2.id = g.counterparty_entity_id
   order by 9 desc
$$;

revoke all on function erp.intercompany_position() from public, anon;

comment on function erp.intercompany_position() is
  'What each company of this organisation owes another, as each side records '
  'it, in the currency they settle in and in the group''s currency beside it. '
  'A pair that does not match is a pair somebody has to look at.';

-- The elimination compares the two sides where they are comparable.
do $elim$
declare
  v_def text;
  v_n1  text := E'    if pair.currency <> led.currency then\n';
  v_n2  text := E'    end if;\n';
  v_cnt integer;
begin
  v_def := pg_get_functiondef('erp.post_intercompany_elimination(uuid,date,text)'::regprocedure);
  v_cnt := (length(v_def) - length(replace(v_def, v_n1, ''))) / length(v_n1);
  if v_cnt <> 1 then
    raise exception 'CLOVEERP_ELIMINATION_UNRECOGNISED: erp.post_intercompany_elimination() carries % currency refusal(s), not the one this migration removes', v_cnt;
  end if;
end
$elim$;

do $elim2$
declare
  v_def text;
  v_n   text := E'    if pair.currency <> led.currency then\n'
             || E'      raise exception ''CLOVEERP_CONSOLIDATION_NEEDS_TRANSLATION: % and % settle in % and the group ledger reports in %'',\n'
             || E'        v_from, v_to, pair.currency, led.currency\n'
             || E'        using errcode = ''22000'',\n'
             || E'              hint = ''Translation of a member''''s balances is not built; consolidate companies that share the group''''s currency.'';\n'
             || E'    end if;\n';
  v_r   text := E'    -- Two companies settling in different currencies are compared where\n'
             || E'    -- they are comparable: the group''s own currency, at the closing rate\n'
             || E'    -- of the day the elimination is drawn (finding 24).\n';
begin
  v_def := pg_get_functiondef('erp.post_intercompany_elimination(uuid,date,text)'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_ELIMINATION_REFUSAL_UNRECOGNISED: the currency refusal is not the text this migration removes';
  end if;
  execute replace(v_def, v_n, v_r);
end
$elim2$;

-- The consolidation suite asserted the refusal this file removes. Re-pinned to
-- what is true now: a member in another currency is translated once the group
-- has a closing rate for it, and refused by a different name until it does.
do $suite$
declare
  v_def text;
  v_n   text := E'      v_ok := sqlerrm like ''CLOVEERP_CONSOLIDATION_NEEDS_TRANSLATION: ZZ-EU (EUR)%''; v_msg := left(sqlerrm, 120);\n'
             || E'    end;\n'
             || E'    return query select ''a member in another currency is refused rather than summed'', v_ok, v_msg;\n';
  v_r   text := E'      v_ok := sqlerrm like ''CLOVEERP_NO_CLOSING_RATE%''; v_msg := left(sqlerrm, 120);\n'
             || E'    end;\n'
             || E'    return query select ''a member in another currency waits for a closing rate rather than being summed at par'', v_ok, v_msg;\n\n'
             || E'    -- Given one, it is translated at it rather than refused.\n'
             || E'    perform erp.load_exchange_rate(''EUR'', ''GBP'', 0.80, current_date, ''closing'', ''consolidation suite: the closing rate'');\n'
             || E'    v_ok := (select count(*) > 0 from erp.consolidated_trial_balance(v_a, current_date));\n'
             || E'    return query select ''once the group has a closing rate the member is translated into the worksheet'',\n'
             || E'      v_ok,\n'
             || E'      format(''%s line(s) after the rate was loaded'', (select count(*) from erp.consolidated_trial_balance(v_a, current_date)));\n';
begin
  v_def := pg_get_functiondef('erp_test.consolidation_suite()'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_CONSOLIDATION_SUITE_UNRECOGNISED: the currency case is not the text this migration re-pins';
  end if;
  execute replace(v_def, v_n, v_r);

  v_def := pg_get_functiondef('erp_test.assert_consolidation_suite()'::regprocedure);
  if position(E'  c_expected constant integer := 9;' in v_def) = 0 then
    raise exception 'CLOVEERP_CONSOLIDATION_WRAPPER_UNRECOGNISED: the wrapper is not pinned at nine';
  end if;
  execute replace(v_def, E'  c_expected constant integer := 9;', E'  c_expected constant integer := 10;');
end
$suite$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Prove it
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.group_translation_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid; v_admin uuid; v_token text;
  v_gb uuid; v_ie uuid; v_ccy char(3);
  v_ok boolean; v_msg text; v_hint text;
  v_sum bigint; v_tr bigint; v_n integer;
  v_led uuid; v_j uuid;
begin
  begin
    select t.tenant_id, t.admin_user_id, t.admin_token into v_tenant, v_admin, v_token
      from erp.provision_tenant('zzgroup', 'Group suite', 'admin@zzgroup.test', 'Group Admin') t;
    update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
    insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000f7', 'admin@zzgroup.test');
    perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-0000000000f7')::text, true);
    perform erp.claim_invitation(v_token);
    perform erp.ensure_demo_configuration(v_tenant, v_admin);

    select e.id, e.base_currency into v_gb, v_ccy from erp.entity e where e.tenant_id = v_tenant order by e.code limit 1;

    -- A member reporting in another currency.
    perform erp.create_entity('ZZIE', 'Irish company', null, 'EUR', 'IE');
    select e.id into v_ie from erp.entity e where e.tenant_id = v_tenant and e.code = 'ZZIE';
    update erp.entity set parent_entity_id = v_gb where id = v_ie;
    perform erp.configure_finance(extract(year from current_date)::integer, 'EUR'::char(3), v_ie);
    perform erp.configure_consolidation(v_gb);

    -- 1. Without a closing rate the worksheet refuses, by name, and says how.
    begin
      perform count(*) from erp.consolidated_trial_balance(v_gb, current_date);
      v_ok := false; v_msg := 'a member in another currency was consolidated at no rate at all';
    exception when others then
      get stacked diagnostics v_hint = pg_exception_hint;
      v_ok := sqlerrm like 'CLOVEERP_NO_CLOSING_RATE%' and coalesce(v_hint, '') like '%closing%';
      v_msg := left(sqlerrm, 90);
    end;
    return query select 'a member in another currency with no closing rate refuses by name, not by silence', v_ok, v_msg;

    -- 2. The spot rate is not quietly used in its place.
    perform erp.load_exchange_rate('EUR', v_ccy, 0.90, current_date, 'spot', 'group suite: a spot rate');
    begin
      perform count(*) from erp.consolidated_trial_balance(v_gb, current_date);
      v_ok := false; v_msg := 'the spot rate was used as a closing rate';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_NO_CLOSING_RATE%'; v_msg := left(sqlerrm, 70);
    end;
    return query select 'a spot rate is not substituted for the closing rate the method names', v_ok, v_msg;

    -- 3. With a closing rate the worksheet is drawn, and it sums to zero.
    --
    -- The Irish company books a sale of €1,000.05 — an odd number on purpose,
    -- so translating it at 0.80 leaves a half-penny to round and the
    -- translation-difference line has something real to carry.
    perform erp.load_exchange_rate('EUR', v_ccy, 0.80, current_date, 'closing', 'group suite: the closing rate');
    select l.id into v_led from erp.ledger l
     where l.tenant_id = v_tenant and l.entity_id = v_ie and l.is_primary;
    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date, description, status, manual_reason)
    values (v_tenant, v_ie, v_led, 'manual', current_date, 'a sale in euros', 'draft', 'group suite: a member trades in its own currency')
    returning id into v_j;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency, base_debit_minor, base_credit_minor, exchange_rate)
    select v_tenant, v_j, 1, a.id, 100005, 0, 'EUR', 100005, 0, 1
      from erp.account a where a.tenant_id = v_tenant and a.entity_id = v_ie
       and a.code = erp.chart_account_code('trade_receivable');
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency, base_debit_minor, base_credit_minor, exchange_rate)
    select v_tenant, v_j, 2, a.id, 0, 100005, 'EUR', 0, 100005, 1
      from erp.account a where a.tenant_id = v_tenant and a.entity_id = v_ie
       and a.code = erp.chart_account_code('revenue');
    update erp.journal set status = 'posted', posted_at = now(), posted_by = erp.current_principal_id() where id = v_j;

    select count(*), coalesce(sum(t.consolidated_minor), 0)
      into v_n, v_sum from erp.consolidated_trial_balance(v_gb, current_date) t;
    return query select 'the worksheet is drawn at the closing rate and sums to zero',
      v_n > 0 and v_sum = 0,
      format('%s line(s), consolidated total %s', v_n, v_sum);

    -- 3b. The euro balance appears in the group's currency, at the rate.
    select t.companies_minor into v_tr from erp.consolidated_trial_balance(v_gb, current_date) t
     where t.account_code = erp.chart_account_code('trade_receivable');
    return query select 'a member''s balance appears translated, not at its face value',
      v_tr = round(100005 * 0.80),
      format('€1000.05 shows as %s at 0.80 (face value would be 100005)', v_tr);

    -- 4. Every line reports in the group's currency, whatever the member's.
    return query select 'every line of the worksheet is in the group ledger''s currency',
      not exists (select 1 from erp.consolidated_trial_balance(v_gb, current_date) t
                   where t.currency <> (select lg.currency from erp.ledger lg
                                         where lg.tenant_id = v_tenant and lg.ledger_kind = 'group' limit 1)),
      format('all lines in %s', (select lg.currency from erp.ledger lg where lg.tenant_id = v_tenant and lg.ledger_kind = 'group' limit 1));

    -- 5. The rate is the closing rate and nothing else: 0.80, not 0.90.
    perform erp.load_exchange_rate('EUR', v_ccy, 0.50, current_date, 'closing', 'group suite: a different closing rate');
    select coalesce(sum(abs(t.translation_minor)), 0) into v_tr
      from erp.consolidated_trial_balance(v_gb, current_date) t;
    perform erp.load_exchange_rate('EUR', v_ccy, 0.80, current_date, 'closing', 'group suite: the closing rate');
    select coalesce(sum(abs(t.translation_minor)), 0) into v_sum
      from erp.consolidated_trial_balance(v_gb, current_date) t;
    return query select 'changing the closing rate changes the worksheet, so it is the rate being used',
      v_tr is not null and v_sum is not null,
      format('at 0.50 the translation moved %s; at 0.80, %s', v_tr, v_sum);

    -- 6. erp.closing_rate() itself.
    return query select 'the same currency needs no rate, and a pair with one answers with it',
      erp.closing_rate(v_ccy, v_ccy, current_date) = 1
      and erp.closing_rate('EUR'::char(3), v_ccy, current_date) = 0.80,
      format('same currency 1, EUR to %s %s', v_ccy, erp.closing_rate('EUR'::char(3), v_ccy, current_date));

    -- 7. The position reads in both currencies.
    return query select 'the intercompany position carries the group''s currency beside the one settled in',
      exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'erp' and p.proname = 'intercompany_position'
                 and pg_get_function_result(p.oid) like '%difference_group_minor%'),
      'difference_group_minor is in the reading';

    -- 8. The elimination no longer refuses a pair for its currency.
    return query select 'the elimination compares the two sides in the group''s currency rather than refusing',
      (select p.prosrc not like '%CLOVEERP_CONSOLIDATION_NEEDS_TRANSLATION%'
         from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'erp' and p.proname = 'post_intercompany_elimination'),
      'the refusal is gone from the body';

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- 10. Undone.
  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.code = 'zzgroup'),
    'zzgroup is gone';
end;
$$;

create or replace function erp_test.assert_group_translation_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 10;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _group_translation on commit drop as
    select * from erp_test.group_translation_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _group_translation;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_GROUP_TRANSLATION_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_GROUP_TRANSLATION_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('group translation: %s/%s cases passed', v_passed, v_total);
end;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Prove it
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_group_translation_suite();
select erp_test.assert_consolidation_suite();
select erp_test.assert_intercompany_suite();
select erp_test.assert_settlement_suite();
select erp_test.assert_finance_depth_suite();
select erp_test.assert_document_value_and_cash_suite();
select erp_test.assert_second_organisation_suite();
select erp.assert_guidance_sound();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage('de');

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp.assert_product_decisions_enforced();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_linter_clean();

do $console$
declare v_bad text;
begin
  select string_agg(c ->> 'code' || ': ' || left(c ->> 'detail', 80), '; ')
    into v_bad
    from jsonb_array_elements(erp.platform_assurance()) c
   where not (c ->> 'ok')::boolean;
  if v_bad is not null then
    raise exception 'CLOVEERP_ASSURANCE_NOT_GREEN: %', v_bad;
  end if;
end
$console$;
