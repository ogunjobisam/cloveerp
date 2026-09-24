set lock_timeout = '30s';

-- =============================================================================
-- 20260924700000  A works order reaches the ledger
-- -----------------------------------------------------------------------------
-- PR7, M2b: the second half of node M2 of docs/spec/simplification-review.md,
-- works order settlement. M2a (20260924600000) put right what the ledger would
-- be told; this half tells it.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
--   * Nothing in production posted. A component issued to a works order left
--     the stock valuation and stayed in the inventory account; finished goods
--     taken in went into the valuation and nowhere in the books. Any
--     organisation making anything failed erp.assert_inventory_reconciles()
--     from its first issue, and the build was green only because every suite
--     purges its organisation and the demonstration makes nothing.
--   * The work in progress account was an expense or an asset depending on
--     which module an organisation installed first, and nothing ever posted
--     to it. There was no account for the labour an order absorbs.
--   * The variance an order closed on was a figure on a screen. It never
--     reached the books.
--
-- ── WHAT CHANGES ─────────────────────────────────────────────────────────────
--
--   * Four posting rules, on the works order: material issued (Dr work in
--     progress, Cr inventory), labour absorbed (Dr work in progress, Cr labour
--     absorbed), output received (Dr inventory, Cr work in progress) and the
--     settlement at close (what the order still holds, to labour efficiency
--     variance and material usage variance). The production installer ships
--     them as version 3, and an installed organisation takes them as an
--     upgrade.
--   * A new account purpose, labour_absorbed (5200; 6600 under §8.1), and work
--     in progress is an asset wherever nothing has posted to it yet.
--   * erp.post_works_order_finance() posts one of the four for one order, at
--     the movement's exact cost, the booking's change in labour, or the
--     order's residual.
--   * An order decides at release whether it posts (works_order.posts_to_ledger):
--     only when all four rules are in force for its company. An order already
--     on the floor carries on as it did, and nothing is posted after the fact.
--   * Close settles. What the order still holds in work in progress goes to
--     the two variance accounts, and close refuses if the books and
--     erp.works_order_variance() disagree. A settled order takes no more hours.
--   * erp.assert_work_in_progress_reconciles() holds every order's work in
--     progress in the books to what its variance says it holds, and to nothing
--     once it has closed, for every organisation, through the whole-database
--     run. It does not tie the account's balance to its orders: an opening
--     balance or a hand journal may put work in progress there too.
--
-- ── WHAT IT DOES NOT DO ──────────────────────────────────────────────────────
--
--   * An organisation with production history already fails the inventory
--     reconciliation, by what its orders consumed and made without posting.
--     This migration says how far, as a notice; putting that right is a
--     reviewed one-off by the operator, not something a migration guesses at.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. The account, the events and the refusals
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.chart_account_purpose
  (purpose, name, account_type, control_kind, default_code, statutory_code, installer_creates, note, seq) values
  ('labour_absorbed', 'Labour absorbed', 'expense', null, '5200', '6600', false,
   'The labour works orders absorb into work in progress, at the rate their routing '
   'froze: a credit against the wages posted elsewhere. Only production posts to it, '
   'so the finance installer does not create it.', 135)
on conflict (purpose) do nothing;

update erp_ref.chart_account_purpose
   set note = 'What a works order holds: the material issued to it and the labour it '
              'absorbed, less the finished goods it put into stock. An asset.'
 where purpose = 'work_in_progress';

insert into erp_ref.pack_item (pack_code, object_kind, object_key, payload, provenance, seq) values
  ('chart_8_1', 'account', '6600',
   '{"code": "6600", "name": "Labour absorbed", "is_postable": true, "account_type": "expense", "close_blocking": false, "reconciliation_required": false}'::jsonb,
   'The labour works orders absorb, in §8.1''s cost of sales band (20260924700000).', 135),
  ('chart_8_1', 'account_determination', 'labour_absorbed',
   '{"note": "Labour absorbed", "account": "6600", "transaction_type": "labour_absorbed"}'::jsonb,
   'The labour works orders absorb, in §8.1''s cost of sales band (20260924700000).', 435)
on conflict do nothing;

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('interview.account_purpose.labour_absorbed', 'en', 'Labour absorbed', 'finance',
   'The name of the account purpose for labour works orders absorb.'),
  ('interview.account_purpose.labour_absorbed.note', 'en',
   'The cost of the hours booked to works orders, taken into the products they made.', 'finance',
   'What the labour absorbed account holds.'),
  ('event.works_order.material_issued', 'en', 'Material issued to a works order', 'production',
   'Event raised when a component issued to a works order, or returned from it, posts to the ledger.'),
  ('event.works_order.labour_absorbed', 'en', 'Labour absorbed by a works order', 'production',
   'Event raised when hours booked to a works order, or taken off it, post to the ledger.'),
  ('event.works_order.output_received', 'en', 'Finished goods taken in from a works order', 'production',
   'Event raised when finished goods taken in from a works order, or taken back out, post to the ledger.'),
  ('event.works_order.settled', 'en', 'Works order settled', 'production',
   'Event raised when a works order closes and what it still holds goes to its variances.'),
  ('event.works_order.material_issued', 'de', 'Material an einen Fertigungsauftrag ausgegeben', 'production',
   'Ereignis, wenn an einen Fertigungsauftrag ausgegebenes oder von ihm zurückgegebenes Material gebucht wird.'),
  ('event.works_order.labour_absorbed', 'de', 'Arbeitszeit von einem Fertigungsauftrag aufgenommen', 'production',
   'Ereignis, wenn auf einen Fertigungsauftrag gebuchte oder zurückgenommene Stunden gebucht werden.'),
  ('event.works_order.output_received', 'de', 'Fertigerzeugnisse aus einem Fertigungsauftrag zugegangen', 'production',
   'Ereignis, wenn Fertigerzeugnisse aus einem Fertigungsauftrag zugehen oder wieder entnommen werden.'),
  ('event.works_order.settled', 'de', 'Fertigungsauftrag abgerechnet', 'production',
   'Ereignis, wenn ein Fertigungsauftrag abgeschlossen wird und sein Bestand an Abweichungen geht.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
select v.code, 1, 'works_order', 'production', 'event.' || v.code, v.description,
       '{"type":"object","required":["works_order_id","order_number","amount_minor"],
         "properties":{"works_order_id":{"type":"string"},"order_number":{"type":"string"},
                       "amount_minor":{"type":"integer"},"movement_id":{"type":"integer"},
                       "rule_code":{"type":"string"}}}'::jsonb, true
  from (values
    ('works_order.material_issued', 'A component issued to a works order, or returned from it, at the movement''s exact cost.'),
    ('works_order.labour_absorbed', 'Hours booked to a works order, or taken off it, at the rate its routing froze.'),
    ('works_order.output_received', 'Finished goods taken in from a works order, or taken back out, at the movement''s exact cost.'),
    ('works_order.settled', 'A works order closed, and what it still held went to its variances.')
  ) v(code, description)
on conflict do nothing;

select erp.register_refusal('CLOVEERP_WORKS_ORDER_SETTLED',
  'Booking hours on a works order that has closed and been settled in the books.',
  'Its work in progress went to its variances when it closed. An hour booked now would sit in work in progress with no order to settle it.',
  'Book the time to the order still open that it was worked for.');
select erp.register_refusal('CLOVEERP_WORKS_ORDER_WIP_DISAGREES',
  'Closing a works order whose work in progress in the books is not what its variance says it holds.',
  'Settling it would post one figure and report another. Something was posted to the order other than its issues, hours and receipts.',
  'Find the journal posted to the order other than by its issues, hours and receipts, and reverse it; then close the order.');
select erp.register_refusal('CLOVEERP_WORKS_ORDER_WIP_REMAINS',
  'Cancelling a works order that still holds something in work in progress.',
  'A cancelled order is never settled, so what it holds would stay in the books for ever.',
  'Return what was issued to it and take its hours back off, or close it instead.');
select erp.register_refusal('CLOVEERP_PRODUCTION_NEEDS_A_LEDGER',
  'Installing production for a company that has no ledger.',
  'Production posts what it consumes and makes, and a company without a ledger has nowhere to post it.',
  'Install finance first, then production.');

alter table erp.works_order
  add column if not exists posts_to_ledger boolean not null default false;

comment on column erp.works_order.posts_to_ledger is
  'Whether this order posts its issues, hours, receipts and settlement to the ledger. '
  'Decided once, at release, by whether the production posting rules were in force for '
  'its company (20260924700000). An order released before carries on as it did.';

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. The account types
--
-- Work in progress is stock that has been started. configure_production()
-- created it as an expense, configure_finance() as an asset, and whichever ran
-- first won. Nothing has ever posted to it, so every one is put right; one
-- that somebody posted to by hand is left alone and named.
-- ─────────────────────────────────────────────────────────────────────────────

do $wip_type$
declare
  v_fixed integer;
  v_left  text;
