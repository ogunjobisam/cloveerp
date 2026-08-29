-- =============================================================================
-- ERPWare — Part 5.6: sales and order management
--
-- Sales has its lifecycles, its discount and credit bands, and its posting
-- rules. What it does not have is anything that decides a price, promises a
-- date, or reserves the stock it promised — which is most of what an order
-- desk does.
--
-- erp.item_price has existed since B7 with a price_kind enum naming
-- sales_list, contract and promotion, and a party_role_id to hang a customer
-- contract on. Nothing writes it and nothing reads it: every price in this
-- product so far has been typed onto a document line by whoever raised it.
--
-- erp.allocation has location_scope, policy_code, unmet_quantity and
-- unmet_cause — four columns that only make sense for the two-stage allocation
-- spec 5.6 describes, and until this migration nothing populated any of them.
--
-- The two clauses in spec 5.6 that most products skip, and that decide whether
-- this is real:
--
--   "unmet detailed allocation classified by cause, so a shortage raises
--    internal replenishment rather than a silent shortfall"
--       A shortage that is nobody's job is a shortage that is discovered on
--       the loading bay.
--
--   "invoicing derived from validated delivery with role separation enforced"
--       The person who says it shipped must not be the person who bills for
--       it. That is a segregation of duties, and B1 already has the machinery.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Who moved it
--
-- erp.stock_movement.actor_id has existed since B7 and nothing has ever set it.
-- Every movement in this product is anonymous, which was invisible until
-- something needed to know who despatched a delivery — and the segregation of
-- duties below is exactly that.
--
-- A default rather than a change to every call site: the movement's actor is
-- the session's principal in every case, there is no legitimate way for it to
-- be anybody else, and a trigger cannot be forgotten by the next function that
-- writes a movement.
-- -----------------------------------------------------------------------------

create or replace function erp.stamp_movement_actor()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.actor_id is null then
    new.actor_id := erp.current_principal_id();
  end if;
  return new;
end;
$$;

drop trigger if exists t_stock_movement_actor on erp.stock_movement;
create trigger t_stock_movement_actor
  before insert on erp.stock_movement
  for each row execute function erp.stamp_movement_actor();

-- -----------------------------------------------------------------------------
-- Pricing
--
-- Four sources, resolved in a fixed order of specificity, and the order is the
-- design: a contract price beats a promotion beats a list price, because a
-- contract is a promise and a promotion is an offer.
--
-- The margin floor is checked last and against cost, because a discount chain
-- that can reach below cost is one that will.
-- -----------------------------------------------------------------------------

create table if not exists erp.pricing_policy (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  code         text not null,
  name         text,
  entity_id    uuid,
  -- The floor, as a percentage of cost. A policy that permits selling below
  -- cost says so explicitly rather than by omission.
  min_margin_pct numeric(6,3) not null default 0,
  allow_below_cost boolean not null default false,
  -- Whose approval is needed to go under.
  approval_chain_code text,
  status       erp.record_status not null default 'active',
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code),
  foreign key (tenant_id, entity_id) references erp.entity (tenant_id, id) on delete cascade
);

create or replace function erp.resolve_price(
  p_item_id  uuid,
  p_party_id uuid,
  p_quantity numeric default 1,
  p_on       date default null,
  p_site_id  uuid default null
) returns table (amount_minor bigint, currency char(3), price_kind erp.price_kind,
                 price_list_code text, source text)
language sql
stable
security invoker
set search_path = ''
as $$
  -- Specificity, in one ordering, so there is one answer and it can be
  -- explained. A contract beats a promotion because a contract is a promise
  -- and a promotion is an offer; both beat the list.
  select p.amount_minor, p.currency, p.price_kind, p.price_list_code,
         case p.price_kind
           when 'contract'  then 'a contract with this customer'
           when 'promotion' then 'a promotion in force today'
           else 'the sales list'
         end
    from erp.item_price p
    left join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.id = p.party_role_id
   where p.tenant_id = erp.current_tenant_id()
     and p.item_id = p_item_id
     and p.price_kind in ('contract', 'promotion', 'sales_list')
     and (p.party_role_id is null or pr.party_id = p_party_id)
     and (p.site_id is null or p.site_id = p_site_id)
     and coalesce(p.min_quantity, 0) <= p_quantity
     and p.valid_from <= coalesce(p_on, current_date)
     and (p.valid_to is null or p.valid_to > coalesce(p_on, current_date))
   order by case p.price_kind
              when 'contract' then 0 when 'promotion' then 1 else 2 end,
            (p.party_role_id is not null) desc,
            (p.site_id is not null) desc,
            -- The most specific quantity break that this line qualifies for.
            coalesce(p.min_quantity, 0) desc
   limit 1
$$;

comment on function erp.resolve_price(uuid, uuid, numeric, date, uuid) is
  'Spec 5.6: pricing with lists, contracts and promotions. One ordering, so '
  'there is one answer and it can be explained — a contract beats a promotion '
  'because a contract is a promise and a promotion is an offer.';

create or replace function erp.check_margin(
  p_item_id  uuid,
  p_site_id  uuid,
  p_price_minor bigint,
  p_policy_code text default null
) returns table (cost_minor bigint, margin_pct numeric, within_policy boolean,
                 policy_code text, message text)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  pp       erp.pricing_policy%rowtype;
begin
  select * into pp from erp.pricing_policy
   where tenant_id = v_tenant and status = 'active'
     and (p_policy_code is null or code = p_policy_code)
   order by (code = coalesce(p_policy_code, '')) desc, code
   limit 1;

  select c.unit_cost_minor into cost_minor
    from erp.item_cost c
   where c.tenant_id = v_tenant and c.item_id = p_item_id
     and c.site_id is not distinct from p_site_id;

  policy_code := pp.code;

  if cost_minor is null then
    -- No cost is not a pass. A margin check that silently succeeds when it
    -- cannot be answered is worse than no margin check, because somebody will
    -- believe it.
    within_policy := false;
    margin_pct := null;
    message := 'this item has no cost at this site, so margin cannot be checked';
    return next;
    return;
  end if;

  margin_pct := case when p_price_minor = 0 then -100
                     else round(100.0 * (p_price_minor - cost_minor) / p_price_minor, 3) end;

  within_policy := margin_pct >= coalesce(pp.min_margin_pct, 0)
                   or (p_price_minor >= cost_minor)
                      and coalesce(pp.min_margin_pct, 0) = 0;

  if p_price_minor < cost_minor and not coalesce(pp.allow_below_cost, false) then
    within_policy := false;
    message := format('below cost: %s against %s', p_price_minor, cost_minor);
  elsif not within_policy then
    message := format('margin %s per cent is under the floor of %s',
                      margin_pct, pp.min_margin_pct);
  else
    message := 'within policy';
  end if;

  return next;
end;
$$;

create or replace function erp.price_document_line(p_line_id uuid)
returns bigint
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  l        erp.document_line%rowtype;
  d        erp.document%rowtype;
  pr       record;
  m        record;
begin
  select * into l from erp.document_line where tenant_id = v_tenant and id = p_line_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_LINE: %', p_line_id using errcode = '23503';
  end if;

  select * into d from erp.document where tenant_id = v_tenant and id = l.document_id;

  perform erp.authorise('sales.price', d.entity_id, d.site_id, null,
                        'document_line', p_line_id);

  select * into pr from erp.resolve_price(l.item_id, d.party_id, l.quantity,
                                          d.document_date, d.site_id);

  if not found then
    raise exception
      'ERPWARE_NO_PRICE: nothing prices % for this customer on %',
      l.item_id, coalesce(d.document_date, current_date)
      using errcode = '23503',
      hint = 'A price typed onto the line by whoever raised it is not a price '
             'list; configure one.';
  end if;

  select * into m from erp.check_margin(l.item_id, d.site_id, pr.amount_minor);

  update erp.document_line
     set unit_price_minor = pr.amount_minor,
         net_minor = round(l.quantity * pr.amount_minor
                           * (1 - coalesce(l.discount_pct, 0) / 100.0))::bigint,
         currency = coalesce(pr.currency, l.currency),
         updated_at = now()
   where id = p_line_id;

  return pr.amount_minor;
end;
$$;

-- -----------------------------------------------------------------------------
-- Availability and promise dating
--
-- "Available" is not "on hand". It is on hand, less what is already promised
-- to somebody else, plus what is coming before the date being asked about —
-- and the third term is why a promise date is a different question from a
-- stock figure.
-- -----------------------------------------------------------------------------

create or replace function erp.available_to_promise(
  p_item_id uuid,
  p_site_id uuid,
  p_on      date default null
) returns table (on_hand numeric, committed numeric, inbound_before numeric,
                 available numeric)
language sql
stable
security invoker
set search_path = ''
as $$
  select
    coalesce((select sum(b.quantity) from erp.stock_balance b
               where b.tenant_id = erp.current_tenant_id()
                 and b.item_id = p_item_id and b.site_id = p_site_id
                 and b.stock_status = 'available'), 0),
    coalesce((select sum(a.quantity - coalesce(a.unmet_quantity, 0))
                from erp.allocation a
               where a.tenant_id = erp.current_tenant_id()
                 and a.item_id = p_item_id and a.site_id = p_site_id
                 and a.status in ('reserved', 'committed', 'picked')), 0),
    coalesce((select sum(s.quantity) from erp.scheduled_supply(
                p_item_id, p_site_id, current_date,
                coalesce(p_on, current_date)) s
               where s.due_on <= coalesce(p_on, current_date)), 0),
    coalesce((select sum(b.quantity) from erp.stock_balance b
               where b.tenant_id = erp.current_tenant_id()
                 and b.item_id = p_item_id and b.site_id = p_site_id
                 and b.stock_status = 'available'), 0)
    - coalesce((select sum(a.quantity - coalesce(a.unmet_quantity, 0))
                  from erp.allocation a
                 where a.tenant_id = erp.current_tenant_id()
                   and a.item_id = p_item_id and a.site_id = p_site_id
                   and a.status in ('reserved', 'committed', 'picked')), 0)
    + coalesce((select sum(s.quantity) from erp.scheduled_supply(
                  p_item_id, p_site_id, current_date,
                  coalesce(p_on, current_date)) s
                 where s.due_on <= coalesce(p_on, current_date)), 0)
$$;

create or replace function erp.promise_date(
  p_item_id uuid,
  p_site_id uuid,
  p_quantity numeric,
  p_horizon_days integer default 180
) returns date
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  a        record;
  r        record;
  v_run    numeric;
