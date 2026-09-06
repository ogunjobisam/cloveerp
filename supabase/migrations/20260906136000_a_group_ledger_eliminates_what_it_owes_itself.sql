-- =============================================================================
-- 20260906136000  A group ledger eliminates what it owes itself
-- -----------------------------------------------------------------------------
-- Specification v1.6 §5.7, intercompany. The register said 5.7.intercompany
-- was partial: matching is built (erp.intercompany_position shows where two
-- companies of one organisation disagree about what they owe each other),
-- "elimination on consolidation is not, and needs a consolidation ledger this
-- product does not yet have". erp.ledger_kind already had the label `group`
-- and erp.entity already had parent_entity_id; nothing used either.
--
-- What changes:
--
--   * erp.configure_consolidation(parent, members) — the group: the members'
--     parent_entity_id is set (a company cannot be its own parent, nor under
--     two), the parent gets a GROUP ledger of kind group in its base currency
--     with the parent's fiscal periods, and a posting rule
--     intercompany_elimination (debit the trade payable code, credit the trade
--     receivable code, in the GROUP ledger) is promoted through the same
--     change set every other installer uses.
--   * erp.post_intercompany_elimination(parent, as_at, reason) — reads the
--     matched pairs between members from the subledger as at the date, refuses
--     an unmatched pair naming both figures and the difference (a difference
--     eliminated is a difference hidden), refuses the same date twice, and
--     posts one journal in the GROUP ledger with a line per pair, traced to a
--     consolidation.eliminated event and the rule version, so the trigger that
--     refuses an untraceable line is satisfied like any other posting.
--   * erp.consolidated_trial_balance(parent, as_at) — the worksheet: per
--     account code, what the members' statutory ledgers hold, what the GROUP
--     ledger eliminates, and the consolidated figure. Never stored (D2). A
--     member in another currency is refused: translation is not built, and a
--     figure summed across currencies is a number, not a balance.
--   * erp.eliminations(parent) — what has been eliminated, when, why, by
--     which journal.
--   * Doors: erp_configure_consolidation, erp_post_intercompany_elimination,
--     erp_consolidated_trial_balance, erp_eliminations.
--
-- The elimination posts to the same account codes the members use for trade
-- receivables and payables (from the purpose register, so it follows the
-- chart the organisation chose). The plan had two new purpose rows for
-- elimination accounts; the worksheet makes them unnecessary — the
-- eliminations column shows the figure against the account it eliminates,
-- which is what an auditor reads. Not added.
--
-- Proof: erp_test.consolidation_suite() (9 cases, wrapper pinned): the group
-- installs; an unmatched pair is refused naming the difference; once matched,
-- the elimination posts with its event; the same date twice refused; the
-- worksheet nets the intercompany receivable and payable to nothing and
-- leaves revenue and cost alone; the eliminations listing; a member in
-- another currency refused; the register flipped and D2 bound; nothing left.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The event
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current) values
  ('consolidation.eliminated', 1, 'posting', 'finance', 'event.consolidation.eliminated',
   'Intercompany balances between the members of a group were eliminated in the group ledger as at a date.',
   '{"type":"object","required":["parent_entity","as_at","pairs","total_minor","currency"],
     "properties":{"parent_entity":{"type":"string"},"as_at":{"type":"string"},
                   "pairs":{"type":"integer"},"total_minor":{"type":"integer"},"currency":{"type":"string"},
                   "reason":{"type":"string"}}}', true)
on conflict (code, version) do update
  set description = excluded.description, payload_schema = excluded.payload_schema, is_current = excluded.is_current;

insert into erp_ref.resource (key, locale, value, module_code) values
  ('event.consolidation.eliminated', 'en', 'Intercompany balances eliminated', 'finance'),
  ('event.consolidation.eliminated', 'de', 'Konzerninterne Salden eliminiert', 'finance')
on conflict (key, locale) do update set value = excluded.value, module_code = excluded.module_code;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The group
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.consolidation_members(p_parent_entity_id uuid)
returns table(entity_id uuid, depth integer)
language sql
stable
set search_path = ''
as $$
  with recursive members as (
    select e.id, 0 as depth from erp.entity e
     where e.tenant_id = erp.current_tenant_id() and e.id = p_parent_entity_id
    union all
    select c.id, m.depth + 1 from members m
      join erp.entity c on c.tenant_id = erp.current_tenant_id()
                       and c.parent_entity_id = m.id and c.status = 'active'
     where m.depth < 10
  )
  select id, depth from members
$$;
revoke all on function erp.consolidation_members(uuid) from public, anon, authenticated;

create or replace function erp.group_ledger(p_parent_entity_id uuid)
returns erp.ledger
language sql
stable
set search_path = ''
as $$
  select l.* from erp.ledger l
   where l.tenant_id = erp.current_tenant_id() and l.entity_id = p_parent_entity_id
     and l.ledger_kind = 'group' and l.status = 'active'
   order by l.code limit 1
$$;
revoke all on function erp.group_ledger(uuid) from public, anon, authenticated;