begin
  update erp.account a
     set account_type = 'asset', updated_at = now()
   where a.account_type = 'expense'
     and lower(a.name) = 'work in progress'
     and not exists (select 1 from erp.journal_line jl where jl.account_id = a.id);
  get diagnostics v_fixed = row_count;

  select string_agg(format('%s %s', t.code, a.code), ', ') into v_left
    from erp.account a join erp.tenant t on t.id = a.tenant_id
   where a.account_type = 'expense' and lower(a.name) = 'work in progress';

  raise notice 'work in progress: % account(s) made an asset%', v_fixed,
    coalesce('; left as an expense because something has posted to them: ' || v_left, '');
end
$wip_type$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A3. The rules a line may be measured on
-- ─────────────────────────────────────────────────────────────────────────────

do $basis$
declare
  v_sig constant text := 'erp.assert_posting_rule_balances(text,integer)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$'unbilled_return_value', 'billed_return_value');$o$;
  v_new constant text := $n$'unbilled_return_value', 'billed_return_value',
                                      -- What a works order posts (20260924700000).
                                      'labour_cost', 'wip_residual', 'labour_efficiency_variance');$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % basis anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$basis$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A4. The four rules, from one helper
--
-- The installer and the upgrade ship the same lines. The installer names the
-- account by the code today's chart gives the purpose; the upgrade names the
-- purpose, and the planner resolves it against the organisation's own chart.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.works_order_posting_rules(p_by_purpose boolean default false)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with acct(purpose) as (values ('work_in_progress'), ('inventory'), ('labour_absorbed'),
                                ('labour_efficiency_variance'), ('material_usage_variance')),
  a as (
    select jsonb_object_agg(purpose,
             case when p_by_purpose then jsonb_build_object('purpose', purpose)
                  else to_jsonb(erp.chart_account_code(purpose)) end) as ac
      from acct)
  select jsonb_build_array(
    jsonb_build_object(
      'code', 'works_order_issue', 'name', 'Material issued to a works order', 'ledger', 'GL',
      'event_type', 'works_order.material_issued',
      'posting_lines', jsonb_build_array(
        jsonb_build_object('account', a.ac -> 'work_in_progress', 'role', 'work_in_progress', 'side', 'debit', 'basis', 'stock_cost', 'rate', 1,
                           'description', 'Material into work in progress, at cost'),
        jsonb_build_object('account', a.ac -> 'inventory', 'side', 'credit', 'basis', 'stock_cost', 'rate', 1,
                           'description', 'Material out of stock, at cost'))),
    jsonb_build_object(
      'code', 'works_order_labour', 'name', 'Labour absorbed by a works order', 'ledger', 'GL',
      'event_type', 'works_order.labour_absorbed',
      'posting_lines', jsonb_build_array(
        jsonb_build_object('account', a.ac -> 'work_in_progress', 'role', 'work_in_progress', 'side', 'debit', 'basis', 'labour_cost', 'rate', 1,
                           'description', 'Labour into work in progress, at the routing''s rate'),
        jsonb_build_object('account', a.ac -> 'labour_absorbed', 'side', 'credit', 'basis', 'labour_cost', 'rate', 1,
                           'description', 'Labour absorbed'))),
    jsonb_build_object(
      'code', 'works_order_output', 'name', 'Finished goods from a works order', 'ledger', 'GL',
      'event_type', 'works_order.output_received',
      'posting_lines', jsonb_build_array(
        jsonb_build_object('account', a.ac -> 'inventory', 'side', 'debit', 'basis', 'stock_cost', 'rate', 1,
                           'description', 'Finished goods into stock, at cost'),
        jsonb_build_object('account', a.ac -> 'work_in_progress', 'role', 'work_in_progress', 'side', 'credit', 'basis', 'stock_cost', 'rate', 1,
                           'description', 'Finished goods out of work in progress'))),
    jsonb_build_object(
      'code', 'works_order_settlement', 'name', 'Works order settled', 'ledger', 'GL',
      'event_type', 'works_order.settled',
      'posting_lines', jsonb_build_array(
        jsonb_build_object('account', a.ac -> 'work_in_progress', 'role', 'work_in_progress', 'side', 'credit', 'basis', 'wip_residual', 'rate', 1,
                           'description', 'What the order still held'),
        jsonb_build_object('account', a.ac -> 'labour_efficiency_variance', 'side', 'debit',
                           'basis', 'labour_efficiency_variance', 'rate', 1,
                           'description', 'The hours it took against the standard allowed'),
        jsonb_build_object('account', a.ac -> 'material_usage_variance', 'side', 'debit', 'balancing', true,
                           'description', 'The material it used against the standard allowed, and what it put into stock'))))
    from a
$$;

revoke all on function erp.works_order_posting_rules(boolean) from public, anon;

comment on function erp.works_order_posting_rules(boolean) is
  'The four posting rules a works order posts by (20260924700000): by the account code '
  'today''s chart gives each purpose, or by purpose for an upgrade to resolve.';

-- Whether an order released today at this company would post: the ledger is
-- there and all four rules are in force.
create or replace function erp.production_posts_to_ledger(p_entity_id uuid, p_on date)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (select 1 from erp.ledger l
                  where l.tenant_id = erp.current_tenant_id() and l.entity_id = p_entity_id
                    and l.is_primary and l.status = 'active')
     and (select count(distinct r.code) from erp.posting_rule r
           where r.tenant_id = erp.current_tenant_id()
             and r.code in ('works_order_issue', 'works_order_labour', 'works_order_output', 'works_order_settlement')
             and (r.entity_id is null or r.entity_id = p_entity_id)
             and r.status = 'active' and r.effective_from <= p_on
             and (r.effective_to is null or r.effective_to > p_on)) = 4
     -- And the company holds every account they name (found on review: a
     -- second company installed finance, which does not create labour
     -- absorbed, and its orders then refused every booking).
     and not exists (
       select 1 from erp.posting_rule r
        cross join lateral jsonb_array_elements(r.posting_lines) l
        where r.tenant_id = erp.current_tenant_id()
          and r.code in ('works_order_issue', 'works_order_labour', 'works_order_output', 'works_order_settlement')
          and (r.entity_id is null or r.entity_id = p_entity_id)
          and r.status = 'active' and r.effective_from <= p_on
          and (r.effective_to is null or r.effective_to > p_on)
          and not exists (select 1 from erp.account a
                           where a.tenant_id = r.tenant_id and a.entity_id = p_entity_id
                             and a.code = l.value ->> 'account' and a.status = 'active'))
$$;

revoke all on function erp.production_posts_to_ledger(uuid, date) from public, anon;

comment on function erp.production_posts_to_ledger(uuid, date) is
  'True when a works order released on the day at the company would post: it has a '
  'primary ledger, all four works order rules are in force, and it holds every account '
  'they name (20260924700000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- A5. What an order holds, and how much labour it has absorbed
-- ─────────────────────────────────────────────────────────────────────────────

-- What the order holds in the books, account by account: every posted line
-- raised by one of the order's own events on an account some version of the
-- works order rules marks as work in progress. Any version, not the one in
-- force, so an organisation that repoints its rules mid-order still finds
-- what its orders hold where they put it, and the settlement that takes it
-- off the old account is counted there too (found on review).
create or replace function erp.works_order_wip_by_account(p_works_order_id uuid)
returns table(account_id uuid, amount_minor bigint)
language sql
stable
set search_path = ''
as $$
  select jl.account_id, sum(jl.base_debit_minor - jl.base_credit_minor)::bigint
    from erp.works_order w
    join erp.event e on e.tenant_id = w.tenant_id and e.aggregate_type = 'works_order'
                    and e.aggregate_id = w.id
    join erp.journal_line jl on jl.tenant_id = w.tenant_id and jl.source_event_id = e.id
    join erp.journal j on j.id = jl.journal_id and j.status = 'posted'
    join erp.account a on a.id = jl.account_id
   where w.tenant_id = erp.current_tenant_id() and w.id = p_works_order_id
     and exists (select 1 from erp.posting_rule pr
                  cross join lateral jsonb_array_elements(pr.posting_lines) l
                  where pr.tenant_id = w.tenant_id
                    and pr.code in ('works_order_issue', 'works_order_labour',
                                    'works_order_output', 'works_order_settlement')
                    and (pr.entity_id is null or pr.entity_id = w.entity_id)
                    and l.value ->> 'role' = 'work_in_progress'
                    and l.value ->> 'account' = a.code)
   group by jl.account_id
$$;

revoke all on function erp.works_order_wip_by_account(uuid) from public, anon;

comment on function erp.works_order_wip_by_account(uuid) is
  'What a works order holds in work in progress, by account: its own posted lines on '
  'the accounts any version of the works order rules marks as work in progress '
  '(20260924700000).';

create or replace function erp.works_order_wip(p_works_order_id uuid)
returns bigint
language sql
stable
set search_path = ''
as $$
  select coalesce(sum(w.amount_minor), 0)::bigint from erp.works_order_wip_by_account(p_works_order_id) w
$$;

revoke all on function erp.works_order_wip(uuid) from public, anon;

comment on function erp.works_order_wip(uuid) is
  'What a works order holds in work in progress in the books, on whichever accounts its '
  'rules put it (20260924700000).';

-- The labour an operation has absorbed, as the variance reads it. A booking
-- posts the change in this figure, not its own minutes at the rate, so the
-- sum of what was posted is always this, rounding and all.
create or replace function erp.operation_labour_minor(p_minutes numeric, p_rate_minor_per_hour bigint)
returns bigint
language sql
immutable
set search_path = ''
as $$
  select round(coalesce(p_minutes, 0) / 60.0 * coalesce(p_rate_minor_per_hour, 0))::bigint
