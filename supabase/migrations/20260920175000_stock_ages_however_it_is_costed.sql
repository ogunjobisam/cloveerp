set lock_timeout = '30s';

-- =============================================================================
-- 20260920175000  Stock ages however it is costed
-- -----------------------------------------------------------------------------
-- The Stock ageing report was empty for every organisation that does not cost
-- its stock first in, first out. The live demonstration's two ageing cards both
-- said "no aged stock" over months of trading. Found on 18 September by the
-- session working the friction log, while it worked out why
-- erp_test.stock_site_filter_suite() found no ageing at either depot. It was
-- not the filter.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- What was verified before anything was changed
--
--   * The report is erp.stock_ageing_report(), behind public.erp_stock_ageing(),
--     which the Stock screen draws twice: the "Stock ageing" chart and the
--     "Ageing" table. Both read only erp.stock_valuation_layer.
--
--   * erp.receive_cost() writes a layer only when erp.costing_method_for() says
--     fifo. Average cost keeps one running figure per product and site in
--     erp.item_cost, and so does standard cost. So the report was empty under
--     average AND standard, not only average: two methods out of three.
--
--   * Costing is not chosen per organisation. erp.costing_policy is narrowed by
--     product, product class and site, most specific first, over a default for
--     the organisation, and with no policy at all the answer is average. One
--     organisation can hold stock under all three methods at once. So whatever
--     replaces the layers has to be chosen position by position, never by
--     organisation.
--
--   * First in, first out is a real choice, not a dead branch. It is the third
--     answer to the onboarding interview's costing question (20260913100000),
--     and public.erp_configure_inventory() takes it as an argument. Nothing the
--     product seeds uses it: erp.ensure_demo_configuration() installs average,
--     the Configuration screen installs inventory with the default, which is
--     average, and the second fixture organisation (20260906090000) answers
--     standard. Whether any live organisation chose it is a question for the
--     live database, which a migration cannot see before it runs.
--
--   * A second report had the same dependency and nobody had said so.
--     public.erp_stock_provision(), the slow-moving stock provision on the
--     Finance screen, banded the layers and nothing else, so it too was empty
--     for every organisation at average or standard cost. Its empty sentence
--     then said "nothing is old enough to provide against", which was not the
--     question it had failed to answer.
--
--   * And the mirror image. erp.item_cost is never written for stock costed
--     first in, first out: erp.receive_cost(), erp.issue_cost() and
--     erp.transfer_cost() all return from the layer branch before touching it.
--     Nine routines read that table and nothing else — a count that finds
--     stock values the gain at a unit cost of nought, the margin check cannot
--     measure a price, the expiry horizon values expiring stock at nothing, and
--     four more. That is the same class, the other way round, and it is written
--     down below rather than fixed here.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- Which source, and why
--
-- Two were named: the movement ledger, and the history of erp.item_cost. There
-- is no history of erp.item_cost. It is one row per product and site, unique on
-- exactly that, updated in place on every receipt and every issue. And a
-- history of it would not help if there were one: an average is a blend, and a
-- blend does not know which of its receipts are still on the shelf. Nothing
-- about a running unit cost says how old the stock behind it is.
--
-- The movement ledger does know when stock arrived, for every method, because
-- every unit at a site came onto it by a movement. What it does not know under
-- average or standard cost is WHICH arrivals are still there, because an issue
-- at an average cost does not say which receipt it took. So the ageing assumes
-- what first in, first out would have done: the oldest went first, and what is
-- on hand is the latest arrivals, newest first, until they add up to it. That
-- is an assumption, and the report says so on every row.
--
-- An arrival is a movement whose to side is the company's own stock at that
-- site and whose from side is not — a receipt, an opening balance, a transfer
-- in, production output, a customer return, a count or an adjustment that
-- found stock, or stock the company has just taken on from a consignor. A
-- movement that was reversed never happened, and its reversal is not an
-- arrival either. A transfer in counts from the day it reached this site: that
-- is when this site started holding it.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- What the report now says, method by method
--
--   First in, first out   exactly what it said before. Each open layer is a
--                         receipt with its own date and its own cost; the band
--                         and the value are that receipt's. Aged by "the
--                         receipt it was costed from".
--
--   Average, standard     the latest arrivals that account for what is on hand,
--                         oldest assumed out first, and the valuation's own
--                         figure for the position shared across them by
--                         quantity — so the bands add up to the valuation to
--                         the unit and to the penny, and the value is at the
--                         current cost, not at what each receipt cost. Aged by
--                         "latest arrivals, oldest assumed out first".
--
-- Both reports read one source, erp.stock_on_hand_by_arrival(), so the ageing
-- and the provision cannot come to disagree about how old anything is. Stock
-- that no arrival accounts for — which the ledger's own arithmetic says cannot
-- happen — is shown undated rather than dropped or guessed at.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- So the class cannot come back
--
-- erp.conditional_store_register() names the stores some organisations never
-- fill, and for each one what answers for the rest. erp.assert_conditional_
-- stores_answer_otherwise() refuses any routine or view in the product schemas
-- that reads such a store and reads nothing that answers for the rest, unless
-- erp.conditional_store_allowance() says why. The ageing and the provision as
-- they read until today are refused by name in the suite: this check would
-- have caught both. The nine routines and one view that read only
-- erp.item_cost are in the allowance as KNOWN GAPS with what each gets wrong,
-- so the class is closed against the next one and the open ones are a list.
--
-- It is catalogue arithmetic. The raw source is filtered for the store's name
-- before any comment is stripped, so the cost is one substring search per
-- routine per store, and a view's reads come from pg_depend, not its text.
-- =============================================================================


-- ═════════════════════════════════════════════════════════════════════════════
-- 1. What is on hand, and when it arrived
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.stock_on_hand_by_arrival()
returns table (item_id uuid, site_id uuid, method erp.costing_method,
               arrived_at timestamptz, quantity numeric, value_minor numeric,
               aged_by text)