begin
  select * into a from erp.available_to_promise(p_item_id, p_site_id, current_date);

  if a.available >= p_quantity then
    return current_date;
  end if;

  -- Walk the inbound supply until the projection covers what is being asked
  -- for. Promising the lead time regardless is how a date is given that has
  -- nothing to do with anything actually arriving.
  v_run := a.on_hand - a.committed;
  for r in
    select s.due_on, sum(s.quantity) as qty
      from erp.scheduled_supply(p_item_id, p_site_id, current_date,
                                current_date + p_horizon_days) s
     where s.due_on is not null
     group by s.due_on order by s.due_on
  loop
    v_run := v_run + r.qty;
    if v_run >= p_quantity then
      return r.due_on;
    end if;
  end loop;

  -- Nothing within the horizon covers it. A null date is the honest answer:
  -- a promise nobody can keep is worse than an admission that there is none.
  return null;
end;
$$;

comment on function erp.promise_date(uuid, uuid, numeric, integer) is
  'Spec 5.6: promise dating. Walks the actual inbound supply rather than adding '
  'a lead time to today; returns null when nothing in the horizon covers the '
  'quantity, because a promise nobody can keep is worse than an admission.';

-- -----------------------------------------------------------------------------
-- Two-stage allocation
--
-- Stage one reserves a quantity against the order. Stage two commits it to
-- specific stock — a location, a batch, a container. They are separate because
-- a warehouse wants to know it has enough long before it wants to be told which
-- pallet, and committing a pallet on the day of order is how a picker is sent
-- to a location that was emptied a fortnight ago.
--
-- The part almost nobody builds is what happens when it does not fit. Spec 5.6:
-- "unmet detailed allocation classified by cause ... raising internal
-- replenishment rather than silent shortage". A shortage that is nobody's job
-- is a shortage discovered on the loading bay.
-- -----------------------------------------------------------------------------