$$;

revoke all on function erp.operation_labour_minor(numeric, bigint) from public, anon;

comment on function erp.operation_labour_minor(numeric, bigint) is
  'The labour cost of an operation''s minutes at its rate, rounded as '
  'erp.works_order_variance() rounds it (20260924700000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- B1. One routine posts for a works order
--
-- An amount is signed: a return, a reversal or a correction down posts
-- negative, and each line's side turns over with it. A movement's amount is
-- its exact cost, which is what the valuation recorded, so the ledger and the
-- valuation move by the same figure.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.post_works_order_finance(
  p_works_order_id uuid, p_rule_code text, p_amount bigint default null,
  p_movement_id bigint default null, p_parts jsonb default '{}'::jsonb)
returns uuid
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  wo        erp.works_order%rowtype;
  m         erp.stock_movement%rowtype;
  pr        erp.posting_rule%rowtype;
  v_amount  bigint := p_amount;
  v_on      date;
  v_ledger  uuid;
  v_ccy     char(3);
  v_event   uuid;
  v_journal uuid;
  v_sum     bigint := 0;
  v_no      integer := 0;
  v_signed  bigint;
  v_acct    uuid;
  v_kind    erp.account.control_kind%type;
  rl        record;
  wa        record;
begin
  select * into wo from erp.works_order where tenant_id = v_tenant and id = p_works_order_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_WORKS_ORDER: %', p_works_order_id using errcode = '23503';
  end if;
  -- An order released before its rules were in force does not post, now or
  -- later.
  if not wo.posts_to_ledger then
    return null;
  end if;

  if p_movement_id is not null then
    select * into m from erp.stock_movement where tenant_id = v_tenant and id = p_movement_id;
    if not found then
      raise exception 'CLOVEERP_UNKNOWN_MOVEMENT: %', p_movement_id using errcode = '23503';
    end if;
    v_amount := coalesce(v_amount,
                         case when m.is_reversal then -1 else 1 end
                         * coalesce(m.cost_minor, round(m.quantity * m.unit_cost_minor)::bigint, 0));
    v_on := (m.occurred_at at time zone erp.local_timezone(m.site_id))::date;
  end if;
  v_on := coalesce(v_on, erp.local_today(wo.site_id));

  if coalesce(v_amount, 0) = 0 and coalesce((p_parts ->> 'labour_efficiency_variance')::bigint, 0) = 0 then
    return null;
  end if;

  select * into pr from erp.posting_rule r
   where r.tenant_id = v_tenant and r.code = p_rule_code and r.status = 'active'
     and (r.entity_id is null or r.entity_id = wo.entity_id)
     and r.effective_from <= v_on and (r.effective_to is null or r.effective_to > v_on)
   order by (r.entity_id is null), r.version desc limit 1;
  if not found then
    raise exception 'CLOVEERP_NO_POSTING_RULE_IN_FORCE: no posting rule % is in force for this organisation on %', p_rule_code, v_on
      using errcode = '23514',
            hint = 'erp_upgrade_module_configuration(''production'') delivers the rules the production installer ships.';
  end if;

  select l.id, l.currency into v_ledger, v_ccy
    from erp.ledger l
   where l.tenant_id = v_tenant and l.entity_id = wo.entity_id and l.is_primary and l.status = 'active';
  if v_ledger is null then
    raise exception 'CLOVEERP_NO_LEDGER: the company making % has no primary ledger', wo.order_number
      using errcode = '23514', hint = 'Configure finance for the company before it makes anything.';
  end if;
  if m.id is not null and m.currency is distinct from v_ccy then
    raise exception 'CLOVEERP_NO_TRANSLATION: movement % is in %, and the ledger of the company making % is in %',
      m.id, m.currency, wo.order_number, v_ccy
      using errcode = '23514', hint = 'A works order is costed in its company''s own currency.';
  end if;

  v_event := erp.append_event(pr.event_type, 'works_order', wo.id,
    jsonb_strip_nulls(jsonb_build_object(
      'works_order_id', wo.id, 'order_number', wo.order_number, 'amount_minor', coalesce(v_amount, 0),
      'movement_id', p_movement_id, 'rule_code', pr.code)) || coalesce(p_parts, '{}'::jsonb),
    wo.entity_id, wo.site_id);

  insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, source_event_id,
                           posting_date, description, status)
  values (v_tenant, wo.entity_id, v_ledger, pr.event_type, v_event, v_on,
          format('%s: %s', wo.order_number, pr.name), 'draft')
  returning id into v_journal;

  -- Each line signed as a debit; the balancing line takes what is left.
  for rl in
    select x.value as line, x.ordinality as ord
      from jsonb_array_elements(pr.posting_lines) with ordinality x
     order by coalesce((x.value ->> 'balancing')::boolean, false), x.ordinality
  loop
    -- What the order holds comes off each account it is held on, which is
    -- the settlement rule's own only while nobody has repointed the rules.
    if rl.line ->> 'basis' = 'wip_residual' then
      for wa in select * from erp.works_order_wip_by_account(wo.id) x where x.amount_minor <> 0 loop
        v_signed := round(wa.amount_minor * coalesce((rl.line ->> 'rate')::numeric, 1)
                          * case when rl.line ->> 'side' = 'debit' then 1 else -1 end)::bigint;
        v_sum := v_sum + v_signed;
        v_no := v_no + 1;
        insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
                                      currency, base_debit_minor, base_credit_minor, exchange_rate,
                                      posting_rule_id, posting_rule_version, source_event_id, description)
        values (v_tenant, v_journal, v_no, wa.account_id,
                greatest(v_signed, 0), greatest(-v_signed, 0), v_ccy,
                greatest(v_signed, 0), greatest(-v_signed, 0), 1,
                pr.id, pr.version, v_event, rl.line ->> 'description');
      end loop;
      continue;
    end if;

    if coalesce((rl.line ->> 'balancing')::boolean, false) then
      v_signed := -v_sum;
    else
      v_signed := round(
        case rl.line ->> 'basis'
          when 'labour_efficiency_variance' then coalesce((p_parts ->> 'labour_efficiency_variance')::bigint, 0)
          when 'stock_cost' then v_amount
          when 'labour_cost' then v_amount
          when 'wip_residual' then v_amount
        end
        * coalesce((rl.line ->> 'rate')::numeric, 1)
        * case when rl.line ->> 'side' = 'debit' then 1 else -1 end)::bigint;
      if v_signed is null then
        raise exception 'CLOVEERP_POSTING_RULE_BASIS: % measures a line on %, which a works order does not post',
          pr.code, coalesce(rl.line ->> 'basis', 'nothing') using errcode = '23514',
          hint = 'A works order line is measured on the stock cost, the labour cost, what the order holds, or its labour efficiency variance. Repoint the rule.';
      end if;
      v_sum := v_sum + v_signed;
    end if;

    continue when v_signed = 0;

    select a.id, a.control_kind into v_acct, v_kind from erp.account a
     where a.tenant_id = v_tenant and a.entity_id = wo.entity_id and a.status = 'active'
       and a.code = rl.line ->> 'account';
    if v_acct is null then
      raise exception 'CLOVEERP_ACCOUNT_NOT_ON_CHART: % names account %, which the company making % does not have',
        pr.code, rl.line ->> 'account', wo.order_number
        using errcode = '23514',
              hint = 'Add the account to the company''s chart, or repoint the rule.';
    end if;

    v_no := v_no + 1;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
                                  currency, base_debit_minor, base_credit_minor, exchange_rate,
                                  posting_rule_id, posting_rule_version, source_event_id, description)
    values (v_tenant, v_journal, v_no, v_acct,
            greatest(v_signed, 0), greatest(-v_signed, 0), v_ccy,
            greatest(v_signed, 0), greatest(-v_signed, 0), 1,
            pr.id, pr.version, v_event, rl.line ->> 'description');

    -- A control account carries its detail, keyed by the item moved, as
    -- erp.post_movement_finance() keys it.
    if v_kind is not null then
      insert into erp.subledger_item (
        tenant_id, entity_id, ledger_id, control_kind, control_account_id,
        item_id, journal_id, currency, debit_minor, credit_minor, posting_date)
      values (v_tenant, wo.entity_id, v_ledger, v_kind, v_acct,
              m.item_id, v_journal, v_ccy,
              greatest(v_signed, 0), greatest(-v_signed, 0), v_on);
    end if;
  end loop;

  if v_no = 0 then
    delete from erp.journal where id = v_journal;
    return null;
  end if;

  update erp.journal set status = 'posted', posted_at = now(), posted_by = erp.current_principal_id(),
         updated_at = now()
   where id = v_journal;
  return v_journal;
end;
$$;

revoke all on function erp.post_works_order_finance(uuid, text, bigint, bigint, jsonb) from public, anon;

comment on function erp.post_works_order_finance(uuid, text, bigint, bigint, jsonb) is
  'Posts one of the four works order rules for one order (20260924700000): a movement '
  'at its exact cost, a booking''s change in labour, or the settlement. Signed: a '
  'return, reversal or correction down turns each line over. Nothing for an order '
  'released before its rules were in force.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B2. The doors post