language plpgsql
stable
security invoker
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_tenant uuid := erp.current_tenant_id();
begin
  -- No organisation, nothing on hand: what the layer-only reports answered.
  if v_tenant is null then
    return;
  end if;

  return query
  with layered as materialized (
    -- Positions costed first in, first out. Their open layers are the answer,
    -- and it is exact: each layer is a receipt, with its own date and cost.
    select x.item_id, x.site_id
      from (select distinct l.item_id, l.site_id
              from erp.stock_valuation_layer l
             where l.tenant_id = v_tenant and l.remaining > 0) x
     where erp.costing_method_for(x.item_id, x.site_id) = 'fifo'
  ),
  held as materialized (
    -- Every other position the valuation values, at the figures it values it
    -- at, so what is shared out below adds up to the valuation by construction.
    select v.item_id, v.site_id, v.method, v.quantity as held,
           v.value_minor::numeric as held_value, e.party_id as company
      from erp.stock_valuation_report() v
      join erp.site s on s.id = v.site_id
      join erp.entity e on e.id = s.entity_id
     where v.method <> 'fifo'
       and v.quantity > 0
  ),
  arrived as (
    -- What brought stock onto the company's books at this site: its own stock
    -- on the to side, and on the from side nothing, or someone else's.
    select m.id, m.item_id, m.site_id, m.occurred_at, m.quantity
      from held h
      join erp.stock_movement m
        on m.tenant_id = v_tenant and m.item_id = h.item_id and m.site_id = h.site_id
     where m.to_location_id is not null
       and coalesce(m.to_owner_party_id, m.owner_party_id) = h.company
       and (m.from_location_id is null or m.owner_party_id <> h.company)
       and not m.is_reversal
       and not exists (select 1 from erp.stock_movement r
                        where r.tenant_id = v_tenant and r.reverses_movement_id = m.id)
  ),
  newest_first as (
    select a.item_id, a.site_id, a.occurred_at, a.quantity,
           sum(a.quantity) over (partition by a.item_id, a.site_id
                                 order by a.occurred_at desc, a.id desc
                                 rows between unbounded preceding and current row) as through
      from arrived a
  ),
  piece as (
    -- The oldest is assumed out first, so what is on hand is the latest
    -- arrivals, newest first, until they add up to it.
    select n.item_id, n.site_id, n.occurred_at as arrived_at,
           n.through - n.quantity as from_qty,
           least(n.through, h.held) as to_qty
      from newest_first n
      join held h on h.item_id = n.item_id and h.site_id = n.site_id
     where n.through - n.quantity < h.held
    union all
    -- Anything the arrivals do not account for is shown undated, not dropped
    -- and not guessed at. By the ledger's own arithmetic it never appears.
    select h.item_id, h.site_id, null::timestamptz,
           coalesce(c.covered, 0), h.held
      from held h
      left join (select n.item_id, n.site_id, max(n.through) as covered
                   from newest_first n
                  group by n.item_id, n.site_id) c
        on c.item_id = h.item_id and c.site_id = h.site_id
     where coalesce(c.covered, 0) < h.held
  )
  select p.item_id, p.site_id, h.method, p.arrived_at,
         p.to_qty - p.from_qty,
         -- The position's value shared by quantity and rounded cumulatively,
         -- so its pieces add up to the valuation's figure to the penny.
         round(h.held_value * p.to_qty / h.held) - round(h.held_value * p.from_qty / h.held),
         case when p.arrived_at is null then 'no arrival accounts for it'
              else 'latest arrivals, oldest assumed out first' end
    from piece p
    join held h on h.item_id = p.item_id and h.site_id = p.site_id
  union all
  select l.item_id, l.site_id, 'fifo'::erp.costing_method, l.received_at,
         l.remaining, l.remaining * l.unit_cost_minor,
         'the receipt it was costed from'
    from erp.stock_valuation_layer l
    join layered f on f.item_id = l.item_id and f.site_id is not distinct from l.site_id
   where l.tenant_id = v_tenant
     and l.remaining > 0;
end;
$$;

revoke all on function erp.stock_on_hand_by_arrival() from public, anon;

comment on function erp.stock_on_hand_by_arrival() is
  'What is on hand, piece by piece, with when each piece arrived and how that '
  'is known. Stock costed first in, first out: its open cost layers, exactly. '
  'Stock at average or standard cost: the latest arrivals in the movement '
  'ledger that account for what is on hand, oldest assumed out first, carrying '
  'the valuation''s own figure shared by quantity. The one source the stock '
  'ageing and the slow-moving provision read (20260920175000).';


-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The ageing reads it
--
-- Dropped and recreated: it gains a column, and CREATE OR REPLACE cannot change
-- a function's result. The signature does not change, so erp_ref.part5_capability
-- still resolves it, and public.erp_stock_ageing(uuid) passes the new column
-- through as it passes the others.
-- ═════════════════════════════════════════════════════════════════════════════

drop function if exists erp.stock_ageing_report();

create function erp.stock_ageing_report()
returns table (item_id uuid, item_code text, site_id uuid, site_code text,
               bucket text, quantity numeric, value_minor bigint, aged_by text)
language sql
stable
security invoker
set search_path = ''
as $$
  -- A balance has no age: it is a number updated this morning whether the
  -- stock arrived today or two years ago. So the age comes from what arrived,
  -- and each row says how it knows.
  select a.item_id, i.code, a.site_id, s.code,
         case
           when a.arrived_at is null                          then 'not dated'
           when a.arrived_at > now() - interval '30 days'  then '0-30'
           when a.arrived_at > now() - interval '90 days'  then '31-90'
           when a.arrived_at > now() - interval '180 days' then '91-180'
           when a.arrived_at > now() - interval '365 days' then '181-365'
           else '365+'
         end,
         sum(a.quantity),
         round(sum(a.value_minor))::bigint,
         a.aged_by
    from erp.stock_on_hand_by_arrival() a
    join erp.item i on i.id = a.item_id
    left join erp.site s on s.id = a.site_id
   group by 1, 2, 3, 4, 5, 8
   order by 2, 4, min(a.arrived_at) desc nulls last
$$;

comment on function erp.stock_ageing_report() is
  'Spec 5.2: ageing analysis, per product, site and age band, for stock under '
  'every costing method. First in, first out is aged by the receipt each unit '
  'was costed from; average and standard by the latest arrivals that account '
  'for what is on hand, oldest assumed out first, valued at the current cost. '
  'aged_by says which, on every row. Read the layers alone, and so answered '
  'nothing at average or standard cost, until 20260920175000.';


-- ═════════════════════════════════════════════════════════════════════════════
-- 3. So does the provision
--
-- The same bands and percentages as before, from the same source as the
-- ageing. The keys are those it answered with, and aged_by.
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function public.erp_stock_provision()
returns jsonb language sql stable security invoker set search_path to '' as $$
  -- One published policy, applied the same way every time: nothing is provided
  -- against in the first quarter of life, a quarter after six months, half
  -- after a year, and the whole value beyond that. Stock whose arrival cannot
  -- be dated is shown with no percentage rather than given one.
  select coalesce(jsonb_agg(x order by (x->>'provision_minor')::bigint desc nulls last), '[]'::jsonb) from (
    select jsonb_build_object(
             'item_id', a.item_id, 'item_code', i.code, 'item_name', i.name,
             'bucket', b.bucket, 'quantity', sum(a.quantity),
             'value_minor', round(sum(a.value_minor))::bigint,
             'provision_pct', b.pct,
             'provision_minor', round(sum(a.value_minor) * b.pct / 100.0)::bigint,
             'aged_by', a.aged_by) as x
      from erp.stock_on_hand_by_arrival() a
      join erp.item i on i.id = a.item_id
      cross join lateral (
        select case
                 when a.arrived_at is null then 'not dated'
                 when a.arrived_at > now() - interval '90 days'  then '0-90'
                 when a.arrived_at > now() - interval '180 days' then '91-180'
                 when a.arrived_at > now() - interval '365 days' then '181-365'
                 else '365+' end as bucket,
               case
                 when a.arrived_at is null then null::integer
                 when a.arrived_at > now() - interval '90 days'  then 0
                 when a.arrived_at > now() - interval '180 days' then 25
                 when a.arrived_at > now() - interval '365 days' then 50
                 else 100 end as pct) b
     group by a.item_id, i.code, i.name, b.bucket, b.pct, a.aged_by) t;
$$;

comment on function public.erp_stock_provision() is
  'The slow-moving stock provision: every product on hand in its age band, '
  'with the published percentage of its value provided against. Aged and '
  'valued from the same source as the stock ageing, for stock under every '
  'costing method; aged_by says how each row''s age is known.';


-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The words on the screen
--
-- Five, all in src/lib/modules.tsx: the two panels' new descriptions and empty
-- sentences, and the column that says how a row was aged.
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string on the stock ageing or the slow-moving provision, rendered through ui(). ' || v.why
  from (values
    ('How long stock has been here, by when it arrived. Stock costed first in, first out is aged by the receipt each unit was costed from. Stock at average or standard cost keeps no such record, so it is aged by the latest arrivals that make up what is on hand, oldest assumed out first.',
     'The Stock ageing table''s description. It says how the age is known for each costing method, because under average and standard cost it is an assumption and the screen should not imply otherwise.'),
    ('Nothing on hand to age. Stock appears here in its age band from the day it arrives.',
     'The Stock ageing table when nothing is on hand. It used to say nothing was old enough to band, which was never the reason.'),
    ('Aged by',
     'The column on the stock ageing and the provision that says how a row''s age is known: the receipt it was costed from, or the latest arrivals with the oldest assumed out first.'),
    ('One published policy: nothing under ninety days, a quarter to six months, half to a year, all of it beyond. Stock costed first in, first out is aged and valued by the receipts it was costed from; stock at average or standard cost by its latest arrivals, at its current cost.',
     'The slow-moving provision''s description, with how the age and the value are known for each costing method.'),
    ('Nothing on hand to provide against. Every product in stock appears here in its age band, including stock too new to need a provision.',
     'The slow-moving provision when nothing is on hand. It used to name a threshold the organisation set, and there is none: the policy is published and fixed.')
  ) as v(text, why)