create or replace function erp.configure_consolidation(p_parent_entity_id uuid, p_member_entity_ids uuid[] default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  parent   erp.entity%rowtype;
  v_member uuid;
  v_ledger uuid;
  v_start  integer;
  v_year   integer;
  v_from   date;
  m        integer;
  v_cs     uuid;
begin
  perform erp.authorise('finance.configure', p_parent_entity_id, null, null, 'ledger', null);

  select * into parent from erp.entity e
   where e.tenant_id = v_tenant and e.id = p_parent_entity_id and e.status = 'active';
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_ENTITY: % is not an active company of this organisation', p_parent_entity_id
      using errcode = '23503', hint = 'erp_entities() lists the companies; the parent must be one of them.';
  end if;

  -- The members. A company is under one parent; the parent is under nobody
  -- in this group.
  if p_member_entity_ids is not null then
    foreach v_member in array p_member_entity_ids loop
      if v_member = p_parent_entity_id then
        raise exception 'CLOVEERP_ENTITY_IS_ITS_OWN_PARENT: % cannot be a member of its own group', parent.code
          using errcode = '22023', hint = 'Name the subsidiaries; the parent is the group''s head.';
      end if;
      if not exists (select 1 from erp.entity e where e.tenant_id = v_tenant and e.id = v_member and e.status = 'active') then
        raise exception 'CLOVEERP_UNKNOWN_ENTITY: % is not an active company of this organisation', v_member
          using errcode = '23503', hint = 'erp_entities() lists the companies.';
      end if;
      if exists (select 1 from erp.entity e where e.tenant_id = v_tenant and e.id = v_member
                    and e.parent_entity_id is not null and e.parent_entity_id <> p_parent_entity_id) then
        raise exception 'CLOVEERP_ENTITY_HAS_ANOTHER_PARENT: % is already under a different parent', v_member
          using errcode = '23505', hint = 'A company consolidates into one group; move it deliberately first.';
      end if;
      if exists (select 1 from erp.consolidation_members(v_member) cm where cm.entity_id = p_parent_entity_id) then
        raise exception 'CLOVEERP_GROUP_WOULD_CYCLE: % is above %, so it cannot be below it', v_member, parent.code
          using errcode = '22023', hint = 'A group is a tree.';
      end if;
      update erp.entity set parent_entity_id = p_parent_entity_id, updated_at = now()
       where tenant_id = v_tenant and id = v_member;
    end loop;
  end if;

  if not exists (select 1 from erp.consolidation_members(p_parent_entity_id) cm where cm.depth > 0) then
    raise exception 'CLOVEERP_GROUP_HAS_NO_MEMBERS: % has no company beneath it to consolidate', parent.code
      using errcode = '23503', hint = 'Pass the member companies, or set their parent first.';
  end if;

  -- The group ledger, in the parent's currency, with the parent's periods.
  insert into erp.ledger (tenant_id, entity_id, code, name, ledger_kind, currency, is_primary, status, journal_prefix)
  values (v_tenant, parent.id, 'GROUP', 'Group consolidation', 'group', parent.base_currency, false, 'active', 'GRP-')
  on conflict (tenant_id, entity_id, code) do update set status = 'active', ledger_kind = 'group'
  returning id into v_ledger;

  v_start := coalesce(parent.fiscal_year_start_month, 1);
  v_year  := case when extract(month from current_date)::integer >= v_start
                  then extract(year from current_date)::integer
                  else extract(year from current_date)::integer - 1 end;
  for m in 1..12 loop
    v_from := (make_date(v_year, v_start, 1) + ((m - 1) || ' months')::interval)::date;
    insert into erp.fiscal_period (tenant_id, ledger_id, code, fiscal_year, period_number, starts_on, ends_on, status)
    values (v_tenant, v_ledger, format('%s-%s', v_year, lpad(m::text, 2, '0')), v_year, m::smallint,
            v_from, (v_from + interval '1 month - 1 day')::date, 'open')
    on conflict (tenant_id, ledger_id, fiscal_year, period_number) do nothing;
  end loop;

  -- The parent must hold the two accounts the elimination posts to.
  if not exists (select 1 from erp.account a where a.tenant_id = v_tenant and a.entity_id = parent.id
                    and a.code = erp.chart_account_code('trade_receivable') and a.status = 'active' and a.is_postable)
     or not exists (select 1 from erp.account a where a.tenant_id = v_tenant and a.entity_id = parent.id
                    and a.code = erp.chart_account_code('trade_payable') and a.status = 'active' and a.is_postable) then
    raise exception 'CLOVEERP_PARENT_HAS_NO_CHART: % has no trade receivable and payable accounts to eliminate against', parent.code
      using errcode = '23503', hint = 'Run the finance installer for the parent company first.';
  end if;

  -- The rule, promoted like every other. Not live means installed at once.
  select cs.id into v_cs from erp.change_set cs
   where cs.tenant_id = v_tenant and cs.code = 'consolidation-' || lower(parent.code);
  if v_cs is not null then
    return v_cs;
  end if;

  v_cs := erp.install_module_config(
    'consolidation-' || lower(parent.code), 'Consolidation for ' || parent.name,
    'The group ledger''s one posting rule: what the members owe each other is '
    'eliminated against the trade receivable and payable codes, so the '
    'consolidated figures show what the group owes the world.',
    jsonb_build_array(
      jsonb_build_object('kind', 'posting_rule', 'key', 'intercompany_elimination', 'payload',
        jsonb_build_object(
          'code', 'intercompany_elimination', 'name', 'Intercompany elimination',
          'entity', parent.code, 'ledger', 'GROUP',
          'event_type', 'consolidation.eliminated',
          'posting_lines', jsonb_build_array(
            jsonb_build_object('account', erp.chart_account_code('trade_payable'), 'side', 'debit', 'rate', 1,
                               'description', 'Intercompany payable eliminated'),
            jsonb_build_object('account', erp.chart_account_code('trade_receivable'), 'side', 'credit', 'rate', 1,
                               'description', 'Intercompany receivable eliminated'))))));
  return v_cs;
end;
$$;
revoke all on function erp.configure_consolidation(uuid, uuid[]) from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The elimination
-- ═════════════════════════════════════════════════════════════════════════════

-- What the members owe each other as at a date, from the subledger, per pair.
create or replace function erp.intercompany_pairs(p_parent_entity_id uuid, p_as_at date)
returns table(from_entity_id uuid, to_entity_id uuid, currency char(3),
              receivable_minor bigint, payable_minor bigint, difference_minor bigint)
language sql
stable
set search_path = ''
as $$
  with members as (select entity_id from erp.consolidation_members(p_parent_entity_id)),
  recv as (
    -- What the holder says it is owed by the other company.
    select si.entity_id as from_entity_id, e2.id as to_entity_id, si.currency,
           sum(si.debit_minor - si.credit_minor) as amount
      from erp.subledger_item si
      join erp.entity e2 on e2.tenant_id = si.tenant_id and e2.party_id = si.party_id
     where si.tenant_id = erp.current_tenant_id()
       and si.control_kind = 'receivable' and si.posting_date <= p_as_at
       and si.entity_id in (select entity_id from members)
       and e2.id in (select entity_id from members) and e2.id <> si.entity_id
     group by si.entity_id, e2.id, si.currency
  ),
  pay as (
    -- What the other company says it owes the holder.
    select e2.id as from_entity_id, si.entity_id as to_entity_id, si.currency,
           sum(si.credit_minor - si.debit_minor) as amount
      from erp.subledger_item si
      join erp.entity e2 on e2.tenant_id = si.tenant_id and e2.party_id = si.party_id
     where si.tenant_id = erp.current_tenant_id()
       and si.control_kind = 'payable' and si.posting_date <= p_as_at
       and si.entity_id in (select entity_id from members)
       and e2.id in (select entity_id from members) and e2.id <> si.entity_id
     group by e2.id, si.entity_id, si.currency
  )
  select coalesce(r.from_entity_id, p.from_entity_id), coalesce(r.to_entity_id, p.to_entity_id),
         coalesce(r.currency, p.currency),
         coalesce(r.amount, 0)::bigint, coalesce(p.amount, 0)::bigint,
         (coalesce(r.amount, 0) - coalesce(p.amount, 0))::bigint
    from recv r
    full outer join pay p on p.from_entity_id = r.from_entity_id and p.to_entity_id = r.to_entity_id
                         and p.currency = r.currency
   where coalesce(r.amount, 0) <> 0 or coalesce(p.amount, 0) <> 0
$$;
revoke all on function erp.intercompany_pairs(uuid, date) from public, anon, authenticated;

create or replace function erp.post_intercompany_elimination(p_parent_entity_id uuid, p_as_at date, p_reason text)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  parent    erp.entity%rowtype;
  led       erp.ledger;
  pr        erp.posting_rule%rowtype;
  v_recv    erp.account%rowtype;
  v_pay     erp.account%rowtype;
  pair      record;
  v_event   uuid;
  v_journal uuid;
  v_no      integer := 0;
  v_pairs   integer := 0;
  v_total   bigint := 0;
  v_from    text;
  v_to      text;
begin
  select * into parent from erp.entity e where e.tenant_id = v_tenant and e.id = p_parent_entity_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_ENTITY: %', p_parent_entity_id
      using errcode = '23503', hint = 'erp_entities() lists the companies.';
  end if;

  perform erp.authorise('finance.post', p_parent_entity_id, null, null, 'ledger', null);

  if length(btrim(coalesce(p_reason, ''))) < 10 then
    raise exception 'CLOVEERP_ELIMINATION_NEEDS_A_REASON: say why the balances are being eliminated as at %', p_as_at
      using errcode = '22023', hint = 'For example "month-end consolidation, August".';
  end if;

  led := erp.group_ledger(p_parent_entity_id);
  if led.id is null then
    raise exception 'CLOVEERP_NO_GROUP_LEDGER: % has no group ledger', parent.code
      using errcode = '23503', hint = 'erp_configure_consolidation(parent, members) installs it.';
  end if;

  select * into pr from erp.posting_rule r
   where r.tenant_id = v_tenant and r.code = 'intercompany_elimination' and r.status = 'active'
     and r.entity_id = p_parent_entity_id
     and r.effective_from <= p_as_at and (r.effective_to is null or r.effective_to > p_as_at)
   order by r.version desc limit 1;
  if not found then
    raise exception 'CLOVEERP_NO_ELIMINATION_RULE: no intercompany_elimination rule of % is in force on %', parent.code, p_as_at
      using errcode = '23503', hint = 'Approve and promote the consolidation change set erp_configure_consolidation() raised.';
  end if;

  if exists (select 1 from erp.journal j
              where j.tenant_id = v_tenant and j.ledger_id = led.id
                and j.source_code = 'consolidation.eliminated' and j.posting_date = p_as_at
                and j.status = 'posted'
                and not exists (select 1 from erp.journal rj where rj.reverses_journal_id = j.id and rj.status = 'posted')) then
    raise exception 'CLOVEERP_ALREADY_ELIMINATED: % has an elimination posted as at %', parent.code, p_as_at
      using errcode = '23505', hint = 'Reverse that journal before eliminating the same date again, or eliminate as at a later date.';
  end if;

  select * into v_recv from erp.account a where a.tenant_id = v_tenant and a.entity_id = parent.id
     and a.code = erp.chart_account_code('trade_receivable') and a.status = 'active';
  select * into v_pay from erp.account a where a.tenant_id = v_tenant and a.entity_id = parent.id
     and a.code = erp.chart_account_code('trade_payable') and a.status = 'active';
  if v_recv.id is null or v_pay.id is null then
    raise exception 'CLOVEERP_PARENT_HAS_NO_CHART: % has no trade receivable and payable accounts to eliminate against', parent.code
      using errcode = '23503', hint = 'Run the finance installer for the parent company first.';
  end if;

  -- Every pair must agree before any is eliminated: an elimination of a
  -- figure the two companies do not share hides the difference.
  for pair in select * from erp.intercompany_pairs(p_parent_entity_id, p_as_at) loop
    select e.code into v_from from erp.entity e where e.id = pair.from_entity_id;
    select e.code into v_to from erp.entity e where e.id = pair.to_entity_id;
    if pair.currency <> led.currency then
      raise exception 'CLOVEERP_CONSOLIDATION_NEEDS_TRANSLATION: % and % settle in % and the group ledger reports in %',
        v_from, v_to, pair.currency, led.currency
        using errcode = '22000',
              hint = 'Translation of a member''s balances is not built; consolidate companies that share the group''s currency.';
    end if;
    if pair.difference_minor <> 0 then
      raise exception 'CLOVEERP_INTERCOMPANY_UNMATCHED: % records % owed by %; % records % owed to %; the difference is %',
        v_from, pair.receivable_minor, v_to, v_to, pair.payable_minor, v_from, pair.difference_minor
        using errcode = '23514',
              hint = 'Post the missing invoice, or a correcting journal, in the company that is behind; erp_intercompany_position() shows every pair.';
    end if;
  end loop;

  select count(*), coalesce(sum(receivable_minor), 0) into v_pairs, v_total
    from erp.intercompany_pairs(p_parent_entity_id, p_as_at);
  if v_pairs = 0 then
    raise exception 'CLOVEERP_NOTHING_TO_ELIMINATE: no member of % owes another as at %', parent.code, p_as_at
      using errcode = '23514', hint = 'There is nothing to consolidate away; the members'' figures already show what the group owes the world.';
  end if;

  v_event := erp.append_event(
    'consolidation.eliminated', 'posting', led.id,
    jsonb_build_object('parent_entity', parent.code, 'as_at', p_as_at, 'pairs', v_pairs,
                       'total_minor', v_total, 'currency', led.currency, 'reason', btrim(p_reason)),
    parent.id, null);

  insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, source_event_id, posting_date, description, status)
  values (v_tenant, parent.id, led.id, 'consolidation.eliminated', v_event, p_as_at,
          format('Intercompany elimination as at %s: %s', p_as_at, btrim(p_reason)), 'draft')
  returning id into v_journal;

  for pair in
    select p.*, ef.code as from_code, et.code as to_code
      from erp.intercompany_pairs(p_parent_entity_id, p_as_at) p
      join erp.entity ef on ef.id = p.from_entity_id
      join erp.entity et on et.id = p.to_entity_id
     order by ef.code, et.code
  loop
    v_no := v_no + 1;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency,
                                  base_debit_minor, base_credit_minor, exchange_rate, dimensions,
                                  posting_rule_id, posting_rule_version, source_event_id, description)
    values (v_tenant, v_journal, v_no, v_pay.id, pair.receivable_minor, 0, led.currency,
            pair.receivable_minor, 0, 1, '{}'::jsonb, pr.id, pr.version, v_event,
            format('%s owes %s: payable eliminated', pair.to_code, pair.from_code));
    v_no := v_no + 1;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency,
                                  base_debit_minor, base_credit_minor, exchange_rate, dimensions,
                                  posting_rule_id, posting_rule_version, source_event_id, description)
    values (v_tenant, v_journal, v_no, v_recv.id, 0, pair.receivable_minor, led.currency,
            0, pair.receivable_minor, 1, '{}'::jsonb, pr.id, pr.version, v_event,
            format('%s is owed by %s: receivable eliminated', pair.from_code, pair.to_code));
  end loop;

  update erp.journal
     set status = 'posted', posted_at = now(), posted_by = erp.current_principal_id()
   where id = v_journal;

  return v_journal;