-- ─────────────────────────────────────────────────────────────────────────────


-- Release decides, once, whether the order posts.
do $patch1$
declare
  v_sig  constant text := 'erp.release_works_order(uuid)';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
$o$         standard_labour_minor = v_std - v_mat,
         updated_at = now()$o$,
$n$         standard_labour_minor = v_std - v_mat,
         -- Whether it posts, decided once (20260924700000): an order released
         -- before the rules were in force carries on as it did.
         posts_to_ledger = erp.production_posts_to_ledger(wo.entity_id, erp.local_today(wo.site_id)),
         updated_at = now()$n$,
$o$          jsonb_build_object('standard_cost_minor', v_std,
                             'released_short', v_short is not null),$o$,
$n$          jsonb_build_object('standard_cost_minor', v_std,
                             'released_short', v_short is not null,
                             'posts_to_ledger', erp.production_posts_to_ledger(wo.entity_id, erp.local_today(wo.site_id))),$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$patch1$;

-- An issue posts at the movement's cost.
do $patch2$
declare
  v_sig  constant text := 'erp.issue_to_works_order(uuid,uuid,numeric,uuid,uuid)';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
$o$  returning id into v_id;

  update erp.works_order_component$o$,
$n$  returning id into v_id;

  -- Into work in progress, at what the valuation recorded (20260924700000).
  perform erp.post_works_order_finance(p_works_order_id, 'works_order_issue', null, v_id);

  update erp.works_order_component$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$patch2$;

-- A receipt posts at the movement's cost.
do $patch3$
declare
  v_sig  constant text := 'erp.receive_works_order_output(uuid,numeric,text,uuid)';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
$o$  v_policy  jsonb;
  r         record;$o$,
$n$  v_policy  jsonb;
  v_moved   bigint;
  r         record;$n$,
$o$          wo.order_number, p_works_order_id);

  update erp.works_order
     set quantity_completed = quantity_completed + p_quantity,$o$,
$n$          wo.order_number, p_works_order_id)
  returning id into v_moved;

  -- Out of work in progress into stock, at what the valuation recorded
  -- (20260924700000).
  perform erp.post_works_order_finance(p_works_order_id, 'works_order_output', null, v_moved);

  update erp.works_order
     set quantity_completed = quantity_completed + p_quantity,$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$patch3$;

-- A return and a reversal post back, at the mirror movement's cost.
do $patch4$
declare
  v_sig  constant text := 'erp.return_works_order_issue(bigint,text)';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
$o$  returning id into v_new;

  -- One line, as the issue drew on one$o$,
$n$  returning id into v_new;

  -- Out of work in progress, back into stock (20260924700000).
  perform erp.post_works_order_finance(wo.id, 'works_order_issue', null, v_new);

  -- One line, as the issue drew on one$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$patch4$;

do $patch5$
declare
  v_sig  constant text := 'erp.reverse_works_order_output(bigint,text)';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
$o$  returning id into v_new;

  -- The order made less than it said.$o$,
$n$  returning id into v_new;

  -- Out of stock, back into work in progress (20260924700000).
  perform erp.post_works_order_finance(wo.id, 'works_order_output', null, v_new);

  -- The order made less than it said.$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$patch5$;

-- A booking posts the change in the operation's labour, and a settled order
-- takes no more.
do $patch6$
declare
  v_sig  constant text := 'erp.book_operation_time(uuid,integer,numeric,numeric,numeric)';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
$o$  wo       erp.works_order%rowtype;
begin
  select * into wo from erp.works_order
   where tenant_id = v_tenant and id = p_works_order_id;$o$,
$n$  wo       erp.works_order%rowtype;
  v_before bigint;
  v_after  bigint;
begin
  -- Locked always (20260924700000), so a booking cannot race the close that
  -- settles the order.
  select * into wo from erp.works_order
   where tenant_id = v_tenant and id = p_works_order_id for update;$n$,
$o$  if p_minutes < 0 and exists ($o$,
$n$  -- A settled order's work in progress went to its variances when it closed
  -- (20260924700000). One released before the rules takes hours as it did.
  if wo.status = 'closed' and wo.posts_to_ledger and p_minutes <> 0 then
    raise exception 'CLOVEERP_WORKS_ORDER_SETTLED: % has closed and been settled in the books, and takes no more hours', wo.order_number
      using errcode = '23514', hint = 'Book the time to the order still open that it was worked for.';
  end if;
  if p_minutes < 0 and exists ($n$,
$o$  update erp.works_order_operation
     set actual_minutes = actual_minutes + p_minutes,$o$,
$n$  select erp.operation_labour_minor(o.actual_minutes, o.cost_rate_minor_per_hour) into v_before
    from erp.works_order_operation o
   where o.tenant_id = v_tenant and o.works_order_id = p_works_order_id and o.seq = p_operation_seq;

  update erp.works_order_operation
     set actual_minutes = actual_minutes + p_minutes,$n$,
$o$  if not found then
    raise exception 'CLOVEERP_UNKNOWN_OPERATION: % on %', p_operation_seq, wo.order_number
      using errcode = '23503';
  end if;$o$,
$n$  if not found then
    raise exception 'CLOVEERP_UNKNOWN_OPERATION: % on %', p_operation_seq, wo.order_number
      using errcode = '23503';
  end if;

  -- What the operation has absorbed now, less what it had: posted, so the sum
  -- of the postings is always what the variance reads, rounding and all
  -- (20260924700000).
  select erp.operation_labour_minor(o.actual_minutes, o.cost_rate_minor_per_hour) into v_after
    from erp.works_order_operation o
   where o.tenant_id = v_tenant and o.works_order_id = p_works_order_id and o.seq = p_operation_seq;
  perform erp.post_works_order_finance(p_works_order_id, 'works_order_labour', v_after - v_before);$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$patch6$;

-- Close settles what the order holds, and refuses if the books and the
-- variance disagree.
do $patch7$
declare
  v_sig  constant text := 'erp.close_works_order(uuid)';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
$o$  v_var    jsonb;
begin$o$,
$n$  v_var    jsonb;
  v_wip    bigint;
  v_held   bigint;
  v_lev    bigint;
  v_settle uuid;
begin$n$,
$o$  select jsonb_agg(to_jsonb(v)) into v_var
    from erp.works_order_variance(p_works_order_id) v;
$o$,
$n$  select jsonb_agg(to_jsonb(v)), coalesce(sum(v.variance_minor), 0)::bigint,
         coalesce(sum(v.variance_minor) filter (where v.kind = 'labour'), 0)::bigint
    into v_var, v_held, v_lev
    from erp.works_order_variance(p_works_order_id) v;

  -- Settled (20260924700000): what the order still holds in work in progress
  -- goes to the labour efficiency variance, as far as the labour line says,
  -- and the rest to material usage. The books and the variance must say the
  -- same thing, or the settlement would post one figure and report another.
  if wo.posts_to_ledger then
    v_wip := erp.works_order_wip(p_works_order_id);
    if v_wip <> v_held then
      raise exception 'CLOVEERP_WORKS_ORDER_WIP_DISAGREES: % holds % in work in progress in the books and % by its variance',
        wo.order_number, v_wip, v_held
        using errcode = '23514',
              hint = 'Something posted to the order other than its issues, hours and receipts. Reverse that journal, then close the order.';
    end if;
    v_settle := erp.post_works_order_finance(p_works_order_id, 'works_order_settlement', v_wip, null,
                  jsonb_build_object('labour_efficiency_variance', v_lev));
  end if;
$n$,
$o$          jsonb_build_object('variance', v_var), erp.current_principal_id());$o$,
$n$          jsonb_strip_nulls(jsonb_build_object('variance', v_var, 'settled_by', v_settle,
                                               'posts_to_ledger', wo.posts_to_ledger)),
          erp.current_principal_id());$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$patch7$;

-- A cancelled order is never settled, so it may hold nothing.
do $patch8$
declare
  v_sig  constant text := 'erp.cancel_works_order(uuid,text)';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
$o$  -- Its own commitment, and, for an order raised before the lifecycle, one$o$,
$n$  -- Nothing left in the books (20260924700000). Hours booked and taken back
  -- off net to nothing, and nothing issued is cancellable at all.
  if wo.posts_to_ledger and erp.works_order_wip(p_works_order_id) <> 0 then
    raise exception 'CLOVEERP_WORKS_ORDER_WIP_REMAINS: % still holds % in work in progress',
      wo.order_number, erp.works_order_wip(p_works_order_id)
      using errcode = '23514',
            hint = 'Return what was issued to it and take its hours back off, or close it instead.';
  end if;

  -- Its own commitment, and, for an order raised before the lifecycle, one$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$patch8$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C1. The installer ships the rules, and the accounts as their purposes say
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.configure_production(p_issue_method erp.issue_method default 'backflush'::erp.issue_method)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_entity uuid;
  v_entity_code text;
  v_cs     uuid;
  v_rule   jsonb;
  v_items  jsonb;