on conflict (key, locale) do nothing;


-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The class: a store some organisations never fill is not read alone
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.conditional_store_register()
returns table (store text, filled_for text, answered_otherwise_by text[])
language sql
immutable
set search_path = ''
as $$
  select v.store, v.filled_for, v.answered_otherwise_by
    from (values
      ('erp.stock_valuation_layer'::text,
       'stock costed first in, first out'::text,
       array['erp.stock_movement', 'erp.item_cost']::text[]),
      ('erp.item_cost',
       'stock costed at average or at standard cost',
       array['erp.stock_valuation_layer'])
    ) as v(store, filled_for, answered_otherwise_by);
$$;

revoke all on function erp.conditional_store_register() from public, anon;

comment on function erp.conditional_store_register() is
  'The stores some organisations never fill, what fills them, and what answers '
  'for everything else. Read by erp.assert_conditional_stores_answer_otherwise(), '
  'which refuses a routine or view that reads one of them alone.';

create or replace function erp.conditional_store_allowance()
returns table (reader text, store text, known_gap boolean, rationale text)
language sql
immutable
set search_path = ''
as $$
  select v.reader, v.store, v.known_gap, v.rationale
    from (values
      ('erp.set_standard_cost'::text, 'erp.item_cost'::text, false,
       'By design. It sets the standard for a product costed at standard and '
       'refuses any other, and a product costed at standard always has its row '
       'here.'::text),
      ('erp.calculate_policy', 'erp.item_cost', true,
       'A KNOWN GAP as at 18 September 2026. The economic order quantity divides '
       'by the unit cost held here. A product costed first in, first out has '
       'none, so its order quantity comes back empty.'),
      ('erp.check_margin', 'erp.item_cost', true,
       'A KNOWN GAP as at 18 September 2026. Margin is measured against the unit '
       'cost held here. A product costed first in, first out has none, so every '
       'price for it fails the check as one that cannot be measured, rather than '
       'being measured against what its layers cost.'),
      ('erp.expiry_horizon_report', 'erp.item_cost', true,
       'A KNOWN GAP as at 18 September 2026. Expiring batches are valued at the '
       'unit cost held here, which is nought for stock costed first in, first '
       'out, so the expiry horizon values that stock at nothing.'),
      ('erp.post_count', 'erp.item_cost', true,
       'A KNOWN GAP as at 18 September 2026. A count that finds stock values the '
       'gain at the unit cost held here. For a product costed first in, first '
       'out that is nought: the found stock goes into a layer at no cost and '
       'nothing reaches the ledger.'),
      ('erp.post_stock_adjustment', 'erp.item_cost', true,
       'A KNOWN GAP as at 18 September 2026. The same for an adjustment document '
       'that finds stock: a product costed first in, first out is layered at no '
       'cost and nothing reaches the ledger.'),
      ('erp.release_works_order', 'erp.item_cost', true,
       'A KNOWN GAP as at 18 September 2026. The standard material cost frozen '
       'at release adds each component at the unit cost held here, so a '
       'component costed first in, first out adds nought.'),
      ('erp.roll_up_standard_cost', 'erp.item_cost', true,
       'A KNOWN GAP as at 18 September 2026. A bought component''s standard is '
       'taken as the unit cost held here, which is nought for one costed first '
       'in, first out, so the roll-up understates what it is part of.'),
      ('erp.works_order_variance', 'erp.item_cost', true,
       'A KNOWN GAP as at 18 September 2026. Material and yield variances are '
       'priced at the unit cost held here, so for items costed first in, first '
       'out they are priced at nought.'),
      ('erp.stock_valuation', 'erp.item_cost', true,
       'A KNOWN GAP as at 18 September 2026. The view behind the Stock on hand '
       'and valuation report version prices each position at the unit cost held '
       'here, so stock costed first in, first out is valued at nought in it. The '
       'valuation the Stock screens read prices that stock from its layers.')
    ) as v(reader, store, known_gap, rationale);
$$;

revoke all on function erp.conditional_store_allowance() from public, anon;

comment on function erp.conditional_store_allowance() is
  'The routines and views allowed to read a conditional store alone, each with '
  'its reason: by design where it serves only the organisations that fill the '
  'store, and A KNOWN GAP where it does not and is not yet fixed. An allowance '
  'that no longer describes anything is refused, so a fixed gap has to leave '
  'the list.';

create or replace function erp.conditional_store_report()
returns table (reader text, store text, verdict text, finding text)
language sql
stable
set search_path = ''
as $$
  with register as materialized (
    select g.store, g.filled_for, g.answered_otherwise_by,
           to_regclass(g.store)::oid as relid
      from erp.conditional_store_register() g
  ),
  allowance as (
    select a.reader, a.store, a.known_gap
      from erp.conditional_store_allowance() a
  ),
  candidate as materialized (
    -- The raw source is searched first, for the store's name as written.
    -- erp.prosrc_code() only replaces comments with a space, so it cannot make
    -- a name appear that the raw text lacked (20260920010000), and comments are
    -- then stripped from the few bodies that name a store, not from all of them.
    select n.nspname || '.' || p.proname as reader, g.store, g.answered_otherwise_by,
           erp.prosrc_code(p.prosrc) as code
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      join register g on strpos(p.prosrc, g.store) > 0
     where n.nspname in ('erp', 'erp_ai', 'public')
       and p.prokind in ('f', 'p')
       -- The check's own registers name every store and read none.
       and not (n.nspname = 'erp'
                and (p.proname like 'conditional\_store\_%'
                     or p.proname = 'assert_conditional_stores_answer_otherwise'))
  ),
  routine_read as (
    select c.reader, c.store,
           bool_and(exists (select 1 from unnest(c.answered_otherwise_by) as o(alt)
                             where c.code ~ (replace(o.alt, '.', '\.') || '\M'))) as answers
      from candidate c
     where c.code ~ (replace(c.store, '.', '\.') || '\M')
     group by c.reader, c.store
  ),
  view_read as (
    -- A view says what it reads in the catalogue, so its text is not read.
    select distinct vn.nspname || '.' || vc.relname as reader, g.store,
           exists (select 1
                     from pg_catalog.pg_depend d2
                    where d2.classid = 'pg_catalog.pg_rewrite'::regclass
                      and d2.objid = rw.oid
                      and d2.refclassid = 'pg_catalog.pg_class'::regclass
                      and d2.refobjid in (select to_regclass(o.alt)::oid
                                            from unnest(g.answered_otherwise_by) as o(alt))) as answers
      from register g
      join pg_catalog.pg_depend d
        on d.refclassid = 'pg_catalog.pg_class'::regclass
       and d.refobjid = g.relid
       and d.classid = 'pg_catalog.pg_rewrite'::regclass
      join pg_catalog.pg_rewrite rw on rw.oid = d.objid
      join pg_catalog.pg_class vc on vc.oid = rw.ev_class
      join pg_catalog.pg_namespace vn on vn.oid = vc.relnamespace
     where vn.nspname in ('erp', 'erp_ai', 'public')
       and vc.relkind in ('v', 'm')
  ),
  found as (
    select r.reader, r.store, r.answers from routine_read r
    union all
    select v.reader, v.store, v.answers from view_read v
  )
  select f.reader, f.store,
         case when f.answers and a.reader is not null then 'stale'
              when f.answers then 'answers otherwise'
              when a.known_gap then 'known gap'
              when a.reader is not null then 'by design'
              else 'refused'
         end,
         case when f.answers and a.reader is not null then
                format('%s is allowed to read %s alone and no longer does, because it now reads what answers for the rest; take its allowance out',
                       f.reader, f.store)
              when not f.answers and a.reader is null then
                format('%s reads %s, which holds rows only for %s, and reads nothing that answers for the rest (%s)',
                       f.reader, f.store, g.filled_for,
                       array_to_string(g.answered_otherwise_by, ' or '))
         end
    from found f
    join register g on g.store = f.store
    left join allowance a on a.reader = f.reader and a.store = f.store
  union all
  select a.reader, a.store, 'stale',
         format('%s is allowed to read %s alone and does not read it at all, so the allowance describes nothing; take it out',
                a.reader, a.store)
    from allowance a
   where not exists (select 1 from found f where f.reader = a.reader and f.store = a.store)
  union all
  select null::text, g.store, 'stale',
         format('the register names %s, and it, or something it says answers for the rest, does not exist',
                g.store)
    from register g
   where g.relid is null
      or exists (select 1 from unnest(g.answered_otherwise_by) as o(alt)
                  where to_regclass(o.alt) is null)
  union all
  select null::text, g.store, 'blind',
         format('nothing reads %s at all, which cannot be true of a store the product writes; the search has stopped seeing it',
                g.store)
    from register g
   where g.relid is not null
     and not exists (select 1 from found f where f.store = g.store)
  order by 3, 2, 1;