end;
$$;
revoke all on function erp.post_intercompany_elimination(uuid, date, text) from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The worksheet
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.consolidated_trial_balance(p_parent_entity_id uuid, p_as_at date default current_date)
returns table(account_code text, account_name text, account_type erp.account_type, currency char(3),
              companies_minor bigint, eliminations_minor bigint, consolidated_minor bigint, members integer)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  led      erp.ledger;
  v_other  text;
begin
  led := erp.group_ledger(p_parent_entity_id);
  if led.id is null then
    raise exception 'CLOVEERP_NO_GROUP_LEDGER: % has no group ledger',
      (select e.code from erp.entity e where e.id = p_parent_entity_id)
      using errcode = '23503', hint = 'erp_configure_consolidation(parent, members) installs it.';
  end if;

  select string_agg(e.code || ' (' || e.base_currency || ')', ', ') into v_other
    from erp.consolidation_members(p_parent_entity_id) cm
    join erp.entity e on e.id = cm.entity_id
   where e.base_currency <> led.currency;
  if v_other is not null then
    raise exception 'CLOVEERP_CONSOLIDATION_NEEDS_TRANSLATION: % report in another currency than the group ledger''s %',
      v_other, led.currency
      using errcode = '22000',
            hint = 'Translation of a member''s balances is not built; consolidate companies that share the group''s currency.';
  end if;

  return query
    with members as (select cm.entity_id from erp.consolidation_members(p_parent_entity_id) cm),
    statutory as (
      select a.code, min(a.name) as name, min(a.account_type::text)::erp.account_type as account_type,
             sum(l.debit_minor - l.credit_minor) as balance, count(distinct j.entity_id)::integer as n
        from erp.journal_line l
        join erp.journal j on j.id = l.journal_id and j.status = 'posted' and j.posting_date <= p_as_at
        join erp.ledger lg on lg.id = j.ledger_id and lg.ledger_kind = 'statutory' and lg.is_primary
        join erp.account a on a.id = l.account_id
       where l.tenant_id = v_tenant and j.entity_id in (select entity_id from members)
       group by a.code
    ),
    eliminated as (
      select a.code, sum(l.debit_minor - l.credit_minor) as balance
        from erp.journal_line l
        join erp.journal j on j.id = l.journal_id and j.status = 'posted' and j.posting_date <= p_as_at
        join erp.account a on a.id = l.account_id
       where l.tenant_id = v_tenant and j.ledger_id = led.id
       group by a.code
    )
    select coalesce(s.code, e.code),
           coalesce(s.name, (select a.name from erp.account a where a.tenant_id = v_tenant
                              and a.entity_id = p_parent_entity_id and a.code = e.code limit 1)),
           coalesce(s.account_type, (select a.account_type from erp.account a where a.tenant_id = v_tenant
                              and a.entity_id = p_parent_entity_id and a.code = e.code limit 1)),
           led.currency,
           coalesce(s.balance, 0)::bigint, coalesce(e.balance, 0)::bigint,
           (coalesce(s.balance, 0) + coalesce(e.balance, 0))::bigint,
           coalesce(s.n, 0)
      from statutory s
      full outer join eliminated e on e.code = s.code
     order by 1;