begin
  perform erp.authorise('administration.configure', null, null, null,
                        'works_order', null);

  select e.id, e.code into v_entity, v_entity_code from erp.entity e
   where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;

  -- Production posts what it consumes and makes (20260924700000), and a
  -- company without a ledger has nowhere to post it.
  if not exists (select 1 from erp.ledger l
                  where l.tenant_id = v_tenant and l.entity_id = v_entity
                    and l.is_primary and l.status = 'active') then
    raise exception 'CLOVEERP_PRODUCTION_NEEDS_A_LEDGER: % has no ledger for production to post to', coalesce(v_entity_code, 'the organisation')
      using errcode = '23514', hint = 'Install finance first, then production.';
  end if;

  -- The accounts, typed as their purposes say: work in progress is an asset,
  -- wherever it was an expense before (20260924700000). §8.1's chart is an
  -- alternative, and an alternative is only one if the installers stop
  -- insisting on theirs: with statutory_chart_8_1 on, the chart_8_1 pack ships
  -- the accounts, and only the one it did not always carry is added here.
  -- For every company with a ledger, as the upgrade plans them, not the first
  -- alone (found on review: a second company could not book an hour).
  insert into erp.account (
    tenant_id, entity_id, code, name, account_type, is_postable, currency, status)
  select v_tenant, e.id, erp.chart_account_code(cap.purpose), cap.name, cap.account_type, true,
         e.base_currency, 'active'
    from erp_ref.chart_account_purpose cap
    join erp.entity e on e.tenant_id = v_tenant and e.status = 'active'
                     and exists (select 1 from erp.ledger l
                                  where l.tenant_id = v_tenant and l.entity_id = e.id
                                    and l.is_primary and l.status = 'active')
   where cap.purpose in ('work_in_progress', 'material_usage_variance',
                         'labour_efficiency_variance', 'labour_absorbed')
     and (cap.purpose = 'labour_absorbed'
          or not erp.capability_on(v_tenant, 'statutory_chart_8_1', current_date))
  on conflict (tenant_id, entity_id, code) do update set status = 'active';

  update erp.account a
     set account_type = 'asset', updated_at = now()
   where a.tenant_id = v_tenant
     and a.code = erp.chart_account_code('work_in_progress')
     and a.account_type = 'expense'
     and not exists (select 1 from erp.journal_line jl where jl.account_id = a.id);

  v_items := jsonb_build_array(
      -- The sequence goes through the change set like everything else the
      -- module installs. It used to be written directly, above, which on a
      -- live organisation meant half the module landed before anybody had
      -- approved the other half.
      jsonb_build_object('kind','numbering_rule','key','works_order','payload',
        jsonb_build_object(
          'code','works_order', 'entity', v_entity_code, 'prefix','WO-',
          'pad_to', 6, 'reset_period','yearly', 'next_value', 1)),
      -- The lifecycle (20260924400000), from its one helper.
      erp.works_order_lifecycle_item(),
      jsonb_build_object('kind','config','key','production.issue_method','payload',
        jsonb_build_object(
          'config_type','production.issue_method',
          'value', to_jsonb(p_issue_method::text))));

  -- The four rules a works order posts by (20260924700000).
  for v_rule in select value from jsonb_array_elements(erp.works_order_posting_rules(false)) loop
    v_items := v_items || jsonb_build_array(
      jsonb_build_object('kind', 'posting_rule', 'key', v_rule ->> 'code', 'payload', v_rule));
  end loop;

  v_cs := erp.install_module_config(
    'production', 'Production',
    'How works orders consume material, how what they consume and make reaches the '
    'ledger, and how the difference between what they should have cost and what they '
    'did is accounted for.',
    v_items);

  return v_cs;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C2. Version 3: an installed organisation takes the rules as an upgrade
-- ─────────────────────────────────────────────────────────────────────────────

update erp_ref.module_installer
   set current_version = 3,
       description = description
         || ' Version 3 (20260924700000): a works order posts what it consumes, absorbs '
         || 'and makes, and settles to its variances when it closes.'
 where install_code = 'production' and current_version = 2;

insert into erp_ref.module_upgrade_item (install_code, to_version, object_kind, object_key, payload, seq)
select 'production', 3, 'posting_rule', r.value ->> 'code', r.value, 100 + 10 * (r.ordinality - 1)::integer
  from jsonb_array_elements(erp.works_order_posting_rules(true)) with ordinality r
on conflict (install_code, to_version, object_kind, object_key)
  do update set payload = excluded.payload, seq = excluded.seq;

insert into erp_ref.module_upgrade_account (install_code, to_version, purpose)
values ('production', 3, 'labour_absorbed')
on conflict do nothing;

do $register$
begin
  if (select current_version from erp_ref.module_installer
       where install_code = 'production') is distinct from 3 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: the production installer is not at version 3';
  end if;
  if (select count(*) from erp_ref.module_upgrade_item ui
       where ui.install_code = 'production' and ui.to_version = 3 and ui.object_kind = 'posting_rule'
         and ui.payload in (select value from jsonb_array_elements(erp.works_order_posting_rules(true))))
     <> jsonb_array_length(erp.works_order_posting_rules(true))
     or (select count(*) from erp_ref.module_upgrade_item ui
          where ui.install_code = 'production' and ui.to_version = 3)
     <> jsonb_array_length(erp.works_order_posting_rules(true)) then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: version 3 of production is not the posting rules it ships';
  end if;
end
$register$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C3. The register of reversal routes says how a works order is undone
-- ─────────────────────────────────────────────────────────────────────────────

do $route$
declare
  v_sig constant text := 'erp.document_reversal_route()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$'Nothing raises a works order in this product yet. When production installs a document type on this base type, it needs a route on this register before it can post.',$o$;
  v_new constant text := $n$'A works order is not a document: it posts on its own events, and each is undone by a door of its own. Return materials to stock (erp_return_works_order_issue), reverse finished goods taken in (erp_reverse_works_order_output), or book negative hours; close settles what is left. When production installs a document type on this base type, it needs a route on this register before it can post.',$n$;
  v_old2 constant text := $o$'erp_ref.document_type says a works order reaches the ledger, and no installer has ever made a tenant document type of it — erp.configure_production() ships the numbering rule, the work in progress account and the variance accounts, and no type.$o$;
  v_new2 constant text := $n$'erp_ref.document_type says a works order reaches the ledger, and no installer has ever made a tenant document type of it — erp.configure_production() ships the numbering rule, the accounts and the four works order posting rules (20260924700000), which post through erp.post_works_order_finance() on the order''s own events, and no type.$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % next action found % time(s)', v_sig, v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % rationale found % time(s)', v_sig, v_hits;
  end if;
  execute replace(replace(v_def, v_old, v_new), v_old2, v_new2);
end
$route$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C4. The account agrees with its orders
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.work_in_progress_reconciliation_report()
returns table(order_number text, status text, books_minor bigint, orders_minor bigint, difference_minor bigint)
language sql
stable
set search_path = ''
as $$
  -- An order that posts holds in the books what its variance says it holds
  -- while it is open, and nothing once it has closed or been cancelled.
  select x.order_number, x.status, x.books, x.held, x.books - x.held
    from (
      select w.order_number, w.status::text as status,
             erp.works_order_wip(w.id) as books,
             case when w.status in ('closed', 'cancelled') then 0
                  else (select coalesce(sum(v.variance_minor), 0)::bigint
                          from erp.works_order_variance(w.id) v) end as held
        from erp.works_order w
       where w.tenant_id = erp.current_tenant_id() and w.posts_to_ledger
    ) x
   where x.books <> x.held
   order by 1
$$;

revoke all on function erp.work_in_progress_reconciliation_report() from public, anon;

comment on function erp.work_in_progress_reconciliation_report() is
  'Every works order that posts whose work in progress in the books is not what it '
  'should hold: its variance while open, nothing once closed or cancelled '
  '(20260924700000).';

create or replace function erp.assert_work_in_progress_reconciles()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count  integer;
  v_detail text;
begin
  select count(*), string_agg(format('  %s (%s): books %s, the order %s, out by %s',
                                     r.order_number, r.status, r.books_minor, r.orders_minor,
                                     r.difference_minor), E'\n')
    into v_count, v_detail
    from erp.work_in_progress_reconciliation_report() r;

  if v_count > 0 then
    raise exception E'CLOVEERP_WORK_IN_PROGRESS_DOES_NOT_RECONCILE: % works order(s) hold what they should not\n%',
      v_count, v_detail;
  end if;

  return 'work in progress: every works order holds in the books what it should';
end;
$$;

revoke all on function erp.assert_work_in_progress_reconciles() from public, anon;

comment on function erp.assert_work_in_progress_reconciles() is
  'Every works order that posts holds in work in progress what its variance says while '
  'open, and nothing once closed or cancelled (20260924700000). Tenant-scoped: '
  'erp.assert_whole_database_reconciles() drives it for every organisation.';

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments, detail_function, detail_arguments,
   blurb, runs_in_ci, seq)
values ('work_in_progress_reconciles', 'Work in progress', 'assertion', 'tenant', 'erp',
        'assert_work_in_progress_reconciles', '', 'work_in_progress_reconciliation_report', '',
        'Every works order holds in work in progress what its variance says, and nothing once it has closed.',
        false, 43)