$$;

revoke all on function erp.conditional_store_report() from public, anon;

comment on function erp.conditional_store_report() is
  'Every routine and view in the product schemas that reads a store some '
  'organisations never fill, and whether it also reads what answers for the '
  'rest, is allowed by design, or is a known gap. A finding for each that is '
  'none of those, for each allowance or register row that has gone stale, and '
  'for a registered store nothing reads at all.';

create or replace function erp.assert_conditional_stores_answer_otherwise()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  r          record;
  v_count    integer := 0;
  v_first    text;
  v_findings text := '';
  v_answers  integer := 0;
  v_design   integer := 0;
  v_gaps     integer := 0;
  v_stores   integer;
begin
  for r in select * from erp.conditional_store_report() loop
    if r.finding is not null then
      v_count := v_count + 1;
      v_first := coalesce(v_first, r.finding);
      v_findings := v_findings || E'\n  ' || r.finding;
    elsif r.verdict = 'answers otherwise' then
      v_answers := v_answers + 1;
    elsif r.verdict = 'by design' then
      v_design := v_design + 1;
    elsif r.verdict = 'known gap' then
      v_gaps := v_gaps + 1;
    end if;
  end loop;

  if v_count > 0 then
    raise exception E'CLOVEERP_STORE_READ_ALONE: %\n% finding(s):%', v_first, v_count, v_findings
      using errcode = '23514',
            hint = 'A report or routine that reads only a store some organisations '
                   'never fill answers nothing for them, and says nothing about it. '
                   'Read what the register says answers for the rest as well; or, '
                   'where it serves only the organisations that fill the store, add '
                   'it to erp.conditional_store_allowance() with the reason. Take a '
                   'stale allowance out.';
  end if;

  select count(*) into v_stores from erp.conditional_store_register();

  return format('conditional stores: %s registered; %s reader(s) also read what answers when one is empty, %s serve only what fills it, %s known gap(s) written down',
                v_stores, v_answers, v_design, v_gaps);
end;
$$;

revoke all on function erp.assert_conditional_stores_answer_otherwise() from public, anon;

comment on function erp.assert_conditional_stores_answer_otherwise() is
  'No routine or view in the product schemas reads a store some organisations '
  'never fill without also reading what answers for the rest, unless the '
  'allowance says why; and neither register names anything that has gone. '
  'Catalogue arithmetic: one substring search per routine per store, and '
  'pg_depend for views.';

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('conditional_stores_answer_otherwise',
   'No report reads only what some organisations never fill',
   'assertion', 'platform', 'erp', 'assert_conditional_stores_answer_otherwise', '',
   'conditional_store_report', '',
   'Some stores hold rows for some organisations only: cost layers for stock costed first in, first out, unit costs for stock at average or standard cost. A report that reads one of them alone answers nothing for every other organisation and does not say so. This refuses one, and keeps the ones not yet fixed on a list.',
   true, (select coalesce(max(seq), 0) + 1 from erp_meta.diagnostic_check))
on conflict (code) do update set
  title = excluded.title, kind = excluded.kind, scope = excluded.scope,
  schema_name = excluded.schema_name, function_name = excluded.function_name,
  arguments = excluded.arguments, detail_function = excluded.detail_function,
  detail_arguments = excluded.detail_arguments, blurb = excluded.blurb,
  runs_in_ci = excluded.runs_in_ci;