end;
$$;
revoke all on function erp.consolidated_trial_balance(uuid, date) from public, anon, authenticated;

create or replace function erp.eliminations(p_parent_entity_id uuid, p_limit integer default 50)
returns table(journal_id uuid, journal_number text, as_at date, reason text, pairs integer,
              total_minor bigint, currency char(3), posted_at timestamptz, reversed boolean)
language sql
stable
set search_path = ''
as $$
  select j.id, j.journal_number, j.posting_date,
         (ev.payload ->> 'reason'), (ev.payload ->> 'pairs')::integer,
         (ev.payload ->> 'total_minor')::bigint, l.currency, j.posted_at,
         exists (select 1 from erp.journal rj where rj.reverses_journal_id = j.id and rj.status = 'posted')
    from erp.journal j
    join erp.ledger l on l.id = j.ledger_id
    left join erp.event ev on ev.id = j.source_event_id
   where j.tenant_id = erp.current_tenant_id()
     and j.entity_id = p_parent_entity_id
     and l.ledger_kind = 'group'
     and j.source_code = 'consolidation.eliminated'
     and j.status = 'posted'
   order by j.posting_date desc, j.posted_at desc
   limit greatest(p_limit, 1)
$$;
revoke all on function erp.eliminations(uuid, integer) from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Doors
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function public.erp_configure_consolidation(p_parent_entity_id uuid, p_member_entity_ids uuid[] default null)
returns uuid
language sql
set search_path = ''
as $$
  select erp.configure_consolidation(p_parent_entity_id, p_member_entity_ids)