on conflict (code) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- C5. What production has already consumed and made without posting
--
-- Said, not put right. The difference between the inventory account and the
-- valuation, for organisations that have made anything, is the operator's to
-- true up after their orders close; supabase/ops is where that is written.
-- ─────────────────────────────────────────────────────────────────────────────

do $legacy$
declare
  v_tenants integer;
  v_orders  integer;
begin
  select count(distinct w.tenant_id), count(*) into v_tenants, v_orders
    from erp.works_order w
   where w.status not in ('draft', 'planned');
  raise notice 'production: % works order(s) in % organisation(s) were released before they posted, and carry on as they did',
    v_orders, v_tenants;
end
$legacy$;

-- ─────────────────────────────────────────────────────────────────────────────
-- D1. The proof: erp_test.production_settlement_suite
-- ─────────────────────────────────────────────────────────────────────────────

-- What an account holds in the suite's organisation, debit positive.
create or replace function erp_test.account_balance_minor(p_code text)
returns bigint
language sql
stable
set search_path = ''
as $$
  select coalesce(sum(jl.base_debit_minor - jl.base_credit_minor), 0)::bigint
    from erp.journal_line jl
    join erp.journal j on j.id = jl.journal_id and j.status = 'posted'
    join erp.account a on a.id = jl.account_id
   where jl.tenant_id = erp.current_tenant_id() and a.code = p_code
$$;

revoke all on function erp_test.account_balance_minor(text) from public, anon;

comment on function erp_test.account_balance_minor(text) is
  'A suite''s view of one account in its own organisation: posted debits less credits (20260924700000).';

create or replace function erp_test.production_settlement_suite()
 returns table(case_name text, passed boolean, detail text)
 language plpgsql
 set search_path to ''
as $function$
declare
  v_hex   text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1      uuid := gen_random_uuid();
  a2      uuid := gen_random_uuid();
  r       record;
  res     jsonb;
  v_tok   text;
  v_second uuid;
  csf uuid; csp uuid; csi uuid; csr uuid;
  v_uom uuid; v_site uuid; v_recv uuid; v_sup uuid;
  v_fg uuid; v_comp uuid; v_bom uuid; v_rout uuid; v_grn uuid;
  v_wo uuid; v_wo2 uuid; v_wo3 uuid; v_wo4 uuid; v_wo5 uuid; v_wo6 uuid;
  v_e2 uuid; v_cs uuid; v_rule jsonb; v_b5100 bigint;
  v_issue bigint; v_out2 bigint; v_back bigint;
  v_wip0 bigint; v_inv0 bigint; v_lab0 bigint;
  v_lev bigint; v_muv bigint; v_j bigint;
  v_err text; v_err2 text; v_err3 text;
  v_ok boolean;