-- ═════════════════════════════════════════════════════════════════════════════
-- 6. Proof: the ageing, under all three methods
--
-- One depot and three products, one per method, received on dates that fall in
-- different bands. The average-cost product is received three times, has a
-- fourth receipt keyed and reversed, and sells thirty-five. The first-in-
-- first-out product is received twice and sells ten. The standard product is
-- received once. Every figure below is worked out by hand in the case that
-- asserts it.
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.stock_ageing_by_costing_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $suite$
declare
  c_expected constant integer := 12;
  c_layer    constant text := 'the receipt it was costed from';
  c_arrival  constant text := 'latest arrivals, oldest assumed out first';
  v_cases   integer := 0;
  v_tag     text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1        uuid := gen_random_uuid();
  v_step    text := 'before the fixture started';
  v_state   text;
  v_msg     text;
  v_tenant  uuid; v_admin uuid; v_token text;
  v_entity  uuid; v_ccy char(3); v_uom uuid;
  v_site    uuid; v_loc uuid;
  v_avg     uuid; v_fifo uuid; v_std uuid;
  v_mv      bigint;
  v_n       integer; v_m integer;
  v_q       numeric; v_v bigint; v_vq numeric; v_vv bigint;
  v_got     text;
  v_methods text;
  v_before  jsonb; v_after jsonb;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    v_step := 'provisioning the organisation';
    perform set_config('request.jwt.claims', '', true);
    select t.tenant_id, t.admin_user_id, t.admin_token
      into v_tenant, v_admin, v_token
      from erp.provision_tenant('zz-age-' || v_tag, 'Ageing suite',
                                'admin@zz-age-' || v_tag || '.test', 'Ageing Admin') t;
    update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zz-age-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(v_token);
    -- Average cost, as the demonstration is.
    perform erp.ensure_demo_configuration(v_tenant, v_admin);

    select l.entity_id, l.currency into v_entity, v_ccy
      from erp.ledger l where l.tenant_id = v_tenant and l.is_primary order by l.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = v_tenant order by u.code limit 1;

    v_step := 'a depot and three products, one for each costing method';
    v_site := erp.create_site('ZZ-AGE', 'Ageing depot', 'warehouse', v_entity);
    insert into erp.location (tenant_id, site_id, code, name, location_type, is_pickable, status)
    values (v_tenant, v_site, 'ZZ-AGE-BULK', 'Ageing bulk', 'bulk'::erp.location_type,
            true, 'active'::erp.record_status)
    returning id into v_loc;

    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (v_tenant, 'ZZ-AGE-AVG', 'Costed at average', v_uom, 'active'::erp.record_status)
    returning id into v_avg;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (v_tenant, 'ZZ-AGE-FIFO', 'Costed first in, first out', v_uom, 'active'::erp.record_status)
    returning id into v_fifo;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (v_tenant, 'ZZ-AGE-STD', 'Costed at standard', v_uom, 'active'::erp.record_status)
    returning id into v_std;

    -- The organisation's own answer is average. The other two are narrowed to
    -- their product, which is the most specific a policy can be.
    insert into erp.costing_policy (tenant_id, code, name, method, item_id, status)
    values (v_tenant, 'zz_age_fifo', 'Ageing suite, first in first out',
            'fifo'::erp.costing_method, v_fifo, 'active'::erp.record_status),
           (v_tenant, 'zz_age_std', 'Ageing suite, standard',
            'standard'::erp.costing_method, v_std, 'active'::erp.record_status);

    v_step := 'receiving the average-cost product three times, and a fourth receipt keyed and reversed';
    -- 30 at 400, 200 days ago; 20 at 500, 100 days ago; 10 at 700, 10 days ago.
    perform erp.receive_cost(v_avg, v_site, 30, 400, v_ccy);
    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id, to_location_id, to_status,
      quantity, uom_id, unit_cost_minor, currency, reason_code, occurred_at)
    values (v_tenant, v_entity, v_site, 'receipt_no_order', v_avg, v_loc,
            'available'::erp.stock_status, 30, v_uom, 400, v_ccy, 'OPENING',
            now() - interval '200 days');
    perform erp.receive_cost(v_avg, v_site, 20, 500, v_ccy);
    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id, to_location_id, to_status,
      quantity, uom_id, unit_cost_minor, currency, reason_code, occurred_at)
    values (v_tenant, v_entity, v_site, 'receipt_no_order', v_avg, v_loc,
            'available'::erp.stock_status, 20, v_uom, 500, v_ccy, 'OPENING',
            now() - interval '100 days');
    perform erp.receive_cost(v_avg, v_site, 10, 700, v_ccy);
    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id, to_location_id, to_status,
      quantity, uom_id, unit_cost_minor, currency, reason_code, occurred_at)
    values (v_tenant, v_entity, v_site, 'receipt_no_order', v_avg, v_loc,
            'available'::erp.stock_status, 10, v_uom, 700, v_ccy, 'OPENING',
            now() - interval '10 days');
    -- Five keyed three days ago and taken back. Were it counted, it would be
    -- the newest arrival and would push five units into the wrong band.
    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id, to_location_id, to_status,
      quantity, uom_id, unit_cost_minor, currency, reason_code, occurred_at)
    values (v_tenant, v_entity, v_site, 'receipt_no_order', v_avg, v_loc,
            'available'::erp.stock_status, 5, v_uom, 600, v_ccy, 'OPENING',
            now() - interval '3 days')
    returning id into v_mv;
    perform erp.reverse_stock_movement(v_mv, 'keyed twice');

    v_step := 'selling thirty-five of the average-cost product';
    -- 29,000 over 60 units; 35 out takes round(29000 * 35 / 60) = 16,917, and
    -- 12,083 stays for the 25 on hand.
    perform erp.issue_cost(v_avg, v_site, 35);
    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id, from_location_id, from_status,
      quantity, uom_id, unit_cost_minor, currency)
    values (v_tenant, v_entity, v_site, 'despatch', v_avg, v_loc,
            'available'::erp.stock_status, 35, v_uom, 483, v_ccy);

    v_step := 'receiving the first-in-first-out product twice, and selling ten';
    perform erp.receive_cost(v_fifo, v_site, 30, 500, v_ccy);
    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id, to_location_id, to_status,
      quantity, uom_id, unit_cost_minor, currency, reason_code, occurred_at)
    values (v_tenant, v_entity, v_site, 'receipt_no_order', v_fifo, v_loc,
            'available'::erp.stock_status, 30, v_uom, 500, v_ccy, 'OPENING',
            now() - interval '120 days');
    -- A layer is stamped when it is written. Put this one where its receipt
    -- is, so the comparison below has two bands to compare and not one.
    update erp.stock_valuation_layer
       set received_at = now() - interval '120 days'
     where tenant_id = v_tenant and item_id = v_fifo;
    perform erp.receive_cost(v_fifo, v_site, 20, 600, v_ccy);
    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id, to_location_id, to_status,
      quantity, uom_id, unit_cost_minor, currency, reason_code, occurred_at)
    values (v_tenant, v_entity, v_site, 'receipt_no_order', v_fifo, v_loc,
            'available'::erp.stock_status, 20, v_uom, 600, v_ccy, 'OPENING',
            now() - interval '5 days');
    perform erp.issue_cost(v_fifo, v_site, 10);
    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id, from_location_id, from_status,
      quantity, uom_id, unit_cost_minor, currency)
    values (v_tenant, v_entity, v_site, 'despatch', v_fifo, v_loc,
            'available'::erp.stock_status, 10, v_uom, 500, v_ccy);

    v_step := 'receiving the standard-cost product once';
    perform erp.receive_cost(v_std, v_site, 12, 400, v_ccy);
    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id, to_location_id, to_status,
      quantity, uom_id, unit_cost_minor, currency, reason_code, occurred_at)
    values (v_tenant, v_entity, v_site, 'receipt_no_order', v_std, v_loc,
            'available'::erp.stock_status, 12, v_uom, 400, v_ccy, 'OPENING',
            now() - interval '40 days');

    -- ── 1. The defect ───────────────────────────────────────────────────────
    v_step := 'reading the average-cost product the way the ageing read until today';
    v_methods := format('%s, %s, %s',
                        erp.costing_method_for(v_avg, v_site),
                        erp.costing_method_for(v_fifo, v_site),
                        erp.costing_method_for(v_std, v_site));
    select count(*) into v_n
      from erp.stock_valuation_layer l
     where l.tenant_id = v_tenant and l.item_id = v_avg and l.remaining > 0;
    select count(*) into v_m
      from erp.stock_ageing_report() a where a.item_code = 'ZZ-AGE-AVG';

    v_cases := v_cases + 1;
    case_name := 'stock at average cost has no layers to age, which is why the ageing was empty, and now it has rows';
    passed := coalesce(v_methods = 'average, fifo, standard' and v_n = 0 and v_m > 0, false);
    detail := format('costed %s; %s layer(s) for the average-cost product, %s ageing row(s) for it now',
                     v_methods, v_n, v_m);
    return next;

    -- ── 2. Average: the latest arrivals, newest first ────────────────────────
    -- On hand 25. Newest first: the 10 from ten days ago, then 15 of the 20
    -- from a hundred days ago. The 30 from two hundred days ago are taken as
    -- gone, and the reversed five are no arrival at all. Value 12,083 shared by
    -- quantity: round(12083 * 10 / 25) = 4,833, and 7,250 for the rest.
    v_step := 'banding the average-cost product';
    select string_agg(format('%s %s %s', a.bucket, a.quantity::bigint, a.value_minor), '; '
                      order by a.bucket)
      into v_got
      from erp.stock_ageing_report() a where a.item_code = 'ZZ-AGE-AVG';

    v_cases := v_cases + 1;
    case_name := 'stock at average cost is aged by the latest arrivals that make up what is on hand, oldest assumed out first, and a reversed receipt is no arrival';
    passed := coalesce(v_got = '0-30 10 4833; 91-180 15 7250', false);
    detail := coalesce(v_got, 'no rows');
    return next;

    -- ── 3. And it adds up to the valuation ───────────────────────────────────
    select sum(a.quantity), sum(a.value_minor) into v_q, v_v
      from erp.stock_ageing_report() a where a.item_code = 'ZZ-AGE-AVG';
    select v.quantity, v.value_minor into v_vq, v_vv
      from erp.stock_valuation_report() v where v.item_code = 'ZZ-AGE-AVG';

    v_cases := v_cases + 1;
    case_name := 'the average-cost bands add up to the valuation, to the unit and to the penny';
    passed := coalesce(v_q = v_vq and v_v = v_vv and v_vq = 25 and v_vv = 12083, false);
    detail := format('ageing %s units worth %s; valuation %s units worth %s', v_q, v_v, v_vq, v_vv);
    return next;

    -- ── 4. Standard ages the same way ───────────────────────────────────────
    select string_agg(format('%s %s %s', a.bucket, a.quantity::bigint, a.value_minor), '; '
                      order by a.bucket)
      into v_got
      from erp.stock_ageing_report() a where a.item_code = 'ZZ-AGE-STD';

    v_cases := v_cases + 1;
    case_name := 'stock at standard cost keeps no layers either, and is aged from its arrival the same way';
    passed := coalesce(v_got = '31-90 12 4800', false);
    detail := coalesce(v_got, 'no rows');
    return next;

    -- ── 5. Each row says how it knows ───────────────────────────────────────
    select string_agg(k.said, '; ' order by k.said)
      into v_got
      from (select distinct format('%s: %s', a.item_code, a.aged_by) as said
              from erp.stock_ageing_report() a where a.item_code like 'ZZ-AGE-%') k;

    v_cases := v_cases + 1;
    case_name := 'every row says how its age is known: the receipt it was costed from, or the latest arrivals with the oldest assumed out first';
    passed := coalesce(v_got = format('ZZ-AGE-AVG: %s; ZZ-AGE-FIFO: %s; ZZ-AGE-STD: %s',
                                      c_arrival, c_layer, c_arrival), false);
    detail := coalesce(v_got, 'no rows');
    return next;

    -- ── 6. First in, first out is exactly as it was ──────────────────────────
    -- The ageing's own query until today, verbatim but for the organisation,
    -- against what it answers now for stock kept in layers. Row for row.
    v_step := 'comparing first in, first out with the query it replaced';
    select coalesce(jsonb_agg(jsonb_build_object('item', x.code, 'site', x.site_code,
                                                 'band', x.bucket, 'quantity', x.quantity,
                                                 'value', x.value_minor)), '[]'::jsonb)
      into v_before
      from (select l.item_id, i.code, l.site_id, s.code as site_code,
                   case
                     when l.received_at > now() - interval '30 days'  then '0-30'
                     when l.received_at > now() - interval '90 days'  then '31-90'
                     when l.received_at > now() - interval '180 days' then '91-180'
                     when l.received_at > now() - interval '365 days' then '181-365'
                     else '365+'
                   end as bucket,
                   sum(l.remaining) as quantity,
                   round(sum(l.remaining * l.unit_cost_minor))::bigint as value_minor
              from erp.stock_valuation_layer l
              join erp.item i on i.id = l.item_id
              left join erp.site s on s.id = l.site_id
             where l.tenant_id = v_tenant
               and l.remaining > 0
             group by 1, 2, 3, 4, 5) x;
    select coalesce(jsonb_agg(jsonb_build_object('item', a.item_code, 'site', a.site_code,
                                                 'band', a.bucket, 'quantity', a.quantity,
                                                 'value', a.value_minor)), '[]'::jsonb)
      into v_after
      from erp.stock_ageing_report() a
     where a.aged_by = c_layer;
    select count(*) into v_n
      from (select e.value from jsonb_array_elements(v_before) as e(value)
            except all
            select e.value from jsonb_array_elements(v_after) as e(value)) d;
    select count(*) into v_m
      from (select e.value from jsonb_array_elements(v_after) as e(value)
            except all
            select e.value from jsonb_array_elements(v_before) as e(value)) d;
    select string_agg(format('%s %s %s', a.bucket, a.quantity::bigint, a.value_minor), '; '
                      order by a.bucket)
      into v_got
      from erp.stock_ageing_report() a where a.item_code = 'ZZ-AGE-FIFO';

    v_cases := v_cases + 1;
    case_name := 'stock costed first in, first out ages exactly as it did: the old query and the new report agree row for row';
    passed := coalesce(jsonb_array_length(v_before) = 2 and v_n = 0 and v_m = 0
                       and v_got = '0-30 20 12000; 91-180 20 10000', false);
    detail := format('%s row(s) before, %s after; %s only before, %s only after; %s',
                     jsonb_array_length(v_before), jsonb_array_length(v_after), v_n, v_m,
                     coalesce(v_got, 'no rows'));
    return next;

    -- ── 7. And it still adds up to the valuation ─────────────────────────────
    select sum(a.quantity), sum(a.value_minor) into v_q, v_v
      from erp.stock_ageing_report() a where a.item_code = 'ZZ-AGE-FIFO';
    select v.quantity, v.value_minor into v_vq, v_vv
      from erp.stock_valuation_report() v where v.item_code = 'ZZ-AGE-FIFO';

    v_cases := v_cases + 1;
    case_name := 'the first-in-first-out bands still add up to the valuation';
    passed := coalesce(v_q = v_vq and v_v = v_vv and v_vq = 40 and v_vv = 22000, false);
    detail := format('ageing %s units worth %s; valuation %s units worth %s', v_q, v_v, v_vq, v_vv);
    return next;

    -- ── 8. The whole organisation ────────────────────────────────────────────
    select coalesce(sum(a.quantity), 0), coalesce(sum(a.value_minor), 0) into v_q, v_v
      from erp.stock_ageing_report() a;
    select coalesce(sum(v.quantity), 0), coalesce(sum(v.value_minor), 0) into v_vq, v_vv
      from erp.stock_valuation_report() v where v.quantity > 0;

    v_cases := v_cases + 1;
    case_name := 'the ageing of the whole organisation, under three methods at once, adds up to its valuation';
    passed := coalesce(v_q = v_vq and v_v = v_vv and v_vq = 77 and v_vv = 38883, false);
    detail := format('ageing %s units worth %s; valuation %s units worth %s', v_q, v_v, v_vq, v_vv);
    return next;

    -- ── 9. The door ─────────────────────────────────────────────────────────
    v_step := 'asking the door the screen asks, for the depot';
    select count(*), count(*) filter (where coalesce(x ->> 'aged_by', '') <> '')
      into v_n, v_m
      from jsonb_array_elements(public.erp_stock_ageing(v_site)) x
     where x ->> 'item_code' like 'ZZ-AGE-%';

    v_cases := v_cases + 1;
    case_name := 'the door the Stock screen reads answers for all three products and says how each row was aged';
    passed := coalesce(v_n = 5 and v_m = 5, false);
    detail := format('%s row(s) for the depot, %s saying how they were aged', v_n, v_m);
    return next;

    -- ── 10. The provision reads the same arrivals ───────────────────────────
    -- 10 units ten days old: 0-90, nothing provided. 15 units a hundred days
    -- old: 91-180, a quarter of 7,250, which is 1,812.5 and rounds to 1,813.
    v_step := 'reading the slow-moving provision';
    select string_agg(format('%s %s %s %s %s', x ->> 'bucket', (x ->> 'quantity')::numeric::bigint,
                             x ->> 'value_minor', x ->> 'provision_pct', x ->> 'provision_minor'),
                      '; ' order by x ->> 'bucket')
      into v_got
      from jsonb_array_elements(public.erp_stock_provision()) x
     where x ->> 'item_code' = 'ZZ-AGE-AVG';

    v_cases := v_cases + 1;
    case_name := 'the slow-moving provision reads the same arrivals, so stock at average cost is provided against by age';
    passed := coalesce(v_got = '0-90 10 4833 0 0; 91-180 15 7250 25 1813', false);
    detail := coalesce(v_got, 'no rows');
    return next;

    -- ── 11. And first in, first out's provision is as it was ────────────────
    -- The provision's own query until today, verbatim but for the organisation.
    select coalesce(jsonb_agg(x - 'item_id' - 'item_name'), '[]'::jsonb)
      into v_before
      from (select jsonb_build_object(
                     'item_id', l.item_id, 'item_code', i.code, 'item_name', i.name,
                     'bucket', b.bucket, 'quantity', sum(l.remaining),
                     'value_minor', round(sum(l.remaining * l.unit_cost_minor))::bigint,
                     'provision_pct', b.pct,
                     'provision_minor', round(sum(l.remaining * l.unit_cost_minor) * b.pct / 100.0)::bigint) as x
              from erp.stock_valuation_layer l
              join erp.item i on i.tenant_id = l.tenant_id and i.id = l.item_id
              cross join lateral (
                select case
                         when l.received_at > now() - interval '90 days'  then '0-90'
                         when l.received_at > now() - interval '180 days' then '91-180'
                         when l.received_at > now() - interval '365 days' then '181-365'
                         else '365+' end as bucket,
                       case
                         when l.received_at > now() - interval '90 days'  then 0
                         when l.received_at > now() - interval '180 days' then 25
                         when l.received_at > now() - interval '365 days' then 50
                         else 100 end as pct) b
             where l.tenant_id = v_tenant
               and l.remaining > 0
             group by l.item_id, i.code, i.name, b.bucket, b.pct) t;
    select coalesce(jsonb_agg(x - 'item_id' - 'item_name' - 'aged_by'), '[]'::jsonb)
      into v_after
      from jsonb_array_elements(public.erp_stock_provision()) x
     where x ->> 'aged_by' = c_layer;
    select count(*) into v_n
      from (select e.value from jsonb_array_elements(v_before) as e(value)
            except all
            select e.value from jsonb_array_elements(v_after) as e(value)) d;
    select count(*) into v_m
      from (select e.value from jsonb_array_elements(v_after) as e(value)
            except all
            select e.value from jsonb_array_elements(v_before) as e(value)) d;

    v_cases := v_cases + 1;
    case_name := 'the provision for stock costed first in, first out is exactly as it was';
    passed := coalesce(jsonb_array_length(v_before) = 2 and v_n = 0 and v_m = 0, false);
    detail := format('%s row(s) before, %s after; %s only before, %s only after',
                     jsonb_array_length(v_before), jsonb_array_length(v_after), v_n, v_m);
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
      v_msg := sqlerrm;
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);

  -- ── 12. Undone ────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code = 'zz-age-' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1);
  detail := coalesce(v_state, 'the depot, its three products and their stock rolled back');
  return next;

  -- The count guard says what stopped the fixture, so the refusal this suite
  -- caught — and the step that produced it — reaches the build log.
  if v_cases <> c_expected then
    raise exception 'CLOVEERP_SUITE_SHRANK: stock_ageing_by_costing_suite ran % case(s), expected %; the fixture stopped %; the last refusal it caught was %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost'),
      coalesce(left(v_msg, 200), 'none')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$suite$;