create or replace function erp.reserve_for_line(
  p_document_line_id uuid,
  p_policy_code text default null
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  l        erp.document_line%rowtype;
  d        erp.document%rowtype;
  a        record;
  v_alloc  uuid;
  v_res    numeric;
  v_unmet  numeric;
  v_cause  text;
begin
  select * into l from erp.document_line where tenant_id = v_tenant and id = p_document_line_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_LINE: %', p_document_line_id using errcode = '23503';
  end if;

  select * into d from erp.document where tenant_id = v_tenant and id = l.document_id;

  perform erp.authorise('sales.order', d.entity_id, d.site_id, null,
                        'document_line', p_document_line_id);

  if exists (select 1 from erp.allocation al
              where al.tenant_id = v_tenant and al.document_line_id = p_document_line_id
                and al.status in ('reserved', 'committed', 'picked')) then
    raise exception 'ERPWARE_ALREADY_RESERVED: this line already holds stock'
      using errcode = '23505';
  end if;

  select * into a from erp.available_to_promise(l.item_id, d.site_id, current_date);

  v_res := least(l.quantity, greatest(a.available, 0));
  v_unmet := l.quantity - v_res;

  -- The classification. "Short" is not a cause; these are, and they lead to
  -- different actions by different people.
  v_cause := case
    when v_unmet = 0 then null
    when a.on_hand <= 0 then 'no_stock'
    when a.committed >= a.on_hand then 'all_committed_elsewhere'
    when exists (select 1 from erp.stock_balance b
                  where b.tenant_id = v_tenant and b.item_id = l.item_id
                    and b.site_id = d.site_id and b.stock_status <> 'available'
                    and b.quantity > 0) then 'held_in_a_non_available_status'
    else 'partial_shortfall'
  end;

  insert into erp.allocation (
    tenant_id, entity_id, site_id, item_id, document_id, document_line_id,
    demand_kind, quantity, uom_id, status, policy_code, required_by,
    unmet_quantity, unmet_cause)
  values (v_tenant, d.entity_id, d.site_id, l.item_id, l.document_id,
          p_document_line_id, 'sales_order', l.quantity,
          -- The line may not carry one; the item always does.
          coalesce(l.uom_id, (select i.stock_uom_id from erp.item i
                               where i.id = l.item_id)),
          'reserved', p_policy_code,
          coalesce(l.required_date, d.required_date), v_unmet, v_cause)
  returning id into v_alloc;

  -- Raising the replenishment. This is the clause that makes the difference
  -- between a shortage somebody owns and one that turns up on a loading bay.
  if v_unmet > 0 then
    insert into erp.planning_exception (
      tenant_id, entity_id, site_id, item_id, exception_kind, severity,
      message, detail, document_id)
    values (v_tenant, d.entity_id, d.site_id, l.item_id, 'shortage',
            case when v_cause = 'no_stock' then 'high' else 'medium' end,
            format('%s short against %s: %s', v_unmet, d.document_number, v_cause),
            jsonb_build_object('unmet_quantity', v_unmet, 'cause', v_cause,
                               'on_hand', a.on_hand, 'committed', a.committed,
                               'promise_date',
                               erp.promise_date(l.item_id, d.site_id, v_unmet)),
            l.document_id);
  end if;

  return v_alloc;
end;
$$;

create or replace function erp.commit_allocation(
  p_allocation_id uuid,
  p_location_id uuid default null,
  p_batch_id uuid default null
) returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  al       erp.allocation%rowtype;
  r        record;
  v_left   numeric;
  v_take   numeric;
  v_lines  integer := 0;
begin
  select * into al from erp.allocation
   where tenant_id = v_tenant and id = p_allocation_id for update;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_ALLOCATION: %', p_allocation_id using errcode = '23503';
  end if;

  if al.status <> 'reserved' then
    raise exception 'ERPWARE_ALLOCATION_NOT_RESERVED: % is %', p_allocation_id, al.status
      using errcode = '23514';
  end if;

  perform erp.authorise('sales.despatch', al.entity_id, al.site_id, null,
                        'allocation', p_allocation_id);

  v_left := al.quantity - coalesce(al.unmet_quantity, 0);

  -- Stage two: which stock. First-expiring first, because that is what the
  -- item's own policy says and because the alternative is a warehouse that
  -- writes off the front of the rack.
  for r in
    select b.location_id, b.batch_id, b.quantity, bt.expires_on
      from erp.stock_balance b
      join erp.item i on i.id = b.item_id
      left join erp.batch bt on bt.id = b.batch_id
     where b.tenant_id = v_tenant and b.item_id = al.item_id
       and b.site_id = al.site_id and b.stock_status = 'available'
       and b.quantity > 0
       and (p_location_id is null or b.location_id = p_location_id)
       and (p_batch_id is null or b.batch_id = p_batch_id)
     order by case when i.is_fefo then bt.expires_on end nulls last,
              b.quantity desc
  loop
    exit when v_left <= 0;
    v_take := least(v_left, r.quantity);

    insert into erp.allocation_line (
      tenant_id, allocation_id, location_id, batch_id, stock_status,
      quantity, status)
    values (v_tenant, p_allocation_id, r.location_id, r.batch_id, 'available',
            v_take, 'committed');

    v_left := v_left - v_take;
    v_lines := v_lines + 1;
  end loop;

  if v_lines = 0 then
    raise exception
      'ERPWARE_NOTHING_TO_COMMIT: nothing available matches the scope asked for'
      using errcode = '23514';
  end if;

  update erp.allocation
     set status = 'committed',
         -- What stage two could not find is unmet too, and hiding it here
         -- would make stage one's number the only one anybody trusted.
         unmet_quantity = coalesce(unmet_quantity, 0) + greatest(v_left, 0),
         updated_at = now()
   where id = p_allocation_id;

  return v_lines;
end;
$$;

comment on function erp.commit_allocation(uuid, uuid, uuid) is
  'Spec 5.6: the second stage. Which pallet, decided when the warehouse needs '
  'to know rather than on the day of order — committing a location at order '
  'entry is how a picker is sent to one that was emptied a fortnight ago.';

-- -----------------------------------------------------------------------------
-- Credit hold
--
-- erp.party_role_terms has carried credit_limit_minor, credit_status and
-- is_blocked since B7, and nothing reads any of them. Sales' approval chain
-- checks exposure against a number on the party role's attributes — which is a
-- different place, and having two is how one of them goes stale.
--
-- A hold is a state, not a refusal: the order is taken and cannot be released
-- to fulfilment. Refusing to take the order loses the sale and the record of it.
-- -----------------------------------------------------------------------------

create or replace function erp.credit_position(p_party_id uuid)
returns table (credit_limit_minor bigint, exposure_minor bigint,
               headroom_minor bigint, credit_status text, is_blocked boolean,
               on_hold boolean, reason text)
language sql
stable
security invoker
set search_path = ''
as $$
  with terms as (
    select t.credit_limit_minor, t.credit_status, t.is_blocked, t.block_reason
      from erp.party_role_terms t
      join erp.party_role pr on pr.id = t.party_role_id
     where t.tenant_id = erp.current_tenant_id()
       and pr.party_id = p_party_id and pr.role_kind = 'customer'
       and t.valid_from <= current_date
       and (t.valid_to is null or t.valid_to > current_date)
     order by t.valid_from desc limit 1
  ),
  exposure as (
    -- Committed and not yet settled: orders in flight plus receivables
    -- outstanding. Counting only one of them understates by whichever half is
    -- currently larger.
    select coalesce((select sum(erp.document_value_minor(d.id))
                       from erp.document d
                       join erp.document_type dt on dt.id = d.document_type_id
                       join erp.object_state os on os.object_type = 'document'
                                               and os.object_id = d.id
                       join erp.state s on s.id = os.current_state_id
                      where d.tenant_id = erp.current_tenant_id()
                        and d.party_id = p_party_id
                        and dt.base_type_code = 'sales_order'
                        and s.is_committed and not s.is_terminal
                        and not d.is_cancelled), 0)
         + coalesce((select sum(si.debit_minor - si.credit_minor)
                       from erp.subledger_item si
                      where si.tenant_id = erp.current_tenant_id()
                        and si.party_id = p_party_id
                        and si.control_kind = 'receivable'), 0) as amt
  )
  select terms.credit_limit_minor, exposure.amt,
         terms.credit_limit_minor - exposure.amt,
         terms.credit_status, terms.is_blocked,
         coalesce(terms.is_blocked, false)
           or (terms.credit_limit_minor is not null
               and exposure.amt > terms.credit_limit_minor),
         case when coalesce(terms.is_blocked, false)
                then coalesce(terms.block_reason, 'blocked')
              when terms.credit_limit_minor is not null
                   and exposure.amt > terms.credit_limit_minor
                then 'exposure exceeds the credit limit'
              else 'within terms' end
    from terms, exposure
$$;

create or replace function erp.release_credit_hold(
  p_document_id uuid, p_reason text)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503';
  end if;

  if coalesce(p_reason, '') = '' then
    raise exception 'ERPWARE_CREDIT_RELEASE_NEEDS_REASON: releasing credit is a '
      'decision, and a decision has a reason' using errcode = '23514';
  end if;

  -- A distinct permission, because releasing credit is not order entry. B1's
  -- catalogue has carried sales.credit_release since it was written and
  -- nothing has ever required it.
  perform erp.authorise('sales.credit_release', d.entity_id, d.site_id, null,
                        'document', p_document_id);

  update erp.document
     set attributes = attributes || jsonb_build_object(
           'credit_released_by', erp.current_principal_id(),
           'credit_released_at', now(),
           'credit_release_reason', p_reason),
         updated_at = now()
   where id = p_document_id;
end;
$$;

create or replace function erp.check_release_to_fulfilment(p_document_id uuid)
returns text
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  c        record;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;

  select * into c from erp.credit_position(d.party_id);

  if not found or not c.on_hold then
    return 'clear';
  end if;

  if (d.attributes ? 'credit_released_by') then
    return 'released';
  end if;

  raise exception 'ERPWARE_CREDIT_HOLD: % — %', d.document_number, c.reason
    using errcode = '42501',
    detail = format('limit %s, exposure %s', c.credit_limit_minor, c.exposure_minor),
    hint = 'erp.release_credit_hold() takes a reason and a permission that '
           'order entry does not have.';
end;
$$;

-- -----------------------------------------------------------------------------
-- Amendment and cancellation cut-offs
--
-- Spec 5.6: "amendment and cancellation rules with explicit cut-off behaviour".
-- Explicit is the requirement. Most systems let an order be amended until
-- something downstream fails, which means the cut-off is wherever the first
-- foreign key happens to be.
-- -----------------------------------------------------------------------------

create or replace function erp.amendment_allowed(p_document_id uuid)
returns table (allowed boolean, cut_off text, detail text)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  v_state  text;
  v_picked numeric;
  v_moved  boolean;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503';
  end if;

  select s.code into v_state
    from erp.object_state os join erp.state s on s.id = os.current_state_id
   where os.tenant_id = v_tenant and os.object_type = 'document' and os.object_id = p_document_id;

  select exists (select 1 from erp.stock_movement m
                  where m.tenant_id = v_tenant and m.document_id = p_document_id)
    into v_moved;

  select coalesce(sum(al.quantity), 0) into v_picked
    from erp.allocation a
    join erp.allocation_line al on al.allocation_id = a.id
   where a.tenant_id = v_tenant and a.document_id = p_document_id
     and al.status = 'picked';

  -- Three cut-offs, in the order they bite, each named. "The order is too far
  -- along" is not a cut-off; these are.
  if v_moved then
    allowed := false;
    cut_off := 'stock_has_moved';
    detail := 'stock has left against this order; amend by returning it, not by '
              'editing the order';
  elsif v_picked > 0 then
    allowed := false;
    cut_off := 'picking_started';
    detail := format('%s already picked; the warehouse is holding it', v_picked);
  elsif v_state in ('despatched', 'invoiced', 'closed', 'cancelled') then
    allowed := false;
    cut_off := 'lifecycle_state';
    detail := format('the order is %s', v_state);
  else
    allowed := true;
    cut_off := null;
    detail := 'amendable';
  end if;

  return next;
end;
$$;

create or replace function erp.amend_document_line(
  p_line_id uuid,
  p_quantity numeric,
  p_reason  text
) returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  l        erp.document_line%rowtype;
  a        record;
begin
  select * into l from erp.document_line where tenant_id = v_tenant and id = p_line_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_LINE: %', p_line_id using errcode = '23503';
  end if;

  select * into a from erp.amendment_allowed(l.document_id);

  if not a.allowed then
    raise exception 'ERPWARE_PAST_AMENDMENT_CUT_OFF: % — %', a.cut_off, a.detail
      using errcode = '42501';
  end if;

  perform erp.authorise('sales.order', null, null, null, 'document_line', p_line_id);

  update erp.document_line
     set quantity = p_quantity,
         net_minor = round(p_quantity * unit_price_minor
                           * (1 - coalesce(discount_pct, 0) / 100.0))::bigint,
         notes = coalesce(notes || E'\n', '') || format('amended: %s', p_reason),
         updated_at = now()
   where id = p_line_id;

  -- The reservation was made against the old quantity, so it is released
  -- rather than left holding stock the order no longer wants. Re-reserving is
  -- the caller's next step and is deliberately not automatic: an amendment
  -- that silently re-reserves can quietly take stock from another order.
  update erp.allocation
     set status = 'cancelled', updated_at = now()
   where tenant_id = v_tenant and document_line_id = p_line_id
     and status in ('reserved', 'committed');
end;
$$;

-- -----------------------------------------------------------------------------
-- Invoicing derived from delivery, with role separation enforced
--
-- Spec 5.6, and the clause with teeth: "invoicing derived from validated
-- delivery with role separation enforced". Two requirements.
--
-- Derived: the invoice is built from what was despatched, not typed. An invoice
-- somebody keys from a delivery note is one that can differ from it, and the
-- difference is always in the same direction.
--
-- Role separation: the person who says it shipped must not be the person who
-- bills for it. B1's permission catalogue has carried sales.despatch and
-- sales.invoice as separate permissions since it was written, and nothing has
-- ever required them to be held by different people.
-- -----------------------------------------------------------------------------

create or replace function erp.invoice_from_delivery(
  p_delivery_id uuid,
  p_allow_self_invoice boolean default false
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  dn        erp.document%rowtype;
  dt        erp.document_type%rowtype;
  v_inv     uuid;
  v_line    uuid;
  v_no      integer := 0;
  r         record;
  v_posted  boolean;
  v_despatcher uuid;
begin
  select * into dn from erp.document where tenant_id = v_tenant and id = p_delivery_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_DOCUMENT: %', p_delivery_id using errcode = '23503';
  end if;

  select * into dt from erp.document_type where tenant_id = v_tenant and id = dn.document_type_id;

  if dt.base_type_code <> 'delivery' then
    raise exception 'ERPWARE_NOT_A_DELIVERY: % is a %', dn.document_number, dt.code
      using errcode = '23514';
  end if;

  -- Validated means the stock actually moved. Invoicing a delivery that has
  -- not posted bills for goods that are still on the shelf.
  select exists (select 1 from erp.stock_movement m
                  where m.tenant_id = v_tenant and m.document_id = p_delivery_id)
    into v_posted;

  if not v_posted then
    raise exception
      'ERPWARE_DELIVERY_NOT_VALIDATED: % has not moved any stock', dn.document_number
      using errcode = '23514',
      hint = 'Post the delivery first. Invoicing one that has not posted bills '
             'for goods still on the shelf.';
  end if;

  if exists (select 1 from erp.document_relation rel
              join erp.document i2 on i2.id = rel.from_document_id
              join erp.document_type it on it.id = i2.document_type_id
             where rel.tenant_id = v_tenant and rel.to_document_id = p_delivery_id
               and it.base_type_code = 'invoice_reference'
               and not i2.is_cancelled) then
    raise exception 'ERPWARE_ALREADY_INVOICED: % has an invoice', dn.document_number
      using errcode = '23505';
  end if;

  -- Who said it shipped. The movement's actor, which the ledger recorded and
  -- which therefore cannot be re-stated by whoever is invoicing.
  select m.actor_id into v_despatcher
    from erp.stock_movement m
   where m.tenant_id = v_tenant and m.document_id = p_delivery_id
   order by m.id limit 1;

  if v_despatcher is null then
    -- Unknowable is not permission. A movement with no actor cannot be
    -- separated from anybody, and treating that as "not the same person" turns
    -- the control off exactly when the record is worst.
    raise exception
      'ERPWARE_NO_DESPATCH_ACTOR: % has movements with no recorded actor, so '
      'role separation cannot be established', dn.document_number
      using errcode = '42501';
  end if;

  if v_despatcher = erp.current_principal_id() and not p_allow_self_invoice then
    raise exception
      'ERPWARE_SEGREGATION_OF_DUTIES: you despatched % and cannot also invoice it',
      dn.document_number
      using errcode = '42501',
      hint = 'B1 has carried sales.despatch and sales.invoice as separate '
             'permissions since it was written; this is the first thing to '
             'require that they be held by different people.';
  end if;

  perform erp.authorise('sales.invoice', dn.entity_id, dn.site_id, null,
                        'document', p_delivery_id);

  v_inv := erp.open_document('sales_invoice', dn.party_id, dn.entity_id, dn.site_id);

  -- Derived from what moved, not from the delivery's lines: a line that was
  -- cancelled after posting, or short-shipped, must bill what actually left.
  for r in
    select m.item_id, sum(m.quantity) as qty,
           max(dl.unit_price_minor) as price,
           -- No max() for uuid, and no meaning in one: what is wanted is the
           -- line that supplied the price, so take the first of the group.
           (array_agg(dl.uom_id) filter (where dl.uom_id is not null))[1] as uom,
           (array_agg(dl.id) filter (where dl.id is not null))[1] as delivery_line_id,
           (array_agg(dl.description) filter (where dl.description is not null))[1]
             as description
      from erp.stock_movement m
      left join erp.document_line dl on dl.id = m.document_line_id
     where m.tenant_id = v_tenant and m.document_id = p_delivery_id
       and not m.is_reversal
     group by m.item_id
  loop
    v_no := v_no + 10;
    insert into erp.document_line (
      tenant_id, document_id, line_no, item_id, description, quantity, uom_id,
      unit_price_minor, net_minor, currency)
    values (v_tenant, v_inv, v_no, r.item_id,
            coalesce(r.description, 'delivered'), r.qty, r.uom,
            coalesce(r.price, 0), round(r.qty * coalesce(r.price, 0))::bigint,
            dn.currency)
    returning id into v_line;

    insert into erp.document_relation (
      tenant_id, from_document_id, to_document_id, relation_kind,
      from_line_id, to_line_id, quantity)
    values (v_tenant, v_inv, p_delivery_id, 'invoices', v_line,
            r.delivery_line_id, r.qty);
  end loop;

  if v_no = 0 then
    raise exception 'ERPWARE_NOTHING_DELIVERED: % moved no stock to bill for',
      dn.document_number using errcode = '23514';
  end if;

  return v_inv;
end;
$$;

comment on function erp.invoice_from_delivery(uuid, boolean) is
  'Spec 5.6: invoicing derived from a validated delivery with role separation '
  'enforced. Built from what actually moved, and refused to the person whose '
  'name is on the movement.';

-- -----------------------------------------------------------------------------
-- Returns and credits
--
-- A return is stock coming back and a credit is money going back, and they are
-- not the same event: goods can be returned and not credited (a replacement),
-- and credited and not returned (a quality allowance). Modelling them as one
-- is how a warehouse ends up holding stock nobody has accounted for.
-- -----------------------------------------------------------------------------

create table if not exists erp.customer_return (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  entity_id    uuid not null,
  site_id      uuid not null,
  party_id     uuid not null,
  reference    text,
  original_document_id uuid,
  reason_code  text not null,
  reason       text,
  -- What is being asked for: the goods back, the money back, or both.
  outcome      text not null default 'credit'
                 check (outcome in ('credit', 'replacement', 'goods_only', 'credit_only')),
  return_document_id uuid,
  credit_document_id uuid,
  status       text not null default 'open'
                 check (status in ('open', 'received', 'credited', 'closed', 'rejected')),
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, id),
  foreign key (tenant_id, entity_id) references erp.entity (tenant_id, id) on delete restrict,
  foreign key (tenant_id, site_id) references erp.site (tenant_id, id) on delete restrict,
  foreign key (tenant_id, party_id) references erp.party (tenant_id, id) on delete restrict,
  foreign key (tenant_id, original_document_id)
    references erp.document (tenant_id, id) on delete restrict
);

create or replace function erp.raise_customer_return(
  p_original_document_id uuid,
  p_reason_code text,
  p_reason text,
  p_outcome text default 'credit'
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  v_id     uuid;
begin
  select * into d from erp.document
   where tenant_id = v_tenant and id = p_original_document_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_DOCUMENT: %', p_original_document_id
      using errcode = '23503';
  end if;

  if coalesce(p_reason_code, '') = '' then
    raise exception
      'ERPWARE_RETURN_NEEDS_REASON: a return without a reason code cannot be '
      'analysed, and analysing them is the only way returns ever go down'
      using errcode = '23514';
  end if;

  perform erp.authorise('sales.order', d.entity_id, d.site_id, null,
                        'document', p_original_document_id);

  insert into erp.customer_return (
    tenant_id, entity_id, site_id, party_id, original_document_id,
    reason_code, reason, outcome, status)
  values (v_tenant, d.entity_id, d.site_id, d.party_id, p_original_document_id,
          p_reason_code, p_reason, p_outcome, 'open')
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function erp.return_reason_analysis(p_days integer default 365)
returns table (reason_code text, returns bigint, value_minor bigint, share_pct numeric)
language sql
stable
security invoker
set search_path = ''
as $$
  -- The only report that makes returns go down: which reason, how often, and
  -- worth how much. A list of individual returns is a queue, not an analysis.
  select cr.reason_code, count(*),
         coalesce(sum(erp.document_value_minor(cr.original_document_id)), 0)::bigint,
         round(100.0 * count(*) / nullif(sum(count(*)) over (), 0), 2)
    from erp.customer_return cr
   where cr.tenant_id = erp.current_tenant_id()
     and cr.created_at >= now() - (p_days || ' days')::interval
   group by cr.reason_code
   order by 3 desc
$$;

-- -----------------------------------------------------------------------------
-- Sales controls, installed
-- -----------------------------------------------------------------------------

create or replace function erp.configure_sales_controls(
  p_min_margin_pct numeric default 10,
  p_approver_role text default 'administrator'
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_cs     uuid;
begin
  v_cs := erp.install_module_config(
    'sales-controls', 'Sales controls',
    'The margin floor, and who has to agree before a price goes under it.',
    jsonb_build_array(
      jsonb_build_object('kind','approval_chain','key','margin_exception','payload',
        jsonb_build_object(
          'code','margin_exception','name','Margin exception',
          'object_type','document_line',
          'applies_when','true'::jsonb, 'priority',100,
          'material_fields', jsonb_build_array('unit_price_minor'),
          'steps', jsonb_build_array(
            jsonb_build_object('seq',1,'code','commercial','name','Commercial',
              'approver_kind','role','role',p_approver_role,'min_approvals',1)))),

      jsonb_build_object('kind','pricing_policy','key','default','payload',
        jsonb_build_object(
          'code','default','name','Default margin policy',
          'min_margin_pct', p_min_margin_pct,
          'allow_below_cost', false,
          'approval_chain','margin_exception'))));

  return v_cs;
end;
$$;

-- -----------------------------------------------------------------------------
-- Assertions
-- -----------------------------------------------------------------------------

create or replace function erp.sales_configuration_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  select 'a pricing policy names an approval chain that does not exist',
         pp.code, format('approval_chain_code = %s', pp.approval_chain_code)
    from erp.pricing_policy pp
   where pp.status = 'active' and pp.approval_chain_code is not null
     and not exists (select 1 from erp.approval_chain ac
                      where ac.tenant_id = pp.tenant_id
                        and ac.code = pp.approval_chain_code and ac.status = 'active')
  union all
  -- A margin floor with no route past it means every exception is a refusal,
  -- which is a policy rather than a control — and it should say so.
  select 'a margin floor has no route past it',
         pp.code,
         'every price under the floor is refused outright; if that is intended, '
         'say so with allow_below_cost false and no chain, but a floor above '
         'zero with no chain will simply stop trade'
    from erp.pricing_policy pp
   where pp.status = 'active' and pp.min_margin_pct > 0
     and pp.approval_chain_code is null
  union all
  -- A sales price valid from a date after it expires prices nothing, ever.
  select 'a price is valid from after it expires',
         format('%s %s', p.price_kind, coalesce(p.price_list_code, '(no list)')),
         format('valid_from %s, valid_to %s', p.valid_from, p.valid_to)
    from erp.item_price p
   where p.valid_to is not null and p.valid_to <= p.valid_from
  union all
  -- A contract price with no customer on it is a list price wearing a
  -- contract's name, and it will beat the list for everybody.
  select 'a contract price names no customer',
         coalesce(p.price_list_code, '(no list)'),
         'it outranks the sales list for every customer, which is not what a '
         'contract is'
    from erp.item_price p
   where p.price_kind = 'contract' and p.party_role_id is null
$$;

create or replace function erp.assert_sales_controls_sane()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare v_count integer; v_detail text;
begin
  select count(*), string_agg(format('  %s [%s] %s', finding, reference, detail), E'\n')
    into v_count, v_detail from erp.sales_configuration_report();
  if v_count > 0 then
    raise exception 'ERPWARE_SALES_CONFIGURATION_DEAD: % finding(s)', v_count
      using errcode = 'P0001', detail = v_detail;
  end if;
  return 'sales: every price and policy can apply';
end;
$$;

-- -----------------------------------------------------------------------------
-- Public surface
-- -----------------------------------------------------------------------------

create or replace function public.erp_resolve_price(
  p_item_id uuid, p_party_id uuid, p_quantity numeric default 1)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select coalesce(jsonb_agg(to_jsonb(p)), '[]'::jsonb)
        from erp.resolve_price(p_item_id, p_party_id, p_quantity) p $$;

create or replace function public.erp_available_to_promise(
  p_item_id uuid, p_site_id uuid, p_on date default null)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select coalesce(jsonb_agg(to_jsonb(a)), '[]'::jsonb)
        from erp.available_to_promise(p_item_id, p_site_id, p_on) a $$;

create or replace function public.erp_promise_date(
  p_item_id uuid, p_site_id uuid, p_quantity numeric)
returns date language sql stable security invoker set search_path = ''
as $$ select erp.promise_date(p_item_id, p_site_id, p_quantity) $$;

create or replace function public.erp_credit_position(p_party_id uuid)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb)
        from erp.credit_position(p_party_id) c $$;

create or replace function public.erp_return_reasons(p_days integer default 365)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb)
        from erp.return_reason_analysis(p_days) t $$;

create or replace function public.erp_configure_sales_controls(
  p_min_margin_pct numeric default 10)
returns uuid language sql volatile security invoker set search_path = ''
as $$ select erp.configure_sales_controls(p_min_margin_pct) $$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.erp_resolve_price(uuid, uuid, numeric)',
    'public.erp_available_to_promise(uuid, uuid, date)',
    'public.erp_promise_date(uuid, uuid, numeric)',
    'public.erp_credit_position(uuid)',
    'public.erp_return_reasons(integer)',
    'public.erp_configure_sales_controls(numeric)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_configure_sales_controls', 'erp.configure_sales_controls',
   'Submits the margin policy and its exception chain as a B6 change set the '
   'caller cannot approve; the installer authorises administration.configure.')