begin
  -- 1. The rules ship with the installer and balance.
  return query select 'the four rules name a purpose each for an upgrade to resolve, and balance',
    jsonb_array_length(erp.works_order_posting_rules(true)) = 4
    and not exists (select 1 from jsonb_array_elements(erp.works_order_posting_rules(true)) x,
                                  jsonb_array_elements(x.value -> 'posting_lines') l
                     where jsonb_typeof(l.value -> 'account') <> 'object'),
    (select string_agg(x.value ->> 'code', ', ') from jsonb_array_elements(erp.works_order_posting_rules(true)) x);

  begin
    select * into r from erp.provision_tenant(
      'zz-wos-' || v_hex, 'Works order settlement suite',
      'a@zz-wos-' || v_hex || '.test', 'Suite Admin');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    res := public.erp_invite_principal('second@zz-wos-' || v_hex || '.test', 'Second Admin');
    v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
    perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');

    -- 2. No ledger, no production.
    begin perform erp.configure_production('manual'); v_err := 'configured';
    exception when others then v_err := left(sqlerrm, 160); end;
    return query select 'production is not installed for a company with no ledger to post to',
      v_err like 'CLOVEERP_PRODUCTION_NEEDS_A_LEDGER:%', v_err;

    csf := erp.configure_finance();
    csp := erp.configure_procurement(100000000);
    csi := erp.configure_inventory('average');
    csr := erp.configure_production('manual');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok);
    perform erp.approve_change_set(csf); perform erp.promote_change_set(csf);
    perform erp.approve_change_set(csp); perform erp.promote_change_set(csp);
    perform erp.approve_change_set(csi); perform erp.promote_change_set(csi);
    perform erp.approve_change_set(csr); perform erp.promote_change_set(csr);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    -- 3. What the installer set up.
    v_ok := true;
    for v_err in select pr.code from erp.posting_rule pr
                  where pr.tenant_id = r.tenant_id and pr.status = 'active' and pr.code like 'works_order_%' loop
      begin
        perform erp.assert_posting_rule_balances(v_err,
          (select max(pr.version) from erp.posting_rule pr where pr.tenant_id = r.tenant_id and pr.code = v_err));
      exception when others then v_ok := false;
      end;
    end loop;
    return query select 'the installer ships the four rules, labour absorbed as an expense and work in progress as an asset',
      v_ok
      and (select count(*) from erp.posting_rule pr
            where pr.tenant_id = r.tenant_id and pr.status = 'active' and pr.code like 'works_order_%') = 4
      and exists (select 1 from erp.account a where a.tenant_id = r.tenant_id and a.code = '5200'
                     and a.name = 'Labour absorbed' and a.account_type = 'expense')
      and exists (select 1 from erp.account a where a.tenant_id = r.tenant_id and a.code = '5100'
                     and a.account_type = 'asset'),
      (select string_agg(format('%s %s', a.code, a.account_type), ', ' order by a.code)
         from erp.account a where a.tenant_id = r.tenant_id and a.code in ('5100', '5200', '9200', '9300'));

    -- 4. An organisation on version 2 takes the rules as an upgrade.
    update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;
    update erp.module_installation i set installer_version = 2
     where i.tenant_id = r.tenant_id and i.install_code = 'production';
    update erp.posting_rule pr set status = 'withdrawn'
     where pr.tenant_id = r.tenant_id and pr.code like 'works_order_%' and pr.status = 'active';
    select count(*) into v_j from erp.plan_module_upgrade('production') p where p.object_kind = 'posting_rule';
    res := erp.upgrade_module_configuration('production');
    return query select 'an organisation on version 2 is planned the four rules, and takes them',
      v_j = 4 and (res ->> 'promoted')::boolean
      and (select count(*) from erp.posting_rule pr
            where pr.tenant_id = r.tenant_id and pr.status = 'active' and pr.code like 'works_order_%') = 4
      and (select i.installer_version from erp.module_installation i
            where i.tenant_id = r.tenant_id and i.install_code = 'production') = 3,
      format('%s planned; %s', v_j, res::text);

    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'production', 'active') returning id into v_site;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (r.tenant_id, v_site, 'RECV', 'Receiving', 'receiving', 'active') returning id into v_recv;
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'SUP', 'Supplier', 'active') returning id into v_sup;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'FG', 'Finished good', v_uom, 'active') returning id into v_fg;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'C1', 'Component', v_uom, 'active') returning id into v_comp;
    insert into erp.bom (tenant_id, code, item_id, site_id, version, name,
                         output_quantity, yield_factor, status, effective_from)
    values (r.tenant_id, 'FG-1', v_fg, v_site, 1, 'Finished good', 1, 1, 'active', current_date - 1)
    returning id into v_bom;
    insert into erp.bom_line (tenant_id, bom_id, seq, component_item_id, quantity, uom_id, scrap_factor, is_phantom)
    values (r.tenant_id, v_bom, 10, v_comp, 1, v_uom, 0, false);
    insert into erp.routing (tenant_id, code, item_id, site_id, version, name, status, effective_from)
    values (r.tenant_id, 'FG-R1', v_fg, v_site, 1, 'Assemble', 'active', current_date - 1)
    returning id into v_rout;
    -- Ten minutes to set up and one a unit, at sixty an hour: a hundred a minute.
    insert into erp.routing_operation (
      tenant_id, routing_id, seq, code, name, work_centre_code,
      setup_minutes, run_minutes_per_unit, cost_rate_minor_per_hour)
    values (r.tenant_id, v_rout, 10, 'ASM', 'Assembly', 'WC1', 10, 1, 6000);

    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_comp, 100, 100, 'component');
    perform erp.transition_document(v_grn, 'post');

    v_inv0 := erp_test.account_balance_minor('1200');
    v_wip0 := erp_test.account_balance_minor('5100');
    v_lab0 := erp_test.account_balance_minor('5200');

    -- 5. Released with the rules in force, the order posts.
    v_wo := erp.raise_works_order(v_fg, v_site, 10);
    perform erp.release_works_order(v_wo);
    return query select 'an order released with the rules in force posts, and its release says so',
      (select wo.posts_to_ledger from erp.works_order wo where wo.id = v_wo)
      and (select (pe.detail ->> 'posts_to_ledger')::boolean from erp.production_event pe
            where pe.works_order_id = v_wo and pe.event_kind = 'released'),
      (select pe.detail::text from erp.production_event pe
        where pe.works_order_id = v_wo and pe.event_kind = 'released');

    -- 6. An issue: work in progress up, inventory down, by the movement's cost.
    v_issue := erp.issue_to_works_order(v_wo, v_comp, 10);
    return query select 'an issue moves its exact cost from inventory into work in progress, with the component in the inventory detail',
      erp_test.account_balance_minor('5100') - v_wip0 = 1000
      and erp_test.account_balance_minor('1200') - v_inv0 = -1000
      and (select m.cost_minor from erp.stock_movement m where m.id = v_issue) = 1000
      and exists (select 1 from erp.subledger_item s
                   where s.tenant_id = r.tenant_id and s.item_id = v_comp and s.credit_minor = 1000)
      and erp.works_order_wip(v_wo) = 1000,
      format('work in progress %s, inventory %s', erp_test.account_balance_minor('5100') - v_wip0,
             erp_test.account_balance_minor('1200') - v_inv0);

    -- 7. Hours, and hours taken back off.
    perform erp.book_operation_time(v_wo, 10, 30, 0, 0);
    perform erp.book_operation_time(v_wo, 10, -5, 0, 0);
    return query select 'hours booked absorb labour at the routing''s rate, and hours taken off give it back',
      erp_test.account_balance_minor('5200') - v_lab0 = -2500
      and erp.works_order_wip(v_wo) = 1000 + 2500,
      format('labour absorbed %s, the order holds %s', erp_test.account_balance_minor('5200') - v_lab0,
             erp.works_order_wip(v_wo));

    -- 8. Finished goods, at the order's standard.
    perform erp.receive_works_order_output(v_wo, 4, null, v_recv);
    perform erp.receive_works_order_output(v_wo, 6, null, v_recv);
    select m.id into v_out2 from erp.stock_movement m
     where m.works_order_id = v_wo and m.movement_type = 'production_output' order by m.id desc limit 1;
    return query select 'finished goods move from work in progress into inventory at three hundred a unit',
      erp.works_order_wip(v_wo) = 3500 - 3000
      and erp_test.account_balance_minor('1200') - v_inv0 = -1000 + 3000,
      format('the order holds %s, inventory moved %s', erp.works_order_wip(v_wo),
             erp_test.account_balance_minor('1200') - v_inv0);

    -- 9. The books agree with the stock, the detail and the order.
    begin
      perform erp.assert_inventory_reconciles();
      perform erp.assert_subledger_reconciles();
      perform erp.assert_work_in_progress_reconciles();
      perform erp.assert_trial_balance_balances();
      v_err := 'agree';
    exception when others then v_err := left(sqlerrm, 300); end;
    return query select 'the inventory account agrees with the valuation, its detail and the order with its variance, while it runs',
      v_err = 'agree', v_err;

    -- 10. Undone: finished goods back out, a component back in.
    v_back := public.erp_reverse_works_order_output(v_out2, 'Counted twice at the line');
    perform erp.issue_to_works_order(v_wo, v_comp, 2);
    select m.id into v_issue from erp.stock_movement m
     where m.works_order_id = v_wo and m.movement_type = 'production_issue' and not m.is_reversal
     order by m.id desc limit 1;
    perform public.erp_return_works_order_issue(v_issue, 'Two too many were issued');
    begin
      perform erp.assert_inventory_reconciles();
      perform erp.assert_subledger_reconciles();
      perform erp.assert_work_in_progress_reconciles();
      v_err := 'agree';
    exception when others then v_err := left(sqlerrm, 300); end;
    return query select 'a reversal and a return post back what they undo, and the books still agree',
      v_err = 'agree' and erp.works_order_wip(v_wo) = 500 + 1800,
      format('%s; the order holds %s', v_err, erp.works_order_wip(v_wo));

    -- 11. Closed short at four of ten, settled.
    select v.variance_minor into v_lev from erp.works_order_variance(v_wo) v where v.kind = 'labour';
    res := erp.close_works_order(v_wo);
    v_muv := erp_test.account_balance_minor('9200');
    return query select 'close settles what the order held: labour against its standard, and the rest to material usage',
      erp.works_order_wip(v_wo) = 0
      -- 25 minutes against 14 allowed for 4 of 10; 1000 issued against 400.
      and v_lev = 2500 - 800
      and erp_test.account_balance_minor('9300') = v_lev
      and v_muv = 2300 - v_lev
      and exists (select 1 from erp.production_event pe
                   where pe.works_order_id = v_wo and pe.event_kind = 'closed'
                     and pe.detail ? 'settled_by'),
      format('labour %s, material usage %s, the order holds %s', erp_test.account_balance_minor('9300'),
             v_muv, erp.works_order_wip(v_wo));

    -- 12. A settled order takes no more hours.
    begin perform erp.book_operation_time(v_wo, 10, 5, 0, 0); v_err := 'booked';
    exception when others then v_err := left(sqlerrm, 160); end;
    begin perform erp.book_operation_time(v_wo, 10, -5, 0, 0); v_err2 := 'booked';
    exception when others then v_err2 := left(sqlerrm, 160); end;
    return query select 'an order closed and settled takes no more hours, on or off',
      v_err like 'CLOVEERP_WORKS_ORDER_SETTLED:%' and v_err2 like 'CLOVEERP_WORKS_ORDER_FINISHED:%',
      format('%s | %s', v_err, v_err2);

    -- 13. Something on the order that the order did not raise.
    v_wo2 := erp.raise_works_order(v_fg, v_site, 5);
    perform erp.release_works_order(v_wo2);
    perform erp.issue_to_works_order(v_wo2, v_comp, 5);
    perform erp.post_works_order_finance(v_wo2, 'works_order_labour', 700);
    begin perform erp.assert_work_in_progress_reconciles(); v_err := 'agree';
    exception when others then v_err := left(sqlerrm, 200); end;
    begin perform erp.close_works_order(v_wo2); v_err2 := 'closed';
    exception when others then v_err2 := left(sqlerrm, 200); end;
    return query select 'an order whose books and variance disagree is named, and is not closed on the wrong figure',
      v_err like 'CLOVEERP_WORK_IN_PROGRESS_DOES_NOT_RECONCILE:%' and v_err2 like 'CLOVEERP_WORKS_ORDER_WIP_DISAGREES:%'
      and (select wo.status = 'in_progress' from erp.works_order wo where wo.id = v_wo2),
      format('%s | %s', v_err, v_err2);
    perform erp.post_works_order_finance(v_wo2, 'works_order_labour', -700);
    perform erp.close_works_order(v_wo2);

    -- 14. A cancelled order holds nothing.
    v_wo3 := erp.raise_works_order(v_fg, v_site, 5);
    perform erp.release_works_order(v_wo3);
    perform erp.book_operation_time(v_wo3, 10, 12, 0, 0);
    perform erp.book_operation_time(v_wo3, 10, -12, 0, 0);
    perform erp.post_works_order_finance(v_wo3, 'works_order_labour', 100);
    begin perform erp.cancel_works_order(v_wo3, 'Not needed'); v_err := 'cancelled';
    exception when others then v_err := left(sqlerrm, 160); end;
    perform erp.post_works_order_finance(v_wo3, 'works_order_labour', -100);
    perform erp.cancel_works_order(v_wo3, 'Not needed');
    return query select 'an order is cancelled only once its hours net to nothing and it holds nothing',
      v_err like 'CLOVEERP_WORKS_ORDER_WIP_REMAINS:%'
      and (select wo.status = 'cancelled' from erp.works_order wo where wo.id = v_wo3)
      and erp.works_order_wip(v_wo3) = 0,
      v_err;

    -- 15. Made in full and closed.
    v_wo5 := erp.raise_works_order(v_fg, v_site, 10);
    perform erp.release_works_order(v_wo5);
    perform erp.issue_to_works_order(v_wo5, v_comp, 11);
    perform erp.book_operation_time(v_wo5, 10, 20, 0, 0);
    perform erp.receive_works_order_output(v_wo5, 10, null, v_recv);
    v_lev := erp_test.account_balance_minor('9300');
    v_muv := erp_test.account_balance_minor('9200');
    perform erp.close_works_order(v_wo5);
    return query select 'an order made in full on its hours settles one extra component to material usage and nothing to labour',
      erp.works_order_wip(v_wo5) = 0
      and erp_test.account_balance_minor('9300') - v_lev = 0
      and erp_test.account_balance_minor('9200') - v_muv = 100,
      format('labour %s, material usage %s', erp_test.account_balance_minor('9300') - v_lev,
             erp_test.account_balance_minor('9200') - v_muv);

    -- 16. A company without every account the rules name does not post, so
    -- its shop floor is not refused (found on review).
    v_e2 := erp.create_entity('CO2', 'Second company', null, null, null);
    v_cs := erp.configure_finance(null, null, v_e2);
    if (select cs.status::text from erp.change_set cs where cs.id = v_cs) <> 'promoted' then
      perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
      perform erp.approve_change_set(v_cs); perform erp.promote_change_set(v_cs);
      perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    end if;
    v_ok := erp.production_posts_to_ledger(v_e2, current_date);
    insert into erp.account (tenant_id, entity_id, code, name, account_type, is_postable, currency, status)
    select r.tenant_id, v_e2, '5200', 'Labour absorbed', 'expense', true, e.base_currency, 'active'
      from erp.entity e where e.id = v_e2
    on conflict (tenant_id, entity_id, code) do nothing;
    return query select 'a company that lacks an account the rules name releases orders that do not post, until it has it',
      not v_ok and erp.production_posts_to_ledger(v_e2, current_date)
      and erp.production_posts_to_ledger(r.entity_id, current_date),
      format('before %s, after %s', v_ok, erp.production_posts_to_ledger(v_e2, current_date));

    -- 17. The rules repointed while an order is on the floor: what it holds is
    -- found where each posting put it, and settled from there (found on
    -- review).
    v_b5100 := erp_test.account_balance_minor('5100');
    v_wo6 := erp.raise_works_order(v_fg, v_site, 5);
    perform erp.release_works_order(v_wo6);
    perform erp.issue_to_works_order(v_wo6, v_comp, 5);
    insert into erp.account (tenant_id, entity_id, code, name, account_type, is_postable, currency, status)
    select r.tenant_id, r.entity_id, '5110', 'Work in progress, line two', 'asset', true, e.base_currency, 'active'
      from erp.entity e where e.id = r.entity_id;
    v_cs := erp.create_change_set('wos-repoint-' || v_hex, 'Work in progress repointed', 'The suite repoints its rules.');
    for v_rule in select value from jsonb_array_elements(erp.works_order_posting_rules(false)) loop
      perform erp.add_change_set_item(v_cs, 'posting_rule', v_rule ->> 'code',
        replace(v_rule::text, '"5100"', '"5110"')::jsonb, 'upsert', null, 'repointed');
    end loop;
    perform erp.submit_change_set(v_cs);
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.approve_change_set(v_cs); perform erp.promote_change_set(v_cs);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.book_operation_time(v_wo6, 10, 10, 0, 0);
    v_j := erp.works_order_wip(v_wo6);
    perform erp.close_works_order(v_wo6);
    return query select 'an order whose rules were repointed mid-way holds what it put on each account, and settles each',
      v_j = 500 + 1000
      and erp.works_order_wip(v_wo6) = 0
      and erp_test.account_balance_minor('5100') = v_b5100
      and erp_test.account_balance_minor('5110') = 0,
      format('held %s; 5100 moved %s, 5110 holds %s', v_j, erp_test.account_balance_minor('5100') - v_b5100,
             erp_test.account_balance_minor('5110'));

    -- 18. The organisation's books, every order that posts settled or
    -- cancelled. The per-organisation checks the whole-database run drives,
    -- less the journal numbers, which are given at commit.
    v_ok := true;
    begin
      perform erp.assert_inventory_reconciles();
      perform erp.assert_subledger_reconciles();
      perform erp.assert_work_in_progress_reconciles();
      perform erp.assert_trial_balance_balances();
      for v_err in select pr.code || ':' || pr.version from erp.posting_rule pr
                    where pr.tenant_id = r.tenant_id and pr.status = 'active' loop
        perform erp.assert_posting_rule_balances(split_part(v_err, ':', 1), split_part(v_err, ':', 2)::integer);
      end loop;
      v_err := 'agree';
    exception when others then v_err := left(sqlerrm, 400); end;
    return query select 'the organisation''s books reconcile, work in progress included, once every order is settled',
      v_err = 'agree'
      and erp_test.account_balance_minor('5100') = v_wip0
      and erp_test.account_balance_minor('1200') + erp_test.account_balance_minor('5200')
          + erp_test.account_balance_minor('9200') + erp_test.account_balance_minor('9300') = v_inv0 + v_lab0,
      format('%s; work in progress %s', v_err, erp_test.account_balance_minor('5100') - v_wip0);

    -- 19. An order released before the rules: carries on as it did. Last,
    -- because what it consumes and makes never reaches the books.
    v_wo4 := erp.raise_works_order(v_fg, v_site, 5);
    perform erp.release_works_order(v_wo4);
    update erp.works_order set posts_to_ledger = false where id = v_wo4;
    select count(*) into v_j from erp.journal j where j.tenant_id = r.tenant_id;
    perform erp.issue_to_works_order(v_wo4, v_comp, 5);
    perform erp.book_operation_time(v_wo4, 10, 15, 0, 0);
    perform erp.receive_works_order_output(v_wo4, 5, null, v_recv);
    perform erp.close_works_order(v_wo4);
    perform erp.book_operation_time(v_wo4, 10, 1, 0, 0);
    return query select 'an order released before the rules posts nothing, closes as it did, and still takes hours',
      (select count(*) from erp.journal j where j.tenant_id = r.tenant_id) = v_j
      and (select wo.status = 'closed' from erp.works_order wo where wo.id = v_wo4),
      format('%s journal(s) raised', (select count(*) from erp.journal j where j.tenant_id = r.tenant_id) - v_j);

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      case_name := 'the suite ran to its end';
      passed := false; detail := left(sqlerrm, 300);
      return next;
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant t where t.code = 'zz-wos-' || v_hex);
  detail := 'the organisation, its orders and their journals rolled back';
  return next;