revoke all on function erp_test.stock_ageing_by_costing_suite() from public, anon;

comment on function erp_test.stock_ageing_by_costing_suite() is
  'The stock ageing under all three costing methods at once. Stock at average '
  'and at standard cost is aged by the latest arrivals that make up what is on '
  'hand, a reversed receipt is no arrival, and the bands add up to the '
  'valuation to the penny; stock costed first in, first out ages exactly as '
  'the query this replaced did; the door says how each row was aged; the '
  'slow-moving provision reads the same arrivals, and is unchanged for stock in '
  'layers. Rolls back everything it made.';

create or replace function erp_test.assert_stock_ageing_by_costing_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $wrap$
declare
  c_expected constant integer := 12;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _stock_ageing_by_costing on commit drop as
    select * from erp_test.stock_ageing_by_costing_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _stock_ageing_by_costing;
  drop table _stock_ageing_by_costing;
  if v_fail > 0 then
    raise exception E'CLOVEERP_STOCK_AGEING_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_SUITE_SHRANK: stock_ageing_by_costing_suite ran % case(s), expected %',
      v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('stock ages however it is costed: %s/%s cases passed', v_all, v_all);
end;
$wrap$;

revoke all on function erp_test.assert_stock_ageing_by_costing_suite() from public, anon;