$$;

create or replace function public.erp_post_intercompany_elimination(p_parent_entity_id uuid, p_as_at date, p_reason text)
returns uuid
language sql
set search_path = ''
as $$
  select erp.post_intercompany_elimination(p_parent_entity_id, coalesce(p_as_at, current_date), p_reason)
$$;

create or replace function public.erp_consolidated_trial_balance(p_parent_entity_id uuid, p_as_at date default null)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(to_jsonb(t) order by t.account_code), '[]'::jsonb)
    from erp.consolidated_trial_balance(p_parent_entity_id, coalesce(p_as_at, current_date)) t
$$;

create or replace function public.erp_eliminations(p_parent_entity_id uuid, p_limit integer default 50)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(to_jsonb(t) order by t.as_at desc), '[]'::jsonb)
    from erp.eliminations(p_parent_entity_id, p_limit) t
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'erp_configure_consolidation(uuid, uuid[])',
    'erp_post_intercompany_elimination(uuid, date, text)',
    'erp_consolidated_trial_balance(uuid, date)',
    'erp_eliminations(uuid, integer)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_configure_consolidation', 'erp.configure_consolidation',
   'Sets the members of a group under their parent, installs the group ledger and promotes its elimination rule; authorises finance.configure.'),
  ('erp_post_intercompany_elimination', 'erp.post_intercompany_elimination',
   'Posts the elimination of matched intercompany balances into the group ledger as at a date, with a reason; authorises finance.post.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The register and the decision
-- ═════════════════════════════════════════════════════════════════════════════

update erp_ref.part5_capability
   set status = 'built',
       gap = null,
       artefacts = array['erp.intercompany_position()',
                         'erp.intercompany_pairs(uuid,date)',
                         'erp.consolidation_members(uuid)',
                         'erp.configure_consolidation(uuid,uuid[])',
                         'erp.post_intercompany_elimination(uuid,date,text)',
                         'erp.consolidated_trial_balance(uuid,date)',
                         'erp.eliminations(uuid,integer)',
                         'erp.raise_intercompany_order(uuid,uuid)']
 where code = '5.7.intercompany';

insert into erp_ref.product_decision_check (decision_code, schema_name, routine_name, note) values
  ('D2', 'erp_test', 'assert_consolidation_suite',
   'The consolidated trial balance is computed from the members'' posted journals and the group ledger''s elimination journals every time it is read; nothing stores a consolidated balance, and an elimination is a journal that can be reversed.')
on conflict do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. Proof
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.consolidation_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid; v_admin uuid; v_token text;
  v_auth uuid := gen_random_uuid();
  v_a uuid; v_b uuid; v_c uuid; v_a_party uuid; v_b_party uuid;
  v_gl_a uuid; v_gl_b uuid; v_cs uuid; v_j uuid; v_j2 uuid; v_x jsonb;
  v_recv_code text; v_pay_code text; v_rev_code text; v_cos_code text;
  v_ok boolean; v_msg text; tb record;
begin
  begin
    select x.tenant_id, x.admin_user_id, x.admin_token into v_tenant, v_admin, v_token
      from erp.provision_tenant('zzcon', 'Consolidation Suite', 'admin@zzcon.test', 'Group Admin') x;
    update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
    insert into auth.users (id, email) values (v_auth, 'admin@zzcon.test');
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    perform erp.claim_invitation(v_token);
    perform erp.ensure_demo_configuration(v_tenant, v_admin);

    select e.id, e.party_id into v_a, v_a_party from erp.entity e where e.tenant_id = v_tenant order by e.code limit 1;
    v_b := erp.create_entity('ZZ-SUB', 'Zz Subsidiary', 'Zz Subsidiary Ltd', 'GBP', 'GB', 'en-GB', 'en-GB', 1::smallint);
    select e.party_id into v_b_party from erp.entity e where e.id = v_b;
    perform erp.configure_finance(null, 'GBP', v_b);
    select l.id into v_gl_a from erp.ledger l where l.tenant_id = v_tenant and l.entity_id = v_a and l.ledger_kind = 'statutory' and l.is_primary;
    select l.id into v_gl_b from erp.ledger l where l.tenant_id = v_tenant and l.entity_id = v_b and l.ledger_kind = 'statutory' and l.is_primary;
    v_recv_code := erp.chart_account_code('trade_receivable');
    v_pay_code  := erp.chart_account_code('trade_payable');
    v_rev_code  := erp.chart_account_code('revenue');
    v_cos_code  := erp.chart_account_code('cost_of_sales');

    -- 1. The group.
    v_cs := erp.configure_consolidation(v_a, array[v_b]);
    return query select 'the group installs: members under the parent, a group ledger with periods, the elimination rule promoted',
      (select e.parent_entity_id from erp.entity e where e.id = v_b) = v_a
      and (erp.group_ledger(v_a)).id is not null
      and (select count(*) from erp.fiscal_period p where p.ledger_id = (erp.group_ledger(v_a)).id) = 12
      and exists (select 1 from erp.posting_rule r where r.tenant_id = v_tenant and r.code = 'intercompany_elimination'
                   and r.entity_id = v_a and r.status = 'active' and r.ledger_id = (erp.group_ledger(v_a)).id),
      'GROUP ledger, twelve periods, intercompany_elimination in force';

    -- The parent sells a thousand to the subsidiary; the subsidiary has so far
    -- booked eight hundred of it.
    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date, description, status, manual_reason)
    values (v_tenant, v_a, v_gl_a, 'manual', current_date, 'sale to the subsidiary', 'draft', 'suite: intercompany sale')
    returning id into v_j;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency, base_debit_minor, base_credit_minor, exchange_rate)
    select v_tenant, v_j, 1, a.id, 1000, 0, 'GBP', 1000, 0, 1 from erp.account a where a.tenant_id = v_tenant and a.entity_id = v_a and a.code = v_recv_code;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency, base_debit_minor, base_credit_minor, exchange_rate)
    select v_tenant, v_j, 2, a.id, 0, 1000, 'GBP', 0, 1000, 1 from erp.account a where a.tenant_id = v_tenant and a.entity_id = v_a and a.code = v_rev_code;
    insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id, party_id, journal_id, currency, debit_minor, credit_minor, posting_date)
    select v_tenant, v_a, v_gl_a, 'receivable', a.id, v_b_party, v_j, 'GBP', 1000, 0, current_date
      from erp.account a where a.tenant_id = v_tenant and a.entity_id = v_a and a.code = v_recv_code;
    update erp.journal set status = 'posted', posted_at = now(), posted_by = erp.current_principal_id() where id = v_j;

    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date, description, status, manual_reason)
    values (v_tenant, v_b, v_gl_b, 'manual', current_date, 'purchase from the parent', 'draft', 'suite: intercompany purchase')
    returning id into v_j;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency, base_debit_minor, base_credit_minor, exchange_rate)
    select v_tenant, v_j, 1, a.id, 800, 0, 'GBP', 800, 0, 1 from erp.account a where a.tenant_id = v_tenant and a.entity_id = v_b and a.code = v_cos_code;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency, base_debit_minor, base_credit_minor, exchange_rate)
    select v_tenant, v_j, 2, a.id, 0, 800, 'GBP', 0, 800, 1 from erp.account a where a.tenant_id = v_tenant and a.entity_id = v_b and a.code = v_pay_code;
    insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id, party_id, journal_id, currency, debit_minor, credit_minor, posting_date)
    select v_tenant, v_b, v_gl_b, 'payable', a.id, v_a_party, v_j, 'GBP', 0, 800, current_date
      from erp.account a where a.tenant_id = v_tenant and a.entity_id = v_b and a.code = v_pay_code;
    update erp.journal set status = 'posted', posted_at = now(), posted_by = erp.current_principal_id() where id = v_j;

    -- 2. Unmatched.
    begin
      perform erp.post_intercompany_elimination(v_a, current_date, 'month-end consolidation, the suite');
      v_ok := false; v_msg := 'an unmatched pair was eliminated';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_INTERCOMPANY_UNMATCHED:%1000%800%the difference is 200%'; v_msg := left(sqlerrm, 140);
    end;
    return query select 'an unmatched pair is refused naming both figures and the difference', v_ok, v_msg;

    -- The subsidiary books the rest.
    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date, description, status, manual_reason)
    values (v_tenant, v_b, v_gl_b, 'manual', current_date, 'the rest of the purchase', 'draft', 'suite: the missing two hundred')
    returning id into v_j;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency, base_debit_minor, base_credit_minor, exchange_rate)
    select v_tenant, v_j, 1, a.id, 200, 0, 'GBP', 200, 0, 1 from erp.account a where a.tenant_id = v_tenant and a.entity_id = v_b and a.code = v_cos_code;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency, base_debit_minor, base_credit_minor, exchange_rate)
    select v_tenant, v_j, 2, a.id, 0, 200, 'GBP', 0, 200, 1 from erp.account a where a.tenant_id = v_tenant and a.entity_id = v_b and a.code = v_pay_code;
    insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id, party_id, journal_id, currency, debit_minor, credit_minor, posting_date)
    select v_tenant, v_b, v_gl_b, 'payable', a.id, v_a_party, v_j, 'GBP', 0, 200, current_date
      from erp.account a where a.tenant_id = v_tenant and a.entity_id = v_b and a.code = v_pay_code;
    update erp.journal set status = 'posted', posted_at = now(), posted_by = erp.current_principal_id() where id = v_j;

    -- 3. Matched: eliminated, with the event.
    v_j2 := erp.post_intercompany_elimination(v_a, current_date, 'month-end consolidation, the suite');
    return query select 'once matched, the elimination posts one journal in the group ledger, traced to its event',
      (select j.status::text from erp.journal j where j.id = v_j2) = 'posted'
      and (select j.ledger_id from erp.journal j where j.id = v_j2) = (erp.group_ledger(v_a)).id
      and (select count(*) from erp.journal_line jl where jl.journal_id = v_j2) = 2
      and (select sum(jl.debit_minor) from erp.journal_line jl where jl.journal_id = v_j2) = 1000
      and exists (select 1 from erp.event ev join erp.journal j on j.source_event_id = ev.id
                   where j.id = v_j2 and ev.event_type = 'consolidation.eliminated'
                     and (ev.payload ->> 'total_minor')::bigint = 1000 and (ev.payload ->> 'pairs')::integer = 1)
      and (select bool_and(jl.posting_rule_id is not null) from erp.journal_line jl where jl.journal_id = v_j2),
      'Dr payable 1000 / Cr receivable 1000 in GROUP; consolidation.eliminated for one pair';

    -- 4. Not twice.
    begin
      perform erp.post_intercompany_elimination(v_a, current_date, 'month-end consolidation, again');
      v_ok := false; v_msg := 'the same date was eliminated twice';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_ALREADY_ELIMINATED:%'; v_msg := left(sqlerrm, 100);
    end;
    return query select 'the same date cannot be eliminated twice', v_ok, v_msg;

    -- 5. The worksheet.
    select * into tb from erp.consolidated_trial_balance(v_a, current_date) t where t.account_code = v_recv_code;
    v_ok := tb.companies_minor = 1000 and tb.eliminations_minor = -1000 and tb.consolidated_minor = 0;
    select * into tb from erp.consolidated_trial_balance(v_a, current_date) t where t.account_code = v_pay_code;
    v_ok := v_ok and tb.companies_minor = -1000 and tb.eliminations_minor = 1000 and tb.consolidated_minor = 0;
    select * into tb from erp.consolidated_trial_balance(v_a, current_date) t where t.account_code = v_rev_code;
    v_ok := v_ok and tb.companies_minor = -1000 and tb.eliminations_minor = 0 and tb.consolidated_minor = -1000;
    select * into tb from erp.consolidated_trial_balance(v_a, current_date) t where t.account_code = v_cos_code;
    v_ok := v_ok and tb.companies_minor = 1000 and tb.consolidated_minor = 1000
            and (select sum(t.consolidated_minor) from erp.consolidated_trial_balance(v_a, current_date) t) = 0;
    return query select 'the worksheet nets the intercompany receivable and payable to nothing and leaves revenue and cost alone',
      v_ok, format('%s and %s consolidated 0; %s -1000; %s 1000; the whole balances', v_recv_code, v_pay_code, v_rev_code, v_cos_code);

    -- 6. The listing.
    v_x := public.erp_eliminations(v_a);
    return query select 'the eliminations listing says when, why and how much',
      jsonb_array_length(v_x) = 1
      and (v_x -> 0 ->> 'journal_id')::uuid = v_j2
      and (v_x -> 0 ->> 'total_minor')::bigint = 1000
      and v_x -> 0 ->> 'reason' = 'month-end consolidation, the suite'
      and not (v_x -> 0 ->> 'reversed')::boolean,
      v_x -> 0 ->> 'journal_number';

    -- 7. Another currency.
    v_c := erp.create_entity('ZZ-EU', 'Zz Europe', 'Zz Europe BV', 'EUR', 'NL', 'nl', 'nl', 1::smallint);
    perform erp.configure_consolidation(v_a, array[v_c]);
    begin
      perform erp.consolidated_trial_balance(v_a, current_date);
      v_ok := false; v_msg := 'a EUR member was summed into a GBP group';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_CONSOLIDATION_NEEDS_TRANSLATION: ZZ-EU (EUR)%'; v_msg := left(sqlerrm, 120);
    end;
    return query select 'a member in another currency is refused rather than summed', v_ok, v_msg;

    -- 8. The register.
    return query select 'the register says intercompany is built, and D2 is bound to the proof',
      (select c.status from erp_ref.part5_capability c where c.code = '5.7.intercompany') = 'built'
      and not exists (select 1 from erp.part5_coverage_report() f where f.reference = '5.7.intercompany')
      and exists (select 1 from erp_ref.product_decision_check c
                   where c.decision_code = 'D2' and c.routine_name = 'assert_consolidation_suite'),
      '5.7.intercompany; D2';

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      case_name := 'the suite ran to its end';
      passed := false; detail := left(sqlerrm, 300);
      return next;
    end if;
  end;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant tn where tn.code = 'zzcon');
  detail := 'the organisation, its group and its journals rolled back';
  return next;
end;
$$;

create or replace function erp_test.assert_consolidation_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 9;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _consolidation_suite on commit drop as
    select * from erp_test.consolidation_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _consolidation_suite;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_CONSOLIDATION_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_CONSOLIDATION_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('consolidation: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_consolidation_suite() from public, anon, authenticated;
revoke all on function erp_test.consolidation_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. Prove it
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_consolidation_suite();
select erp_test.assert_intercompany_suite();
select erp_test.assert_companies_suite();
select erp_test.assert_finance_suite();
select erp.assert_part5_coverage();
select erp.assert_vocabulary_aligned();
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