end;
$function$;

revoke all on function erp_test.production_settlement_suite() from public, anon;

create or replace function erp_test.assert_production_settlement_suite()
returns void
language plpgsql
security definer
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
    from erp_test.production_settlement_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_PRODUCTION_SETTLEMENT_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A works order that moves stock without the books, holds in work in progress what its variance does not say, or closes without settling, is the case that failed. Read it.';
  end if;
  if v_total <> 20 then
    raise exception 'CLOVEERP_PRODUCTION_SETTLEMENT_SUITE_SHRANK: % case(s), expected 20', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
end;
$$;

revoke all on function erp_test.assert_production_settlement_suite() from public, anon;

comment on function erp_test.assert_production_settlement_suite() is
  'A works order posts what it consumes, absorbs and makes at the figures the valuation '
  'and its variance hold, settles to its variances when it closes, and leaves the books '
  'reconciled (20260924700000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- D2. The production suite's milestone cases book on an order that took no
-- settlement
--
-- They are about where a routing asks for time, and they book on the suite's
-- one order after it has closed. Closed and settled, it now takes no hours
-- (20260924700000); as one released before the rules, it takes them as every
-- order did, which is the case those three were written for.
-- ─────────────────────────────────────────────────────────────────────────────

do $milestones$
declare
  v_sig constant text := 'erp_test.production_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  -- A second operation on the order, so there is somewhere that is not a
  -- milestone to try booking at (20260922220000).$o$;
  v_new constant text := $n$  -- The order has closed and been settled, and takes no more hours
  -- (20260924700000). What follows is about the routing, so the order books as
  -- one released before the rules, which takes hours as every order did.
  update erp.works_order set posts_to_ledger = false where id = v_wo;

  -- A second operation on the order, so there is somewhere that is not a
  -- milestone to try booking at (20260922220000).$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % milestone anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$milestones$;

-- The §8.1 pack carries the labour absorbed account and its determination
-- (20260924700000): twenty-one of each, where there were twenty.
do $chart_suite$
declare
  v_sig constant text := 'erp_test.chart_alternative_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  return query select 'the pack brings the whole chart',
    (select count(*) from erp.account a where a.tenant_id = v_t) = 20,$o$,
    $n$  return query select 'the pack brings the whole chart',
    (select count(*) from erp.account a where a.tenant_id = v_t) = 21,$n$,
    $o$  return query select 'the installers create no chart of their own',
    (select count(*) from erp.account a where a.tenant_id = v_t) = 20,$o$,
    $n$  return query select 'the installers create no chart of their own',
    (select count(*) from erp.account a where a.tenant_id = v_t) = 21,$n$,
    $o$  return query select 'erp.determine_account() has something to answer from',
    n = 20,$o$,
    $n$  return query select 'erp.determine_account() has something to answer from',
    n = 21,$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$chart_suite$;

-- Three more counts this moves (20260924700000): a twelfth per-organisation
-- assertion the whole-database run drives, which two suites count, and the §8.1 chart's twenty-first
-- account on the demonstration.
do $pins$
declare
  v_sig  text;
  v_def  text;
  v_pairs text[];
  v_hits integer;
begin
  foreach v_sig in array array['erp_test.ageing_tie_suite()', 'erp_test.trial_balance_tie_suite()',
                               'erp_test.demo_chart_suite()'] loop
    v_def := pg_get_functiondef(v_sig::regprocedure);
    v_pairs := case v_sig
      when 'erp_test.ageing_tie_suite()' then array[
        $o$                  and d.function_name <> 'assert_whole_database_reconciles') = 11$o$,
        $n$                  and d.function_name <> 'assert_whole_database_reconciles') = 12$n$]
      when 'erp_test.trial_balance_tie_suite()' then array[
        $o$                  and d.function_name <> 'assert_whole_database_reconciles') = 11$o$,
        $n$                  and d.function_name <> 'assert_whole_database_reconciles') = 12$n$]
      else array[
        $o$        and (select count(*) from erp.account a where a.tenant_id = d.tenant_id) = 20$o$,
        $n$        and (select count(*) from erp.account a where a.tenant_id = d.tenant_id) = 21$n$,
        $o$              where a.tenant_id = d.tenant_id and e.code = 'ACME') = 20$o$,
        $n$              where a.tenant_id = d.tenant_id and e.code = 'ACME') = 21$n$]
    end;
    for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
      v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
      if v_hits <> 1 then
        raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
      end if;
      v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
    end loop;
    execute v_def;
  end loop;
end
$pins$;

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