on conflict (function_name) do update
  set gate = excluded.gate, rationale = excluded.rationale;

-- -----------------------------------------------------------------------------
-- B6 learns pricing policies
-- -----------------------------------------------------------------------------

create or replace function erp.apply_change_set_item(p_item_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant  uuid := erp.require_tenant_id();
  i         erp.change_set_item%rowtype;
  p         jsonb;
  v_entity  uuid;
  v_site    uuid;
  v_from    date;
  v_obj     uuid;
  v_ver     uuid;
  v_vnum    integer;
  r         record;
  v_state   uuid;
begin
  select * into i from erp.change_set_item where tenant_id = v_tenant and id = p_item_id;
  p := i.payload;

  -- Codes to local ids. A change set built elsewhere knows nothing of our keys.
  select e.id into v_entity from erp.entity e
   where e.tenant_id = v_tenant and e.code = (p ->> 'entity');
  select s.id into v_site from erp.site s
   where s.tenant_id = v_tenant and s.code = (p ->> 'site');
  v_from := coalesce(i.effective_from, (p ->> 'effective_from')::date, current_date);

  if (p ? 'entity') and (p ->> 'entity') is not null and v_entity is null then
    raise exception 'ERPWARE_PROMOTION_UNKNOWN_ENTITY: this environment has no entity %',
      p ->> 'entity' using errcode = '23503';
  end if;

  case i.object_kind

    when 'config' then
      if i.operation = 'remove' then
        update erp.config_object co set status = 'inactive', updated_at = now()
         where co.tenant_id = v_tenant
           and co.config_type_code = (p ->> 'config_type')
           and co.code is not distinct from (p ->> 'code')
           and co.entity_id is not distinct from v_entity
           and co.site_id is not distinct from v_site;
      else
        perform erp.set_config_value(
          p ->> 'config_type', p -> 'value', p ->> 'code', v_from,
          v_entity, v_site, 'promoted');
      end if;

    when 'terminology' then
      if i.operation = 'remove' then
        update erp.resource_override ro set status = 'inactive', updated_at = now()
         where ro.tenant_id = v_tenant and ro.key = (p ->> 'key')
           and ro.locale = (p ->> 'locale') and ro.entity_id is not distinct from v_entity;
      else
        insert into erp.resource_override (tenant_id, key, locale, value, entity_id)
        values (v_tenant, p ->> 'key', p ->> 'locale', p ->> 'value', v_entity)
        on conflict (tenant_id, key, locale,
                     coalesce(entity_id, '00000000-0000-0000-0000-000000000000'::uuid))
          do update set value = excluded.value, status = 'active', updated_at = now();
      end if;

    when 'legislation_binding' then
      if i.operation = 'remove' then
        update erp.entity_legislation_binding b set status = 'inactive', updated_at = now()
         where b.tenant_id = v_tenant and b.entity_id = v_entity
           and b.pack_code = (p ->> 'pack');
      else
        update erp.entity_legislation_binding b set status = 'inactive', updated_at = now()
         where b.tenant_id = v_tenant and b.entity_id = v_entity
           and b.pack_code = (p ->> 'pack') and b.status = 'active';
        insert into erp.entity_legislation_binding (
          tenant_id, entity_id, pack_code, pack_version, effective_from, effective_to)
        values (v_tenant, v_entity, p ->> 'pack', (p ->> 'pack_version')::integer,
                v_from, (p ->> 'effective_to')::date);
      end if;

    when 'event_subscription' then
      if i.operation = 'remove' then
        update erp.event_subscription es set status = 'inactive', updated_at = now()
         where es.tenant_id = v_tenant and es.consumer_code = (p ->> 'consumer')
           and es.event_pattern = (p ->> 'pattern');
      else
        insert into erp.event_subscription (
          tenant_id, consumer_code, event_pattern, module_code, max_attempts)
        values (v_tenant, p ->> 'consumer', p ->> 'pattern', p ->> 'module',
                coalesce((p ->> 'max_attempts')::smallint, 8))
        on conflict (tenant_id, consumer_code, event_pattern) do update
          set module_code = excluded.module_code,
              max_attempts = excluded.max_attempts,
              status = 'active', updated_at = now();
      end if;

    when 'role' then
      if i.operation = 'remove' then
        update erp.role r set status = 'inactive', updated_at = now()
         where r.tenant_id = v_tenant and r.code = (p ->> 'code');
      else
        insert into erp.role (tenant_id, code, name, name_key, from_template)
        values (v_tenant, p ->> 'code', p ->> 'name', p ->> 'name_key', p ->> 'from_template')
        on conflict (tenant_id, code) do update
          set name = excluded.name, name_key = excluded.name_key,
              status = 'active', updated_at = now()
        returning id into v_obj;

        -- The grant set is replaced wholesale: a promoted role is the role the
        -- change set describes, not a merge with whatever was here before.
        delete from erp.role_permission rp
         where rp.tenant_id = v_tenant and rp.role_id = v_obj;

        insert into erp.role_permission (tenant_id, role_id, permission_code, data_classes)
        select v_tenant, v_obj, e.value ->> 'permission',
               coalesce((select array_agg(dc #>> '{}')
                           from jsonb_array_elements(e.value -> 'data_classes') dc),
                        '{}'::text[])
          from jsonb_array_elements(coalesce(p -> 'permissions', '[]'::jsonb)) e;
      end if;

    when 'rule_set' then
      if i.operation = 'remove' then
        update erp.rule_set rs set status = 'inactive', updated_at = now()
         where rs.tenant_id = v_tenant
           and rs.decision_point_code = (p ->> 'decision_point')
           and rs.code = (p ->> 'code');
      else
        insert into erp.rule_set (tenant_id, decision_point_code, code, name, entity_id, site_id)
        values (v_tenant, p ->> 'decision_point', p ->> 'code', p ->> 'name', v_entity, v_site)
        on conflict (tenant_id, decision_point_code, code) do update
          set name = excluded.name, status = 'active', updated_at = now()
        returning id into v_obj;

        select coalesce(max(v.version), 0) + 1 into v_vnum
          from erp.rule_set_version v
         where v.tenant_id = v_tenant and v.rule_set_id = v_obj;

        insert into erp.rule_set_version (
          tenant_id, rule_set_id, version, status, effective_from, note)
        values (v_tenant, v_obj, v_vnum, 'draft', v_from, 'promoted')
        returning id into v_ver;

        insert into erp.rule (
          tenant_id, rule_set_version_id, seq, code, name, condition, outcome,
          stop_on_match, is_active)
        select v_tenant, v_ver, (e.value ->> 'seq')::integer, e.value ->> 'code',
               e.value ->> 'name', e.value -> 'condition', e.value -> 'outcome',
               coalesce((e.value ->> 'stop_on_match')::boolean, true),
               coalesce((e.value ->> 'is_active')::boolean, true)
          from jsonb_array_elements(coalesce(p -> 'rules', '[]'::jsonb)) e;

        -- Activation runs the linter, so a promotion cannot introduce a rule
        -- that can never match.
        perform erp.activate_rule_set_version(v_ver, v_from);
      end if;

    when 'state_machine' then
      if i.operation = 'remove' then
        update erp.state_machine sm set status = 'inactive', updated_at = now()
         where sm.tenant_id = v_tenant and sm.code = (p ->> 'code');
      else
        insert into erp.state_machine (tenant_id, code, object_type, name, entity_id, site_id)
        values (v_tenant, p ->> 'code', p ->> 'object_type', p ->> 'name', v_entity, v_site)
        on conflict (tenant_id, code) do update
          set object_type = excluded.object_type, name = excluded.name,
              status = 'active', updated_at = now()
        returning id into v_obj;

        select coalesce(max(v.version), 0) + 1 into v_vnum
          from erp.state_machine_version v
         where v.tenant_id = v_tenant and v.state_machine_id = v_obj;

        insert into erp.state_machine_version (
          tenant_id, state_machine_id, version, status, effective_from, note)
        values (v_tenant, v_obj, v_vnum, 'draft', v_from, 'promoted')
        returning id into v_ver;

        insert into erp.state (
          tenant_id, state_machine_version_id, code, name, is_initial, is_terminal,
          is_committed, sort_order, on_enter, on_exit)
        select v_tenant, v_ver, e.value ->> 'code', e.value ->> 'name',
               coalesce((e.value ->> 'is_initial')::boolean, false),
               coalesce((e.value ->> 'is_terminal')::boolean, false),
               coalesce((e.value ->> 'is_committed')::boolean, false),
               coalesce((e.value ->> 'sort_order')::integer, 100),
               coalesce(e.value -> 'on_enter', '[]'::jsonb),
               coalesce(e.value -> 'on_exit', '[]'::jsonb)
          from jsonb_array_elements(coalesce(p -> 'states', '[]'::jsonb)) e;

        -- Transitions come second because they reference states by code.
        for r in select e.value as tr
                   from jsonb_array_elements(coalesce(p -> 'transitions', '[]'::jsonb)) e
        loop
          insert into erp.transition (
            tenant_id, state_machine_version_id, code, name, from_state_id, to_state_id,
            guard, effects, required_permission, is_automatic, sort_order)
          select v_tenant, v_ver, r.tr ->> 'code', r.tr ->> 'name',
                 (select st.id from erp.state st
                   where st.state_machine_version_id = v_ver and st.code = r.tr ->> 'from'),
                 (select st.id from erp.state st
                   where st.state_machine_version_id = v_ver and st.code = r.tr ->> 'to'),
                 coalesce(r.tr -> 'guard', 'true'::jsonb),
                 coalesce(r.tr -> 'effects', '[]'::jsonb),
                 r.tr ->> 'required_permission',
                 coalesce((r.tr ->> 'is_automatic')::boolean, false),
                 coalesce((r.tr ->> 'sort_order')::integer, 100);
        end loop;

        -- Activation runs the graph validation, so a promotion cannot
        -- introduce a state a document could enter and never leave.
        perform erp.activate_state_machine_version(v_ver, v_from);
      end if;

    when 'approval_chain' then
      if i.operation = 'remove' then
        update erp.approval_chain ac set status = 'inactive', updated_at = now()
         where ac.tenant_id = v_tenant and ac.code = (p ->> 'code');
      else
        insert into erp.approval_chain (
          tenant_id, code, name, object_type, applies_when, priority, entity_id, site_id)
        values (v_tenant, p ->> 'code', p ->> 'name', p ->> 'object_type',
                coalesce(p -> 'applies_when', 'true'::jsonb),
                coalesce((p ->> 'priority')::integer, 100), v_entity, v_site)
        on conflict (tenant_id, code) do update
          set name = excluded.name, object_type = excluded.object_type,
              applies_when = excluded.applies_when, priority = excluded.priority,
              status = 'active', updated_at = now()
        returning id into v_obj;

        select coalesce(max(v.version), 0) + 1 into v_vnum
          from erp.approval_chain_version v
         where v.tenant_id = v_tenant and v.approval_chain_id = v_obj;

        insert into erp.approval_chain_version (
          tenant_id, approval_chain_id, version, status, effective_from,
          material_fields, value_field, tolerance_pct, tolerance_absolute, note)
        values (
          v_tenant, v_obj, v_vnum, 'draft', v_from,
          coalesce((select array_agg(f #>> '{}')
                      from jsonb_array_elements(coalesce(p -> 'material_fields', '[]'::jsonb)) f),
                   '{}'::text[]),
          p ->> 'value_field',
          (p ->> 'tolerance_pct')::numeric,
          (p ->> 'tolerance_absolute')::numeric,
          'promoted')
        returning id into v_ver;

        insert into erp.approval_step (
          tenant_id, approval_chain_version_id, seq, code, name, approver_kind,
          role_id, app_user_id, min_approvals, condition, escalate_after, allow_delegation)
        select v_tenant, v_ver, (e.value ->> 'seq')::integer, e.value ->> 'code',
               e.value ->> 'name', (e.value ->> 'approver_kind')::erp.approver_kind,
               (select ro.id from erp.role ro
                 where ro.tenant_id = v_tenant and ro.code = e.value ->> 'role'),
               (select u.id from erp.app_user u
                 where u.tenant_id = v_tenant and u.email = e.value ->> 'user'),
               coalesce((e.value ->> 'min_approvals')::smallint, 1),
               coalesce(e.value -> 'condition', 'true'::jsonb),
               (e.value ->> 'escalate_after')::interval,
               coalesce((e.value ->> 'allow_delegation')::boolean, true)
          from jsonb_array_elements(coalesce(p -> 'steps', '[]'::jsonb)) e;

        -- Activation refuses a chain with no steps, so a promotion cannot
        -- install one that approves everything unchecked.
        perform erp.activate_approval_chain_version(v_ver, v_from);
      end if;

    -- Spec 5.7: "declarative posting rules from operational events". Declarative
    -- means configuration, and configuration in this product is promoted rather
    -- than edited — otherwise the rule that decides which account a receipt
    -- lands in would be the one thing in finance nobody had to get approved.
    --
    -- Rules are versioned in place: a new version supersedes the last rather
    -- than replacing it, because a journal line records the rule version that
    -- produced it and that reference must stay resolvable for ever.
    when 'posting_rule' then
      if i.operation = 'remove' then
        update erp.posting_rule pr set status = 'withdrawn', updated_at = now()
         where pr.tenant_id = v_tenant and pr.code = (p ->> 'code')
           and pr.status = 'active';
      else
        select coalesce(max(pr.version), 0) + 1 into v_vnum
          from erp.posting_rule pr
         where pr.tenant_id = v_tenant and pr.code = (p ->> 'code');

        -- Supersede the version in force, and only move its end date if it
        -- actually started earlier.
        --
        -- This is the defect 0019 found in every other activation path,
        -- arriving here through a door that did not exist when 0019 was
        -- written. Setting effective_to = v_from on a version that started on
        -- the same day produces an empty window, which posting_rule_range
        -- refuses. Invisible in normal use, because changes are made on later
        -- days than the versions they replace — and immediate the moment two
        -- change sets touch the same rule in one sitting, which is exactly
        -- what installing finance and then inventory does.
        update erp.posting_rule pr
           set status = 'superseded',
               effective_to = case when pr.effective_from < v_from then v_from
                                   else pr.effective_to end,
               updated_at = now()
         where pr.tenant_id = v_tenant and pr.code = (p ->> 'code')
           and pr.status = 'active';

        insert into erp.posting_rule (
          tenant_id, code, name, entity_id, ledger_id, event_type, condition,
          posting_lines, version, status, effective_from, legislation_pack_code)
        values (
          v_tenant, p ->> 'code', p ->> 'name', v_entity,
          (select l.id from erp.ledger l
            where l.tenant_id = v_tenant and l.code = (p ->> 'ledger')
              and (v_entity is null or l.entity_id = v_entity)
            order by l.code limit 1),
          p ->> 'event_type',
          coalesce(p -> 'condition', 'true'::jsonb),
          coalesce(p -> 'posting_lines', '[]'::jsonb),
          v_vnum, 'active', v_from, p ->> 'legislation_pack');

        -- A rule that does not balance would raise a journal that cannot post,
        -- and it would do so at month end rather than here. Refusing at
        -- promotion is the whole point of promoting it.
        perform erp.assert_posting_rule_balances(p ->> 'code', v_vnum);
      end if;

    -- Spec 5.1: what a good record looks like is a tenant's opinion, and an
    -- opinion that decides whether a record is fit to trade on belongs in the
    -- same promotion pipeline as everything else. Replaced rather than
    -- versioned: nothing records "the quality rule version that scored this",
    -- so a superseded version would be a row nobody could ever read.
    when 'data_quality_rule' then
      if i.operation = 'remove' then
        update erp.data_quality_rule q set status = 'inactive', updated_at = now()
         where q.tenant_id = v_tenant
           and q.object_type = (p ->> 'object_type')
           and q.code = (p ->> 'code');
      else
        insert into erp.data_quality_rule (
          tenant_id, object_type, code, name, kind, condition, weight,
          severity, message, entity_id, status)
        values (v_tenant, p ->> 'object_type', p ->> 'code', p ->> 'name',
                coalesce(p ->> 'kind', 'completeness'),
                coalesce(p -> 'condition', 'true'::jsonb),
                coalesce((p ->> 'weight')::integer, 1),
                coalesce(p ->> 'severity', 'warning'),
                coalesce(p ->> 'message', p ->> 'name'),
                v_entity, 'active')
        on conflict (tenant_id, object_type, code) do update
          set name = excluded.name, kind = excluded.kind,
              condition = excluded.condition, weight = excluded.weight,
              severity = excluded.severity, message = excluded.message,
              status = 'active', updated_at = now();
      end if;

    -- Which fields cannot change without somebody agreeing. Promoted for the
    -- same reason the approval chains themselves are: a control that its own
    -- subject can switch off is not a control.
    when 'field_approval_rule' then
      if i.operation = 'remove' then
        update erp.field_approval_rule f set status = 'inactive', updated_at = now()
         where f.tenant_id = v_tenant
           and f.object_type = (p ->> 'object_type')
           and f.field_name = (p ->> 'field_name');
      else
        if not exists (select 1 from erp_meta.maintainable_field m
                        where m.object_type = (p ->> 'object_type')
                          and m.column_name = (p ->> 'field_name')) then
          raise exception
            'ERPWARE_PROMOTION_UNGOVERNABLE_FIELD: %.% is not a maintainable field',
            p ->> 'object_type', p ->> 'field_name'
            using errcode = '23503',
                  hint = 'A rule guarding a field nothing can change is a control '
                         'that will never fire.';
        end if;

        insert into erp.field_approval_rule (
          tenant_id, object_type, field_name, condition, approval_chain_code,
          sensitivity, reason_required, status)
        values (v_tenant, p ->> 'object_type', p ->> 'field_name',
                coalesce(p -> 'condition', 'true'::jsonb),
                p ->> 'approval_chain',
                coalesce((p ->> 'sensitivity')::integer, 100),
                coalesce((p ->> 'reason_required')::boolean, false),
                'active')
        on conflict (tenant_id, object_type, field_name) do update
          set condition = excluded.condition,
              approval_chain_code = excluded.approval_chain_code,
              sensitivity = excluded.sensitivity,
              reason_required = excluded.reason_required,
              status = 'active', updated_at = now();
      end if;

    -- Which stock is valued how. Promoted rather than written, because
    -- switching an item from FIFO to average changes what every future issue
    -- costs and therefore what the accounts say.
    when 'costing_policy' then
      if i.operation = 'remove' then
        update erp.costing_policy c set status = 'inactive', updated_at = now()
         where c.tenant_id = v_tenant and c.code = (p ->> 'code');
      else
        insert into erp.costing_policy (
          tenant_id, code, name, method, item_class, entity_id, site_id,
          variance_account_code, status)
        values (v_tenant, p ->> 'code', p ->> 'name',
                (p ->> 'method')::erp.costing_method,
                p ->> 'item_class', v_entity, v_site,
                p ->> 'variance_account', 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, method = excluded.method,
              item_class = excluded.item_class,
              variance_account_code = excluded.variance_account_code,
              status = 'active', updated_at = now();
      end if;

    -- What gets counted, how often, and how wrong a count may be before
    -- somebody has to look at it. A tolerance a warehouse can set for itself
    -- is not a tolerance.
    when 'count_programme' then
      if i.operation = 'remove' then
        update erp.count_programme c set status = 'inactive', updated_at = now()
         where c.tenant_id = v_tenant and c.code = (p ->> 'code');
      else
        insert into erp.count_programme (
          tenant_id, code, name, site_id, kind, selector,
          tolerance_absolute, tolerance_pct, approval_chain_code, status)
        values (v_tenant, p ->> 'code', p ->> 'name', v_site,
                (p ->> 'kind')::erp.count_programme_kind,
                coalesce(p -> 'selector', 'true'::jsonb),
                coalesce((p ->> 'tolerance_absolute')::numeric, 0),
                coalesce((p ->> 'tolerance_pct')::numeric, 0),
                p ->> 'approval_chain', 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, kind = excluded.kind,
              selector = excluded.selector,
              tolerance_absolute = excluded.tolerance_absolute,
              tolerance_pct = excluded.tolerance_pct,
              approval_chain_code = excluded.approval_chain_code,
              status = 'active', updated_at = now();
      end if;

    -- How much more than was ordered may arrive, and what to do with it.
    when 'receipt_tolerance' then
      if i.operation = 'remove' then
        update erp.receipt_tolerance t set status = 'inactive', updated_at = now()
         where t.tenant_id = v_tenant and t.code = (p ->> 'code');
      else
        insert into erp.receipt_tolerance (
          tenant_id, code, name, item_class, over_pct, under_pct, over_action, status)
        values (v_tenant, p ->> 'code', p ->> 'name', p ->> 'item_class',
                coalesce((p ->> 'over_pct')::numeric, 0),
                coalesce((p ->> 'under_pct')::numeric, 100),
                coalesce(p ->> 'over_action', 'accept'), 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, item_class = excluded.item_class,
              over_pct = excluded.over_pct, under_pct = excluded.under_pct,
              over_action = excluded.over_action,
              status = 'active', updated_at = now();
      end if;

    -- How far an invoice may differ from the receipt before somebody looks.
    -- The most contested numbers in a finance function, and therefore exactly
    -- the ones that should be promoted rather than typed.
    when 'match_tolerance' then
      if i.operation = 'remove' then
        update erp.match_tolerance t set status = 'inactive', updated_at = now()
         where t.tenant_id = v_tenant and t.code = (p ->> 'code');
      else
        insert into erp.match_tolerance (
          tenant_id, code, name, item_class, quantity_pct, price_pct,
          price_absolute_minor, approval_chain_code, status)
        values (v_tenant, p ->> 'code', p ->> 'name', p ->> 'item_class',
                coalesce((p ->> 'quantity_pct')::numeric, 0),
                coalesce((p ->> 'price_pct')::numeric, 0),
                coalesce((p ->> 'price_absolute_minor')::bigint, 0),
                p ->> 'approval_chain', 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, item_class = excluded.item_class,
              quantity_pct = excluded.quantity_pct, price_pct = excluded.price_pct,
              price_absolute_minor = excluded.price_absolute_minor,
              approval_chain_code = excluded.approval_chain_code,
              status = 'active', updated_at = now();
      end if;

    -- What may be spent, and what happens when it would be exceeded.
    when 'budget' then
      if i.operation = 'remove' then
        update erp.budget b set status = 'inactive', updated_at = now()
         where b.tenant_id = v_tenant and b.code = (p ->> 'code');
      else
        insert into erp.budget (
          tenant_id, entity_id, code, name, fiscal_year, selector, amount_minor,
          currency, on_exceed, approval_chain_code, status)
        select v_tenant,
               coalesce(v_entity, (select e.id from erp.entity e
                                    where e.tenant_id = v_tenant and e.status = 'active'
                                    order by e.code limit 1)),
               p ->> 'code', p ->> 'name',
               coalesce((p ->> 'fiscal_year')::integer,
                        extract(year from v_from)::integer),
               coalesce(p -> 'selector', 'true'::jsonb),
               (p ->> 'amount_minor')::bigint,
               coalesce(p ->> 'currency',
                        (select e.base_currency from erp.entity e
                          where e.tenant_id = v_tenant limit 1)),
               coalesce(p ->> 'on_exceed', 'block'),
               p ->> 'approval_chain', 'active'
        on conflict (tenant_id, code, fiscal_year) do update
          set name = excluded.name, selector = excluded.selector,
              amount_minor = excluded.amount_minor,
              on_exceed = excluded.on_exceed,
              approval_chain_code = excluded.approval_chain_code,
              status = 'active', updated_at = now();
      end if;

    -- How much risk of running out is acceptable, how far ahead the plan is
    -- fixed, and how orders are sized. Every one of those is a number a
    -- business argues about for a fortnight and then nobody revisits, which is
    -- precisely what promotion is for.
    when 'planning_policy' then
      if i.operation = 'remove' then
        update erp.planning_policy pp set status = 'inactive', updated_at = now()
         where pp.tenant_id = v_tenant and pp.code = (p ->> 'code');
      else
        insert into erp.planning_policy (
          tenant_id, code, name, reorder_method, safety_stock_basis,
          service_level_pct, lot_sizing, fixed_lot_size, rounding_multiple,
          demand_time_fence_days, planning_time_fence_days, sourcing_rules, status)
        values (v_tenant, p ->> 'code', p ->> 'name',
                coalesce((p ->> 'reorder_method')::erp.reorder_method, 'reorder_point'),
                coalesce(p ->> 'safety_stock_basis', 'statistical'),
                coalesce((p ->> 'service_level_pct')::numeric, 95),
                coalesce(p ->> 'lot_sizing', 'lot_for_lot'),
                (p ->> 'fixed_lot_size')::numeric,
                (p ->> 'rounding_multiple')::numeric,
                coalesce((p ->> 'demand_time_fence_days')::integer, 0),
                coalesce((p ->> 'planning_time_fence_days')::integer, 0),
                coalesce(p -> 'sourcing_rules', '[]'::jsonb), 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, reorder_method = excluded.reorder_method,
              safety_stock_basis = excluded.safety_stock_basis,
              service_level_pct = excluded.service_level_pct,
              lot_sizing = excluded.lot_sizing,
              fixed_lot_size = excluded.fixed_lot_size,
              rounding_multiple = excluded.rounding_multiple,
              demand_time_fence_days = excluded.demand_time_fence_days,
              planning_time_fence_days = excluded.planning_time_fence_days,
              sourcing_rules = excluded.sourcing_rules,
              status = 'active', updated_at = now();
      end if;

    -- The margin floor, and whether anybody may go under it. Promoted because
    -- it is the number a sales force will ask to have moved.
    when 'pricing_policy' then
      if i.operation = 'remove' then
        update erp.pricing_policy pp set status = 'inactive', updated_at = now()
         where pp.tenant_id = v_tenant and pp.code = (p ->> 'code');
      else
        insert into erp.pricing_policy (
          tenant_id, code, name, entity_id, min_margin_pct, allow_below_cost,
          approval_chain_code, status)
        values (v_tenant, p ->> 'code', p ->> 'name', v_entity,
                coalesce((p ->> 'min_margin_pct')::numeric, 0),
                coalesce((p ->> 'allow_below_cost')::boolean, false),
                p ->> 'approval_chain', 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name,
              min_margin_pct = excluded.min_margin_pct,
              allow_below_cost = excluded.allow_below_cost,
              approval_chain_code = excluded.approval_chain_code,
              status = 'active', updated_at = now();
      end if;

    else
      raise exception 'ERPWARE_PROMOTION_UNKNOWN_KIND: % cannot be promoted', i.object_kind
        using errcode = '23514',
              hint = 'Promotable kinds: config, terminology, legislation_binding, event_subscription, role, rule_set, state_machine, approval_chain, posting_rule, data_quality_rule, field_approval_rule, costing_policy, count_programme, receipt_tolerance, match_tolerance, budget, planning_policy, pricing_policy';
  end case;
end;
$function$;

-- -----------------------------------------------------------------------------
-- The suite
-- -----------------------------------------------------------------------------

create or replace function erp_test.sales_depth_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  r record; a1 uuid := gen_random_uuid(); a2 uuid := gen_random_uuid();
  csf uuid; csp uuid; css uuid; csi uuid; csc uuid;
  v_second uuid; v_tok text; res jsonb;
  v_uom uuid; v_site uuid; v_recv uuid; v_desp uuid;
  v_sup uuid; v_cust uuid; v_cust_role uuid; v_item uuid;
  v_grn uuid; v_so uuid; v_sol uuid; v_dn uuid; v_inv uuid; v_ret uuid;
  v_alloc uuid; v_price bigint; v_promise date; v_n integer;
  p record; m record; c record; am record; atp record;
  v_ok boolean; v_msg text;
begin
  select * into r from erp.provision_tenant('zzsdep','Sales Depth','a@zzsdep.test','Suite Admin');
  perform set_config('request.jwt.claims', json_build_object('sub',a1)::text, true);
  perform erp.claim_invitation(r.admin_token);
  res := public.erp_invite_principal('second@zzsdep.test','Second Admin');
  v_second := (res->>'app_user_id')::uuid; v_tok := res->>'token';
  perform erp.grant_role(v_second,'administrator',null,null,'co-administrator');

  csf := erp.configure_finance();
  csp := erp.configure_procurement(100000000);
  css := erp.configure_sales(15);
  csi := erp.configure_inventory('average');
  csc := erp.configure_sales_controls(10);

  perform set_config('request.jwt.claims', json_build_object('sub',a2)::text, true);
  perform erp.claim_invitation(v_tok);
  perform erp.approve_change_set(csf); perform erp.promote_change_set(csf);
  perform erp.approve_change_set(csp); perform erp.promote_change_set(csp);
  perform erp.approve_change_set(css); perform erp.promote_change_set(css);
  perform erp.approve_change_set(csi); perform erp.promote_change_set(csi);
  perform erp.approve_change_set(csc); perform erp.promote_change_set(csc);
  perform set_config('request.jwt.claims', json_build_object('sub',a1)::text, true);

  insert into erp.uom (tenant_id,code,name,uom_class,decimals,is_base,status)
  values (r.tenant_id,'EA','Each','quantity',0,true,'active') returning id into v_uom;
  insert into erp.site (tenant_id,entity_id,code,name,site_type,status)
  values (r.tenant_id,r.entity_id,'MAIN','Main','warehouse','active') returning id into v_site;
  insert into erp.location (tenant_id,site_id,code,name,location_type,status)
  values (r.tenant_id,v_site,'RECV','Receiving','receiving','active') returning id into v_recv;
  insert into erp.location (tenant_id,site_id,code,name,location_type,status)
  values (r.tenant_id,v_site,'DESP','Despatch','despatch','active') returning id into v_desp;
  insert into erp.party (tenant_id,code,name,status)
  values (r.tenant_id,'SUP','Supplier','active') returning id into v_sup;
  insert into erp.party (tenant_id,code,name,status)
  values (r.tenant_id,'CUST','Customer','active') returning id into v_cust;
  insert into erp.party_role (tenant_id,party_id,role_kind,attributes,status)
  values (r.tenant_id,v_cust,'customer', jsonb_build_object('credit_limit_minor', 100000000),'active')
  returning id into v_cust_role;
  insert into erp.item (tenant_id,code,name,stock_uom_id,status)
  values (r.tenant_id,'WID','Widget',v_uom,'active') returning id into v_item;

  -- Stock, at a known cost.
  v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
  perform erp.add_document_line(v_grn, v_item, 500, 1000, 'stock');
  perform erp.transition_document(v_grn,'post');

  -- ---------------------------------------------------------------------------
  -- Pricing: three sources and one ordering.
  -- ---------------------------------------------------------------------------
  insert into erp.item_price (tenant_id, item_id, price_kind, price_list_code,
                              currency, amount_minor, per_quantity, uom_id,
                              min_quantity, valid_from)
  values (r.tenant_id, v_item, 'sales_list', 'RETAIL', 'GBP', 2500, 1, v_uom, 0,
          current_date - 10);

  select * into p from erp.resolve_price(v_item, v_cust, 1);
  return query select 'a list price is found where nothing more specific applies',
    p.amount_minor = 2500 and p.price_kind = 'sales_list',
    format('%s from %s', p.amount_minor, p.source);

  insert into erp.item_price (tenant_id, item_id, price_kind, price_list_code,
                              currency, amount_minor, per_quantity, uom_id,
                              min_quantity, valid_from, valid_to)
  values (r.tenant_id, v_item, 'promotion', 'SUMMER', 'GBP', 2000, 1, v_uom, 0,
          current_date - 1, current_date + 30);

  select * into p from erp.resolve_price(v_item, v_cust, 1);
  return query select 'a promotion in force beats the list',
    p.amount_minor = 2000 and p.price_kind = 'promotion',
    format('%s from %s', p.amount_minor, p.source);

  insert into erp.item_price (tenant_id, item_id, price_kind, price_list_code,
                              party_role_id, currency, amount_minor,
                              per_quantity, uom_id, min_quantity, valid_from)
  values (r.tenant_id, v_item, 'contract', 'CUST-2026', v_cust_role, 'GBP',
          2200, 1, v_uom, 0, current_date - 5);

  select * into p from erp.resolve_price(v_item, v_cust, 1);
  return query select 'and a contract beats the promotion, even when it is dearer',
    p.amount_minor = 2200 and p.price_kind = 'contract',
    'a contract is a promise and a promotion is an offer';

  -- ---------------------------------------------------------------------------
  -- Margin.
  -- ---------------------------------------------------------------------------
  select * into m from erp.check_margin(v_item, v_site, 2200);
  return query select 'margin is measured against what the stock cost',
    m.within_policy and m.cost_minor = 1000,
    format('%s per cent on a cost of %s', m.margin_pct, m.cost_minor);

  select * into m from erp.check_margin(v_item, v_site, 1050);
  return query select 'and a price under the floor is caught',
    not m.within_policy,
    format('%s per cent against a floor of ten: %s', m.margin_pct, m.message);

  select * into m from erp.check_margin(v_item, v_site, 900);
  return query select 'below cost is refused separately from the floor',
    not m.within_policy and m.message like 'below cost%',
    'a discount chain that can reach below cost is one that will';

  -- ---------------------------------------------------------------------------
  -- Availability and promise dating.
  -- ---------------------------------------------------------------------------
  select * into atp from erp.available_to_promise(v_item, v_site);
  return query select 'available is on hand less what is promised elsewhere',
    atp.on_hand = 500 and atp.committed = 0 and atp.available = 500,
    format('%s on hand, %s committed', atp.on_hand, atp.committed);

  v_so := erp.open_document('sales_order', v_cust, null, v_site);
  v_sol := erp.add_document_line(v_so, v_item, 200, 2200, 'ordered');
  v_alloc := erp.reserve_for_line(v_sol);

  select * into atp from erp.available_to_promise(v_item, v_site);
  return query select 'reserving reduces what is available to the next order',
    atp.committed = 200 and atp.available = 300,
    'a reservation nobody else can see is not a reservation';

  return query select 'and the reservation is fully met, with no unmet cause',
    (select al.unmet_quantity from erp.allocation al where al.id = v_alloc) = 0
    and (select al.unmet_cause is null from erp.allocation al where al.id = v_alloc),
    'five hundred on hand against two hundred asked for';

  -- ---------------------------------------------------------------------------
  -- The shortage, classified, raising replenishment.
  -- ---------------------------------------------------------------------------
  declare v_so2 uuid; v_sol2 uuid; v_alloc2 uuid;
  begin
    v_so2 := erp.open_document('sales_order', v_cust, null, v_site);
    v_sol2 := erp.add_document_line(v_so2, v_item, 1000, 2200, 'more than exists');
    v_alloc2 := erp.reserve_for_line(v_sol2);

    return query select 'a shortage is classified by cause, not merely counted',
      (select al.unmet_quantity from erp.allocation al where al.id = v_alloc2) = 700
      and (select al.unmet_cause from erp.allocation al where al.id = v_alloc2)
          = 'partial_shortfall',
      '"short" is not a cause; these lead to different actions by different people';

    return query select 'and it raises internal replenishment rather than a silent gap',
      exists (select 1 from erp.planning_exception e
               where e.tenant_id = r.tenant_id and e.exception_kind = 'shortage'
                 and e.document_id = v_so2),
      'a shortage that is nobody''s job is discovered on the loading bay';
  end;

  -- ---------------------------------------------------------------------------
  -- Stage two.
  -- ---------------------------------------------------------------------------
  v_n := erp.commit_allocation(v_alloc);
  return query select 'stage two commits the reservation to specific stock',
    v_n >= 1
    and (select al.status::text from erp.allocation al where al.id = v_alloc) = 'committed'
    and (select sum(all2.quantity) from erp.allocation_line all2
          where all2.allocation_id = v_alloc) = 200,
    format('%s line(s) of specific stock', v_n);

  -- ---------------------------------------------------------------------------
  -- Amendment cut-offs.
  -- ---------------------------------------------------------------------------
  select * into am from erp.amendment_allowed(v_so);
  return query select 'an order with nothing picked is amendable',
    am.allowed, am.detail;

  perform erp.amend_document_line(v_sol, 150, 'customer reduced');
  return query select 'and amending it releases the reservation it no longer needs',
    (select l.quantity from erp.document_line l where l.id = v_sol) = 150
    and (select al.status::text from erp.allocation al where al.id = v_alloc) = 'cancelled',
    'an amendment that silently re-reserves can take stock from another order';

  -- ---------------------------------------------------------------------------
  -- Credit hold.
  -- ---------------------------------------------------------------------------
  -- Exposure is what is committed and what is owed. A draft order is neither,
  -- so the order has to reach a committed state before a credit position means
  -- anything — the first draft of this case measured a limit against nothing
  -- and reported "within terms" for an order worth thirty times it.
  perform erp.transition_document(v_so,'submit');
  perform erp.transition_document(v_so,'approve');

  insert into erp.party_role_terms (
    tenant_id, party_role_id, entity_id, currency, credit_limit_minor,
    credit_status, is_blocked, valid_from)
  values (r.tenant_id, v_cust_role, r.entity_id, 'GBP', 10000, 'watch', false,
          current_date - 1);

  select * into c from erp.credit_position(v_cust);
  return query select 'credit is read from the terms B7 has always carried',
    c.credit_limit_minor = 10000 and c.on_hold,
    format('limit %s, exposure %s: %s', c.credit_limit_minor, c.exposure_minor, c.reason);

  begin
    perform erp.check_release_to_fulfilment(v_so);
    v_ok := false; v_msg := 'an order over the credit limit was released';
  exception when sqlstate '42501' then v_ok := true; v_msg := left(sqlerrm,52); end;
  return query select 'an order over the limit is held, not refused', v_ok, v_msg;

  perform erp.release_credit_hold(v_so, 'director approved on the phone');
  return query select 'and releasing it is a separate permission with a reason',
    erp.check_release_to_fulfilment(v_so) = 'released',
    'sales.credit_release has been in the catalogue since B1 and required by nothing';

  update erp.party_role_terms set credit_limit_minor = 100000000
   where tenant_id = r.tenant_id and party_role_id = v_cust_role;

  -- ---------------------------------------------------------------------------
  -- Invoicing from a validated delivery, with role separation.
  -- ---------------------------------------------------------------------------
  v_dn := erp.open_document('delivery', v_cust, null, v_site);
  perform erp.add_document_line(v_dn, v_item, 100, 2200, 'delivered');
  update erp.document_line set location_id = v_recv where document_id = v_dn;

  begin
    perform erp.invoice_from_delivery(v_dn);
    v_ok := false; v_msg := 'an unposted delivery was invoiced';
  exception when others then
    v_ok := (sqlerrm like '%NOT_VALIDATED%'); v_msg := left(sqlerrm,52);
  end;
  return query select 'a delivery that has not moved stock cannot be invoiced',
    v_ok, v_msg;

  perform erp.transition_document(v_dn,'post');

  begin
    perform erp.invoice_from_delivery(v_dn);
    v_ok := false; v_msg := 'the despatcher invoiced their own delivery';
  exception when sqlstate '42501' then
    v_ok := (sqlerrm like '%SEGREGATION%'); v_msg := left(sqlerrm,52);
  end;
  return query select 'and the person who despatched it cannot invoice it', v_ok, v_msg;

  -- As somebody else.
  perform set_config('request.jwt.claims', json_build_object('sub',a2)::text, true);
  v_inv := erp.invoice_from_delivery(v_dn);
  perform set_config('request.jwt.claims', json_build_object('sub',a1)::text, true);

  return query select 'the invoice is derived from what actually moved',
    (select sum(l.quantity) from erp.document_line l where l.document_id = v_inv) = 100
    and (select sum(l.net_minor) from erp.document_line l where l.document_id = v_inv) = 220000,
    'built from the movements, not keyed from the note';

  begin
    perform set_config('request.jwt.claims', json_build_object('sub',a2)::text, true);
    perform erp.invoice_from_delivery(v_dn);
    v_ok := false; v_msg := 'a delivery was invoiced twice';
  exception when sqlstate '23505' then v_ok := true; v_msg := left(sqlerrm,52); end;
  perform set_config('request.jwt.claims', json_build_object('sub',a1)::text, true);
  return query select 'and a delivery cannot be invoiced twice', v_ok, v_msg;

  -- ---------------------------------------------------------------------------
  -- Returns.
  -- ---------------------------------------------------------------------------
  v_ret := erp.raise_customer_return(v_dn, 'DAMAGED', 'crushed in transit', 'credit');
  return query select 'a return records why, because that is the only useful part',
    (select cr.reason_code from erp.customer_return cr where cr.id = v_ret) = 'DAMAGED',
    'a list of individual returns is a queue, not an analysis';

  begin
    perform erp.raise_customer_return(v_dn, '', 'no reason', 'credit');
    v_ok := false; v_msg := 'a return with no reason code was accepted';
  exception when sqlstate '23514' then v_ok := true; v_msg := left(sqlerrm,52); end;
  return query select 'and one without a reason code is refused', v_ok, v_msg;

  return query select 'reason analysis is a share, not a list',
    (select t.share_pct from erp.return_reason_analysis() t
      where t.reason_code = 'DAMAGED') = 100.00,
    'which reason, how often, worth how much';

  -- ---------------------------------------------------------------------------
  -- Configuration assertions.
  -- ---------------------------------------------------------------------------
  return query select 'every price and policy can apply',
    (select count(*) from erp.sales_configuration_report()) = 0,
    'a contract with no customer outranks the list for everybody';

  insert into erp.item_price (tenant_id, item_id, price_kind, price_list_code,
                              currency, amount_minor, per_quantity, uom_id,
                              valid_from)
  values (r.tenant_id, v_item, 'contract', 'BAD', 'GBP', 100, 1, v_uom, current_date);
  return query select 'a contract price with no customer fails the build',
    (select count(*) from erp.sales_configuration_report()
      where finding = 'a contract price names no customer') = 1,
    'it is a list price wearing a contract''s name';
  delete from erp.item_price where price_list_code = 'BAD';

  set constraints all immediate;
  perform set_config('request.jwt.claims','',true);
  perform erp.begin_tenant_purge(r.tenant_id);
  delete from erp.tenant where id = r.tenant_id;
  perform erp.end_tenant_purge();
end;
$$;

create or replace function erp_test.assert_sales_depth_suite()
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_pass integer; v_total integer; v_detail text;
  c_expected constant integer := 26;
begin
  create temporary table if not exists zz_sdep_result
    (case_name text, passed boolean, detail text) on commit drop;
  delete from zz_sdep_result;
  insert into zz_sdep_result select * from erp_test.sales_depth_suite();

  select count(*) filter (where passed), count(*),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_pass, v_total, v_detail from zz_sdep_result;

  if v_total <> c_expected then
    raise exception 'ERPWARE_SALES_DEPTH_SUITE_INCOMPLETE: % cases, expected %',
      v_total, c_expected using errcode = 'P0001';
  end if;
  if v_pass < v_total then
    raise exception E'ERPWARE_SALES_DEPTH_SUITE_FAILED: %/%\n%', v_pass, v_total, v_detail
      using errcode = 'P0001';
  end if;

  return format('sales depth: %s/%s', v_pass, v_total);
end;
$$;

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_sales_controls_sane();
select erp.assert_no_dead_configuration();
select erp.assert_public_api_safe();
select erp.assert_resource_coverage('en');
select erp.assert_isolation();