-- ═════════════════════════════════════════════════════════════════════════════
-- 7. Proof: the check, falsified
--
-- Nothing here needs an organisation. It builds throwaway routines and a view
-- the check has to refuse or accept, and every one of them is rolled back.
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.conditional_store_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $suite$
declare
  c_expected constant integer := 6;
  v_cases   integer := 0;
  v_step    text := 'before anything was built';
  v_state   text;
  v_msg     text;
  v_report  text;
  v_verdict text;
  v_gaps    integer;
begin
  begin
    -- ── 1. The census, as the product stands ─────────────────────────────────
    v_step := 'the census as the product stands';
    v_report := erp.assert_conditional_stores_answer_otherwise();
    select count(*) into v_gaps from erp.conditional_store_report() r where r.verdict = 'known gap';
    select r.verdict into v_verdict from erp.conditional_store_report() r
     where r.reader = 'erp.stock_on_hand_by_arrival' and r.store = 'erp.stock_valuation_layer';

    v_cases := v_cases + 1;
    case_name := 'every reader of a store some organisations never fill also reads what answers for the rest, or is written down with its reason';
    passed := coalesce(v_report like 'conditional stores: 2 registered;%'
                       and v_gaps = 9 and v_verdict = 'answers otherwise', false);
    detail := format('%s; the ageing''s own source: %s', v_report, coalesce(v_verdict, 'not found'));
    return next;

    -- ── 2. The defect, as it was ───────────────────────────────────────────
    -- The ageing and the provision exactly as they read until today, under
    -- throwaway names. The check has to name both.
    v_step := 'the two reports as they read before, under throwaway names';
    v_msg := null;
    begin
      execute $ddl$
        create function erp.zz_stock_ageing_as_it_was()
        returns table (item_id uuid, item_code text, site_id uuid, site_code text,
                       bucket text, quantity numeric, value_minor bigint)
        language sql stable security invoker set search_path = '' as $b$
          select l.item_id, i.code, l.site_id, s.code,
                 case
                   when l.received_at > now() - interval '30 days'  then '0-30'
                   when l.received_at > now() - interval '90 days'  then '31-90'
                   when l.received_at > now() - interval '180 days' then '91-180'
                   when l.received_at > now() - interval '365 days' then '181-365'
                   else '365+'
                 end,
                 sum(l.remaining),
                 round(sum(l.remaining * l.unit_cost_minor))::bigint
            from erp.stock_valuation_layer l
            join erp.item i on i.id = l.item_id
            left join erp.site s on s.id = l.site_id
           where l.tenant_id = erp.current_tenant_id()
             and l.remaining > 0
           group by 1, 2, 3, 4, 5
           order by 2, 5
        $b$
      $ddl$;
      execute $ddl$
        create function erp.zz_stock_provision_as_it_was()
        returns jsonb language sql stable security invoker set search_path = '' as $b$
          select coalesce(jsonb_agg(x order by (x->>'provision_minor')::bigint desc), '[]'::jsonb) from (
            select jsonb_build_object(
                     'item_id', l.item_id, 'item_code', i.code, 'item_name', i.name,
                     'bucket', b.bucket, 'quantity', sum(l.remaining),
                     'value_minor', round(sum(l.remaining * l.unit_cost_minor))::bigint,
                     'provision_pct', b.pct,
                     'provision_minor', round(sum(l.remaining * l.unit_cost_minor) * b.pct / 100.0)::bigint) as x
              from erp.stock_valuation_layer l
              join erp.item i on i.tenant_id = l.tenant_id and i.id = l.item_id
              cross join lateral (
                select case
                         when l.received_at > now() - interval '90 days'  then '0-90'
                         when l.received_at > now() - interval '180 days' then '91-180'
                         when l.received_at > now() - interval '365 days' then '181-365'
                         else '365+' end as bucket,
                       case
                         when l.received_at > now() - interval '90 days'  then 0
                         when l.received_at > now() - interval '180 days' then 25
                         when l.received_at > now() - interval '365 days' then 50
                         else 100 end as pct) b
             where l.tenant_id = erp.current_tenant_id()
               and l.remaining > 0
             group by l.item_id, i.code, i.name, b.bucket, b.pct) t
        $b$
      $ddl$;
      begin
        perform erp.assert_conditional_stores_answer_otherwise();
      exception when others then v_msg := sqlerrm;
      end;
      raise exception 'CLOVEERP_SUITE_UNDO';
    exception when others then
      if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
    end;

    v_cases := v_cases + 1;
    case_name := 'the ageing and the provision as they read until today, layers alone, are both refused by name';
    passed := coalesce(v_msg like 'CLOVEERP_STORE_READ_ALONE:%'
                       and v_msg like '%erp.zz_stock_ageing_as_it_was reads erp.stock_valuation_layer%'
                       and v_msg like '%erp.zz_stock_provision_as_it_was reads erp.stock_valuation_layer%', false);
    detail := left(coalesce(v_msg, 'the check passed two reports that read only the layers'), 300);
    return next;

    -- ── 3. Reading the ledger as well is enough ─────────────────────────────
    v_step := 'a routine that reads the layers and the movement ledger';
    v_msg := null;
    v_report := null;
    v_verdict := null;
    begin
      execute $ddl$
        create function erp.zz_ages_by_either() returns bigint
        language sql stable security invoker set search_path = '' as $b$
          select (select count(*) from erp.stock_valuation_layer l where l.remaining > 0)
               + (select count(*) from erp.stock_movement m where m.to_location_id is not null)
        $b$
      $ddl$;
      v_report := erp.assert_conditional_stores_answer_otherwise();
      select r.verdict into v_verdict from erp.conditional_store_report() r
       where r.reader = 'erp.zz_ages_by_either';
      raise exception 'CLOVEERP_SUITE_UNDO';
    exception when others then
      if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := sqlerrm; end if;
    end;

    v_cases := v_cases + 1;
    case_name := 'a routine that reads the layers and the movement ledger too is accepted, so the check refuses the shape and not the name';
    passed := coalesce(v_msg is null and v_report is not null and v_verdict = 'answers otherwise', false);
    detail := coalesce(left(v_msg, 300), format('%s; %s', coalesce(v_verdict, 'not found'), v_report));
    return next;

    -- ── 4. A view is read from the catalogue ────────────────────────────────
    v_step := 'a view that reads the unit costs alone';
    v_msg := null;
    begin
      execute $ddl$
        create view erp.zz_cost_only with (security_invoker = true) as
          select c.item_id, c.unit_cost_minor from erp.item_cost c
      $ddl$;
      begin
        perform erp.assert_conditional_stores_answer_otherwise();
      exception when others then v_msg := sqlerrm;
      end;
      raise exception 'CLOVEERP_SUITE_UNDO';
    exception when others then
      if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
    end;

    v_cases := v_cases + 1;
    case_name := 'a view that reads the unit costs alone is refused too, found from what the catalogue says it depends on';
    passed := coalesce(v_msg like 'CLOVEERP_STORE_READ_ALONE:%'
                       and v_msg like '%erp.zz_cost_only reads erp.item_cost%', false);
    detail := left(coalesce(v_msg, 'the check passed a view that reads only the unit costs'), 300);
    return next;

    -- ── 5. The registers cannot rot ─────────────────────────────────────────
    -- Each register is set aside under a name the check ignores and replaced
    -- by itself plus one row that describes nothing.
    v_step := 'an allowance and a register row that describe nothing';
    v_msg := null;
    begin
      execute 'alter function erp.conditional_store_register() rename to conditional_store_register_as_it_was';
      execute $ddl$
        create function erp.conditional_store_register()
        returns table (store text, filled_for text, answered_otherwise_by text[])
        language sql immutable set search_path = '' as $b$
          select * from erp.conditional_store_register_as_it_was()
          union all
          select 'erp.zz_no_such_store', 'nothing at all', array['erp.stock_movement']
        $b$
      $ddl$;
      execute 'alter function erp.conditional_store_allowance() rename to conditional_store_allowance_as_it_was';
      execute $ddl$
        create function erp.conditional_store_allowance()
        returns table (reader text, store text, known_gap boolean, rationale text)
        language sql immutable set search_path = '' as $b$
          select * from erp.conditional_store_allowance_as_it_was()
          union all
          select 'erp.zz_gone', 'erp.item_cost', true, 'a routine renamed away'
        $b$
      $ddl$;
      begin
        perform erp.assert_conditional_stores_answer_otherwise();
      exception when others then v_msg := sqlerrm;
      end;
      raise exception 'CLOVEERP_SUITE_UNDO';
    exception when others then
      if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
    end;

    v_cases := v_cases + 1;
    case_name := 'an allowance for a routine that is gone, and a register row for a store that does not exist, are both refused';
    passed := coalesce(v_msg like 'CLOVEERP_STORE_READ_ALONE:%'
                       and v_msg like '%erp.zz_gone is allowed to read erp.item_cost alone and does not read it at all%'
                       and v_msg like '%the register names erp.zz_no_such_store%', false);
    detail := left(coalesce(v_msg, 'the check passed a register that describes nothing'), 300);
    return next;

  exception when others then
    v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    v_msg := sqlerrm;
  end;

  -- ── 6. Undone ─────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'everything built to falsify the check was rolled back, and the registers are as they were';
  passed := v_state is null
        and to_regprocedure('erp.zz_stock_ageing_as_it_was()') is null
        and to_regprocedure('erp.zz_stock_provision_as_it_was()') is null
        and to_regprocedure('erp.zz_ages_by_either()') is null
        and to_regclass('erp.zz_cost_only') is null
        and to_regprocedure('erp.conditional_store_register_as_it_was()') is null
        and to_regprocedure('erp.conditional_store_allowance_as_it_was()') is null
        and (select count(*) from erp.conditional_store_register()) = 2;
  detail := coalesce(v_state, 'three routines, a view and two replaced registers, all gone');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_SUITE_SHRANK: conditional_store_suite ran % case(s), expected %; it stopped %; the last refusal it caught was %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost'),
      coalesce(left(v_msg, 200), 'none')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$suite$;

revoke all on function erp_test.conditional_store_suite() from public, anon;

comment on function erp_test.conditional_store_suite() is
  'The conditional-store check, proved and falsified. The product as it stands '
  'passes with nine known gaps written down; the stock ageing and the '
  'slow-moving provision as they read until 20260920175000 are both refused by '
  'name; a routine that also reads the movement ledger is accepted; a view '
  'that reads only unit costs is refused from the catalogue; an allowance for '
  'a routine that is gone and a register row for a store that does not exist '
  'are refused. Rolls back everything it built.';

create or replace function erp_test.assert_conditional_store_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $wrap$
declare
  c_expected constant integer := 6;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _conditional_store on commit drop as
    select * from erp_test.conditional_store_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _conditional_store;
  drop table _conditional_store;
  if v_fail > 0 then
    raise exception E'CLOVEERP_CONDITIONAL_STORE_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_SUITE_SHRANK: conditional_store_suite ran % case(s), expected %',
      v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('no report reads only what some organisations never fill: %s/%s cases passed',
                v_all, v_all);
end;
$wrap$;

revoke all on function erp_test.assert_conditional_store_suite() from public, anon;


-- ═════════════════════════════════════════════════════════════════════════════
-- 8. The generators, then the checks that read what changed
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
select erp.assert_invoker_doors_executable();
select erp.assert_no_caller_reachable_internals();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_governed_views_are_safe();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_part5_coverage();

-- The new check, against the database this migration just changed.
select erp.assert_conditional_stores_answer_otherwise();
select erp_test.assert_conditional_store_suite();

-- The ageing and the provision, and the two suites that already read them.
select erp_test.assert_stock_ageing_by_costing_suite();
select erp_test.assert_stock_site_filter_suite();
select erp_test.assert_inventory_suite();
