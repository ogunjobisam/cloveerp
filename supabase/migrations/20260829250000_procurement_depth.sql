-- =============================================================================
-- ERPWare — Part 5.3: procurement
--
-- Procurement already has its lifecycles, its value-banded approval chain and
-- its posting rules. What it does not have is anything that happens between
-- ordering and paying, which is where procurement actually lives:
--
--   "supplier qualification and approved-supplier control"
--       erp.party_role carries is_approved, approved_by and
--       approval_expires_at. Nothing reads any of them, so an unapproved or
--       lapsed supplier takes orders exactly like an approved one.
--
--   "requisition capture with budget checking"
--       There is no budget.
--
--   "receipt with tolerance rules and quality routing"
--       A receipt accepts whatever quantity it is given and puts it straight
--       into available stock, whatever the item says about inspection.
--
--   "three-way matching with configurable tolerances and an exception
--    workbench"
--       erp.document_line has quantity_fulfilled and quantity_invoiced, which
--       are the two columns a three-way match is made of, and nothing writes
--       or reads either.
--
--   "goods-received-not-invoiced control with ageing and reconciliation"
--       The finance bridge credits 2100 on every receipt and nothing ever
--       clears it. That account grows for ever, which is worse than not having
--       it: a control account nobody reconciles is a number that looks
--       reconciled.
--
--   "landed cost capture and allocation"
--       Nothing. Freight and duty land in an expense account and the stock
--       they arrived with is valued as if it were free to bring in.
--
-- The through-line here is the same as everywhere else in this build: the
-- columns for the discipline exist and the discipline does not. What follows
-- is deliberately built on those columns rather than beside them.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Approved-supplier control
--
-- Three states worth telling apart, and a product that collapses them is one
-- where "approved supplier" means "a supplier we have used before":
--
--   never approved     nobody has qualified them
--   approved           qualified, and the qualification is in date
--   lapsed             qualified once, and the qualification has expired
--
-- The third is the one that matters. It is invisible without a date, which is
-- why erp.party_role.approval_expires_at exists, and it is the state a real
-- supplier spends most of its time drifting into.
-- -----------------------------------------------------------------------------

create or replace function erp.supplier_qualification(p_party_id uuid)
returns table (status text, approved_at timestamptz, expires_at timestamptz,
               days_remaining integer)
language sql
stable
security invoker
set search_path = ''
as $$
  select case
           when not pr.is_approved then 'never_approved'
           when pr.approval_expires_at is not null
                and pr.approval_expires_at < now() then 'lapsed'
           else 'approved'
         end,
         pr.approved_at, pr.approval_expires_at,
         case when pr.approval_expires_at is null then null
              else (pr.approval_expires_at::date - current_date)::integer end
    from erp.party_role pr
   where pr.tenant_id = erp.current_tenant_id()
     and pr.party_id = p_party_id
     and pr.role_kind = 'supplier'
     and pr.status = 'active'
   order by pr.approved_at desc nulls last
   limit 1
$$;

create or replace function erp.require_approved_supplier(p_party_id uuid)
returns void
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  q record;
begin
  select * into q from erp.supplier_qualification(p_party_id);

  if not found then
    raise exception
      'ERPWARE_NOT_A_SUPPLIER: this party has no active supplier role'
      using errcode = '42501';
  end if;

  if q.status = 'lapsed' then
    raise exception
      'ERPWARE_SUPPLIER_QUALIFICATION_LAPSED: qualification expired on %',
      q.expires_at::date
      using errcode = '42501',
      hint = 'Requalify the supplier. A lapsed qualification is the state a '
             'supplier drifts into, and it looks exactly like an approved one '
             'if nobody checks the date.';
  end if;

  if q.status = 'never_approved' then
    raise exception 'ERPWARE_SUPPLIER_NOT_APPROVED: nobody has qualified this supplier'
      using errcode = '42501';
  end if;
end;
$$;

create or replace function erp.qualify_supplier(
  p_party_id uuid,
  p_valid_for interval default '1 year',
  p_note text default null
) returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
begin
  perform erp.authorise('master_data.approve', null, null, null, 'party', p_party_id);

  update erp.party_role
     set is_approved = true,
         approved_by = erp.current_principal_id(),
         approved_at = now(),
         -- An approval with no end date is an approval nobody ever revisits.
         approval_expires_at = now() + p_valid_for,
         attributes = attributes || jsonb_build_object('qualification_note', p_note),
         updated_at = now()
   where tenant_id = v_tenant and party_id = p_party_id
     and role_kind = 'supplier' and status = 'active';

  if not found then
    raise exception 'ERPWARE_NOT_A_SUPPLIER: no active supplier role to qualify'
      using errcode = '23503';
  end if;
end;
$$;

create or replace function erp.supplier_qualification_report()
returns table (party_id uuid, party_code text, party_name text,
               status text, expires_at timestamptz, days_remaining integer,
               open_order_value_minor bigint)
language sql
stable
security invoker
set search_path = ''
as $$
  select p.id, p.code, p.name, q.status, q.expires_at, q.days_remaining,
         coalesce((select sum(erp.document_value_minor(d.id))::bigint
                     from erp.document d
                     join erp.document_type dt on dt.id = d.document_type_id
                    where d.tenant_id = p.tenant_id and d.party_id = p.id
                      and dt.base_type_code = 'purchase_order'
                      and not d.is_cancelled), 0)
    from erp.party p
    join erp.party_role pr on pr.party_id = p.id and pr.role_kind = 'supplier'
                          and pr.status = 'active'
    cross join lateral erp.supplier_qualification(p.id) q
   where p.tenant_id = erp.current_tenant_id()
     and p.merged_into_id is null
   order by case q.status when 'lapsed' then 0 when 'never_approved' then 1 else 2 end,
            q.days_remaining nulls last
$$;

comment on function erp.supplier_qualification_report() is
  'Spec 5.3: approved-supplier control, as a worklist. Lapsed first, and with '
  'the open order value against each — a lapsed supplier with nothing on order '
  'is an administrative task and one with half a million is a problem.';

-- -----------------------------------------------------------------------------
-- Budget checking
--
-- Spec 5.3: "requisition capture with budget checking". The useful part of a
-- budget check is not the spent figure — that is arithmetic — it is the
-- committed figure. A budget that only counts what has been invoiced says a
-- department has money right up until every order it has placed arrives at
-- once.
--
-- So a budget knows three numbers: what has been posted against it, what has
-- been committed and not yet posted, and what is left after both.
-- -----------------------------------------------------------------------------

create table if not exists erp.budget (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  entity_id    uuid not null,
  code         text not null,
  name         text not null,
  fiscal_year  integer not null,
  -- Which spend this budget is about, as JsonLogic over the requisition's
  -- context. A budget per cost centre, per account, per site or per anything
  -- else the tenant records is then configuration.
  selector     jsonb not null default 'true'::jsonb,
  amount_minor bigint not null check (amount_minor >= 0),
  currency     char(3) not null references erp_ref.currency(code),
  -- What happens when a requisition would exceed it. Blocking is not always
  -- right: some organisations want the overspend visible and approved rather
  -- than impossible.
  on_exceed    text not null default 'block'
                 check (on_exceed in ('block', 'warn', 'approve')),
  approval_chain_code text,
  status       erp.record_status not null default 'active',
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code, fiscal_year),
  foreign key (tenant_id, entity_id) references erp.entity (tenant_id, id) on delete cascade
);

comment on table erp.budget is
  'Spec 5.3: budget checking. Knows what has been committed as well as what has '
  'been spent — a budget that counts only invoices says there is money right up '
  'until every order placed against it arrives at once.';

create or replace function erp.budget_position(p_budget_code text, p_year integer default null)
returns table (budget_code text, amount_minor bigint, posted_minor bigint,
               committed_minor bigint, remaining_minor bigint, currency char(3))
language sql
stable
security invoker
set search_path = ''
as $$
  with b as (
    select * from erp.budget
     where tenant_id = erp.current_tenant_id()
       and code = p_budget_code
       and fiscal_year = coalesce(p_year, extract(year from current_date)::integer)
       and status = 'active'
  ),
  -- Posted: what has reached the ledger against this budget, taken from the
  -- journals raised by documents that named it.
  posted as (
    select coalesce(sum(l.debit_minor - l.credit_minor), 0)::bigint as amt
      from b
      join erp.journal j on j.tenant_id = b.tenant_id
      join erp.journal_line l on l.journal_id = j.id
      join erp.document d on d.id = j.document_id
     where j.status = 'posted'
       and d.attributes ->> 'budget_code' = b.code
  ),
  -- Committed: ordered and not yet received. The number that makes a budget
  -- check worth running.
  committed as (
    select coalesce(sum(erp.document_value_minor(d.id)), 0)::bigint as amt
      from b
      join erp.document d on d.tenant_id = b.tenant_id
      join erp.document_type dt on dt.id = d.document_type_id
      join erp.object_state os on os.object_type = 'document' and os.object_id = d.id
      join erp.state s on s.id = os.current_state_id
     where dt.base_type_code = 'purchase_order'
       and d.attributes ->> 'budget_code' = b.code
       and s.is_committed and not s.is_terminal
       and not d.is_cancelled
  )
  select b.code, b.amount_minor, posted.amt, committed.amt,
         b.amount_minor - posted.amt - committed.amt, b.currency
    from b, posted, committed
$$;

create or replace function erp.check_budget(
  p_budget_code text,
  p_amount_minor bigint
) returns text
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.budget%rowtype;
  pos      record;
begin
  select * into b from erp.budget
   where tenant_id = v_tenant and code = p_budget_code
     and fiscal_year = extract(year from current_date)::integer
     and status = 'active';

  if not found then
    raise exception 'ERPWARE_UNKNOWN_BUDGET: % has no budget for this year', p_budget_code
      using errcode = '23503';
  end if;

  select * into pos from erp.budget_position(p_budget_code);

  if pos.remaining_minor >= p_amount_minor then
    return 'within';
  end if;

  if b.on_exceed = 'block' then
    raise exception
      'ERPWARE_BUDGET_EXCEEDED: % has % remaining of %, and this needs %',
      p_budget_code, pos.remaining_minor, pos.amount_minor, p_amount_minor
      using errcode = '42501',
      detail = format('posted %s, committed %s', pos.posted_minor, pos.committed_minor);
  end if;

  return b.on_exceed;
end;
$$;

-- -----------------------------------------------------------------------------
-- Receipt tolerance and quality routing
--
-- Spec 5.3: "receipt with tolerance rules and quality routing". Two separate
-- questions that a naive receipt answers the same way — by accepting whatever
-- turns up and putting it in available stock.
--
--   tolerance   is this quantity acceptable against what was ordered? Over-
--               delivery is the interesting direction, because under-delivery
--               is visible in the outstanding quantity and over-delivery is
--               free stock nobody agreed to buy
--   routing     does this item go into available stock, or into quarantine
--               until somebody inspects it? erp.item.quarantine_on_receipt has
--               existed since B7 and nothing has ever read it
-- -----------------------------------------------------------------------------

create table if not exists erp.receipt_tolerance (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  code         text not null,
  name         text,
  item_class   text,
  party_id     uuid,
  over_pct     numeric(6,3) not null default 0,
  under_pct    numeric(6,3) not null default 100,
  -- What to do with an over-delivery inside tolerance: take it, or take only
  -- what was ordered and send the rest back.
  over_action  text not null default 'accept'
                 check (over_action in ('accept', 'reject', 'quarantine')),
  status       erp.record_status not null default 'active',
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code),
  foreign key (tenant_id, party_id) references erp.party (tenant_id, id) on delete cascade
);

create or replace function erp.check_receipt_tolerance(
  p_item_id  uuid,
  p_party_id uuid,
  p_ordered  numeric,
  p_received numeric
) returns text
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_class  text;
  t        erp.receipt_tolerance%rowtype;
  v_pct    numeric;
begin
  if p_ordered is null or p_ordered <= 0 then
    -- Nothing was ordered, so nothing is out of tolerance. A receipt with no
    -- order behind it is a different control, not this one.
    return 'accept';
  end if;

  select i.item_class into v_class from erp.item i
   where i.tenant_id = v_tenant and i.id = p_item_id;

  select * into t from erp.receipt_tolerance rt
   where rt.tenant_id = v_tenant and rt.status = 'active'
     and (rt.item_class is null or rt.item_class = v_class)
     and (rt.party_id is null or rt.party_id = p_party_id)
   order by (rt.party_id is not null)::integer desc,
            (rt.item_class is not null)::integer desc, rt.code
   limit 1;

  if not found then return 'accept'; end if;

  v_pct := (p_received - p_ordered) * 100.0 / p_ordered;

  if v_pct > t.over_pct then
    if t.over_action = 'reject' then
      raise exception
        'ERPWARE_OVER_DELIVERY: % against % ordered is % per cent over, and '
        'tolerance is % per cent',
        p_received, p_ordered, round(v_pct, 2), t.over_pct
        using errcode = '23514',
        hint = 'Over-delivery inside tolerance is a decision; outside it is '
               'stock nobody agreed to buy.';
    end if;
    return t.over_action;
  end if;

  if -v_pct > t.under_pct then
    raise exception
      'ERPWARE_UNDER_DELIVERY: % against % ordered is % per cent short, and '
      'tolerance is % per cent',
      p_received, p_ordered, round(-v_pct, 2), t.under_pct
      using errcode = '23514';
  end if;

  return 'accept';
end;
$$;

-- -----------------------------------------------------------------------------
-- Three-way matching
--
-- Order, receipt, invoice. The match is per line rather than per document,
-- because a document-level match passes when two errors cancel — and the two
-- errors that cancel are exactly the ones worth finding.
--
-- erp.document_line.quantity_fulfilled and quantity_invoiced have existed since
-- B7 as the two columns a three-way match is made of, and nothing has ever
-- written or read either. Receipts and invoices now maintain them, through
-- erp.document_relation, which is how a receipt says which order line it is
-- against — a link B7 also built and nothing populated.
-- -----------------------------------------------------------------------------

create type erp.match_status as enum
  ('matched', 'quantity_variance', 'price_variance', 'both', 'unmatched');

create table if not exists erp.match_tolerance (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  code         text not null,
  name         text,
  item_class   text,
  party_id     uuid,
  quantity_pct numeric(6,3) not null default 0,
  price_pct    numeric(6,3) not null default 0,
  -- Small absolute differences are not worth a person's time whatever the
  -- percentage says: a penny on a four-pound line is 25 basis points and
  -- nothing at all.
  price_absolute_minor bigint not null default 0,
  approval_chain_code text,
  status       erp.record_status not null default 'active',
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code),
  foreign key (tenant_id, party_id) references erp.party (tenant_id, id) on delete cascade
);

create table if not exists erp.match_exception (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  order_line_id uuid not null,
  invoice_document_id uuid,
  status       erp.match_status not null,
  ordered_quantity  numeric(20,6),
  received_quantity numeric(20,6),
  invoiced_quantity numeric(20,6),
  ordered_price_minor  bigint,
  invoiced_price_minor bigint,
  quantity_variance numeric(20,6),
  price_variance_minor bigint,
  approval_request_id uuid,
  resolved_at  timestamptz,
  resolved_by  uuid,
  resolution   text,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, id),
  foreign key (tenant_id, order_line_id)
    references erp.document_line (tenant_id, id) on delete cascade,
  foreign key (tenant_id, invoice_document_id)
    references erp.document (tenant_id, id) on delete cascade
);

create index if not exists match_exception_open
  on erp.match_exception (tenant_id, status) where resolved_at is null;

-- Receipts and invoices maintain the order line's fulfilled and invoiced
-- quantities. Derived from erp.document_relation rather than stored twice, so
-- the two can only disagree if the relations do.
create or replace function erp.refresh_order_line_progress(p_order_line_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
begin
  update erp.document_line ol
     set quantity_fulfilled = coalesce((
           select sum(rel.quantity)
             from erp.document_relation rel
             join erp.document rd on rd.id = rel.from_document_id
             join erp.document_type rdt on rdt.id = rd.document_type_id
            where rel.tenant_id = v_tenant
              and rel.to_line_id = ol.id
              and rdt.base_type_code = 'receipt'
              and not rd.is_cancelled), 0),
         quantity_invoiced = coalesce((
           select sum(rel.quantity)
             from erp.document_relation rel
             join erp.document id2 on id2.id = rel.from_document_id
             join erp.document_type idt on idt.id = id2.document_type_id
            where rel.tenant_id = v_tenant
              and rel.to_line_id = ol.id
              and idt.base_type_code in ('invoice_reference', 'credit_reference')
              and not id2.is_cancelled), 0),
         updated_at = now()
   where ol.tenant_id = v_tenant and ol.id = p_order_line_id;
end;
$$;

create or replace function erp.match_three_way(p_order_line_id uuid)
returns erp.match_status
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  ol       erp.document_line%rowtype;
  d        erp.document%rowtype;
  tol      erp.match_tolerance%rowtype;
  v_class  text;
  v_inv_price bigint;
  v_inv_doc  uuid;
  v_qty_var numeric;
  v_price_var bigint;
  v_qty_bad boolean;
  v_price_bad boolean;
  v_status erp.match_status;
  v_req    uuid;
begin
  perform erp.refresh_order_line_progress(p_order_line_id);

  select * into ol from erp.document_line
   where tenant_id = v_tenant and id = p_order_line_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_LINE: %', p_order_line_id using errcode = '23503';
  end if;

  select * into d from erp.document where tenant_id = v_tenant and id = ol.document_id;

  -- Nothing invoiced yet is not a match failure; it is a match that has not
  -- happened. Recording it as an exception would fill the workbench with
  -- orders that are simply in progress.
  if coalesce(ol.quantity_invoiced, 0) = 0 then
    return 'unmatched';
  end if;

  select i.item_class into v_class from erp.item i where i.id = ol.item_id;

  select * into tol from erp.match_tolerance mt
   where mt.tenant_id = v_tenant and mt.status = 'active'
     and (mt.item_class is null or mt.item_class = v_class)
     and (mt.party_id is null or mt.party_id = d.party_id)
   order by (mt.party_id is not null)::integer desc,
            (mt.item_class is not null)::integer desc, mt.code
   limit 1;

  -- The invoiced price, from the invoice line that referenced this order line.
  select il.unit_price_minor, il.document_id into v_inv_price, v_inv_doc
    from erp.document_relation rel
    join erp.document_line il on il.id = rel.from_line_id
    join erp.document id2 on id2.id = rel.from_document_id
    join erp.document_type idt on idt.id = id2.document_type_id
   where rel.tenant_id = v_tenant and rel.to_line_id = p_order_line_id
     and idt.base_type_code = 'invoice_reference'
   order by il.created_at desc
   limit 1;

  -- Invoiced against received, not invoiced against ordered. Being billed for
  -- what was ordered and not delivered is the single most common way money
  -- leaves a business by accident.
  v_qty_var := coalesce(ol.quantity_invoiced, 0) - coalesce(ol.quantity_fulfilled, 0);
  v_price_var := coalesce(v_inv_price, ol.unit_price_minor) - ol.unit_price_minor;

  v_qty_bad := coalesce(ol.quantity_fulfilled, 0) > 0
               and abs(v_qty_var) * 100.0 / ol.quantity_fulfilled
                   > coalesce(tol.quantity_pct, 0);
  v_price_bad := abs(v_price_var) > coalesce(tol.price_absolute_minor, 0)
                 and (ol.unit_price_minor = 0
                      or abs(v_price_var) * 100.0 / ol.unit_price_minor
                         > coalesce(tol.price_pct, 0));

  v_status := case
                when v_qty_bad and v_price_bad then 'both'
                when v_qty_bad then 'quantity_variance'
                when v_price_bad then 'price_variance'
                else 'matched'
              end::erp.match_status;

  if v_status = 'matched' then
    -- A previously raised exception that now matches is resolved by the match,
    -- not left for somebody to close by hand.
    update erp.match_exception
       set resolved_at = now(), resolved_by = erp.current_principal_id(),
           resolution = 'resolved by a later match', updated_at = now()
     where tenant_id = v_tenant and order_line_id = p_order_line_id
       and resolved_at is null;
    return v_status;
  end if;

  if tol.approval_chain_code is not null then
    v_req := erp.request_approval(
      'match_exception', p_order_line_id,
      jsonb_build_object(
        'status', v_status::text,
        'quantity_variance', v_qty_var,
        'price_variance_minor', v_price_var,
        'party_id', d.party_id),
      1, d.entity_id, d.site_id);
  end if;

  insert into erp.match_exception (
    tenant_id, order_line_id, invoice_document_id, status,
    ordered_quantity, received_quantity, invoiced_quantity,
    ordered_price_minor, invoiced_price_minor,
    quantity_variance, price_variance_minor, approval_request_id)
  values (v_tenant, p_order_line_id, v_inv_doc, v_status,
          ol.quantity, ol.quantity_fulfilled, ol.quantity_invoiced,
          ol.unit_price_minor, v_inv_price, v_qty_var, v_price_var, v_req);

  return v_status;
end;
$$;

comment on function erp.match_three_way(uuid) is
  'Spec 5.3: three-way matching, per line. Per document would pass whenever two '
  'errors cancel, and the two that cancel are the ones worth finding. Invoiced '
  'is compared against received, never against ordered.';

create or replace function erp.match_exception_workbench()
returns table (exception_id uuid, order_number text, line_no integer,
               item_code text, party_name text, status erp.match_status,
               quantity_variance numeric, price_variance_minor bigint,
               value_at_risk_minor bigint, age_days integer)
language sql
stable
security invoker
set search_path = ''
as $$
  select e.id, d.document_number, ol.line_no, i.code, p.name, e.status,
         e.quantity_variance, e.price_variance_minor,
         -- What the difference is worth, which is how a workbench is ordered
         -- by anybody who has to work it.
         (abs(coalesce(e.quantity_variance, 0)) * coalesce(e.ordered_price_minor, 0)
          + abs(coalesce(e.price_variance_minor, 0))
            * coalesce(e.invoiced_quantity, 0))::bigint,
         (current_date - e.created_at::date)::integer
    from erp.match_exception e
    join erp.document_line ol on ol.id = e.order_line_id
    join erp.document d on d.id = ol.document_id
    left join erp.item i on i.id = ol.item_id
    left join erp.party p on p.id = d.party_id
   where e.tenant_id = erp.current_tenant_id()
     and e.resolved_at is null
   order by 9 desc, 10 desc
$$;

comment on function erp.match_exception_workbench() is
  'Spec 5.3: the exception workbench. Ordered by what the difference is worth, '
  'because a queue ordered by date is worked from the wrong end.';

-- -----------------------------------------------------------------------------
-- Goods received not invoiced
--
-- The finance bridge credits 2100 on every receipt. Nothing has ever debited
-- it, so the account grows for ever — which is worse than not having it,
-- because a control account nobody reconciles is a number that looks
-- reconciled.
--
-- Clearing it is the invoice's job: receipt credits GRNI, invoice debits it and
-- credits the payable. What is left is what has arrived and not been billed,
-- and the ageing of that is the report a finance function actually wants.
-- -----------------------------------------------------------------------------

create or replace function erp.grni_report()
returns table (order_line_id uuid, order_number text, party_name text,
               item_code text, received_quantity numeric, invoiced_quantity numeric,
               open_quantity numeric, open_value_minor bigint,
               received_on date, age_days integer, bucket text)
language sql
stable
security invoker
set search_path = ''
as $$
  with lines as (
    select ol.id, d.document_number, p.name as party_name, i.code as item_code,
           coalesce(ol.quantity_fulfilled, 0) as recvd,
           coalesce(ol.quantity_invoiced, 0) as invd,
           ol.unit_price_minor,
           (select min(rd.document_date)
              from erp.document_relation rel
              join erp.document rd on rd.id = rel.from_document_id
              join erp.document_type rdt on rdt.id = rd.document_type_id
             where rel.to_line_id = ol.id and rdt.base_type_code = 'receipt') as received_on
      from erp.document_line ol
      join erp.document d on d.id = ol.document_id
      join erp.document_type dt on dt.id = d.document_type_id
      left join erp.party p on p.id = d.party_id
      left join erp.item i on i.id = ol.item_id
     where ol.tenant_id = erp.current_tenant_id()
       and dt.base_type_code = 'purchase_order'
       and not ol.is_cancelled
       and coalesce(ol.quantity_fulfilled, 0) > coalesce(ol.quantity_invoiced, 0)
  )
  select id, document_number, party_name, item_code, recvd, invd,
         recvd - invd,
         round((recvd - invd) * unit_price_minor)::bigint,
         received_on,
         (current_date - received_on)::integer,
         case
           when received_on is null then 'unknown'
           when current_date - received_on <= 30 then '0-30'
           when current_date - received_on <= 60 then '31-60'
           when current_date - received_on <= 90 then '61-90'
           else '90+'
         end
    from lines
   order by received_on nulls last
$$;

comment on function erp.grni_report() is
  'Spec 5.3: goods-received-not-invoiced with ageing. What has arrived and not '
  'been billed, oldest first — an old GRNI balance is either an invoice nobody '
  'sent or a receipt that never happened, and both are worth knowing about.';

create or replace function erp.grni_reconciliation()
returns table (account_code text, ledger_minor bigint,
               open_receipts_minor bigint, difference_minor bigint)
language sql
stable
security invoker
set search_path = ''
as $$
  -- The ledger balance on the GRNI account against the receipts that are
  -- actually open. These are two independent derivations of the same figure,
  -- which is the only kind of reconciliation worth running.
  select a.code,
         coalesce(sum(l.credit_minor) - sum(l.debit_minor), 0)::bigint,
         coalesce((select sum(g.open_value_minor) from erp.grni_report() g), 0)::bigint,
         coalesce(sum(l.credit_minor) - sum(l.debit_minor), 0)::bigint
           - coalesce((select sum(g.open_value_minor) from erp.grni_report() g), 0)::bigint
    from erp.account a
    left join erp.journal_line l on l.account_id = a.id
    left join erp.journal j on j.id = l.journal_id and j.status = 'posted'
   where a.tenant_id = erp.current_tenant_id()
     and a.code = '2100'
   group by a.code
$$;

-- -----------------------------------------------------------------------------
-- Landed cost
--
-- Freight, duty and insurance are part of what stock cost. Posting them to an
-- expense account and valuing the stock as if it arrived free understates
-- inventory and overstates the cost of whatever period the freight invoice
-- happened to land in.
--
-- Allocation is by value or by weight, configured per charge, because those are
-- the two answers that are defensible and there is no third: a shipment of one
-- heavy cheap thing and one light expensive thing apportions freight very
-- differently under each, and which is right depends on what the carrier
-- charged for.
-- -----------------------------------------------------------------------------

create table if not exists erp.landed_cost (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  receipt_document_id uuid not null,
  charge_code  text not null,
  description  text,
  amount_minor bigint not null check (amount_minor >= 0),
  currency     char(3) not null references erp_ref.currency(code),
  allocation_basis text not null default 'value'
                     check (allocation_basis in ('value', 'weight', 'quantity')),
  supplier_party_id uuid,
  allocated_at timestamptz,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, id),
  foreign key (tenant_id, receipt_document_id)
    references erp.document (tenant_id, id) on delete cascade,
  foreign key (tenant_id, supplier_party_id)
    references erp.party (tenant_id, id) on delete restrict
);

-- Adding to what stock is worth, without pretending more of it arrived.
--
-- The first version of this called erp.receive_cost() with the freight share as
-- if it were another receipt of the same quantity at a very low price. Under
-- average costing that halved the unit cost and doubled the quantity on hand:
-- freight made the stock CHEAPER. The suite caught it by reading the number
-- rather than checking that the call returned — "unit cost 678 after freight"
-- on stock that had cost 1000.
--
-- What a landed charge does is increase the value of stock that is already
-- there. Quantity does not change, so the arithmetic is on value alone.
create or replace function erp.add_cost_to_stock(
  p_item_id  uuid,
  p_site_id  uuid,
  p_quantity numeric,
  p_amount_minor bigint
) returns bigint
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_method erp.costing_method := erp.costing_method_for(p_item_id, p_site_id);
  ic       erp.item_cost%rowtype;
  r        record;
  v_left   bigint := p_amount_minor;
  v_take   bigint;
  v_open   numeric;
  v_new    bigint;
begin
  if p_amount_minor = 0 then return 0; end if;

  if v_method = 'fifo' then
    -- Onto the open layers, in proportion to what is left in each. Freight on
    -- stock that has already been sold is a period cost, not an inventory one,
    -- and putting it back into a consumed layer would restate a closed month.
    select sum(l.remaining) into v_open
      from erp.stock_valuation_layer l
     where l.tenant_id = v_tenant and l.item_id = p_item_id
       and l.site_id is not distinct from p_site_id and l.remaining > 0;

    if coalesce(v_open, 0) = 0 then return 0; end if;

    for r in
      select * from erp.stock_valuation_layer l
       where l.tenant_id = v_tenant and l.item_id = p_item_id
         and l.site_id is not distinct from p_site_id and l.remaining > 0
       order by l.received_at, l.id
       for update
    loop
      v_take := round(p_amount_minor * r.remaining / v_open)::bigint;
      update erp.stock_valuation_layer
         set unit_cost_minor = unit_cost_minor + round(v_take / r.remaining)::bigint,
             updated_at = now()
       where id = r.id;
      v_left := v_left - v_take;
    end loop;

    return p_amount_minor - v_left;
  end if;

  select * into ic from erp.item_cost c
   where c.tenant_id = v_tenant and c.item_id = p_item_id
     and c.site_id is not distinct from p_site_id;

  if not found or ic.quantity_on_hand <= 0 then
    return 0;
  end if;

  -- Value goes up, quantity does not. That is the whole difference between a
  -- charge and a receipt.
  v_new := ic.unit_cost_minor
           + round(p_amount_minor / ic.quantity_on_hand)::bigint;

  update erp.item_cost set unit_cost_minor = v_new, updated_at = now()
   where id = ic.id;

  return p_amount_minor;
end;
$$;

comment on function erp.add_cost_to_stock(uuid, uuid, numeric, bigint) is
  'Increases what stock on hand is worth without changing how much there is. '
  'A landed charge is not a receipt, and treating it as one makes freight lower '
  'the unit cost.';

create or replace function erp.allocate_landed_cost(p_landed_cost_id uuid)
returns bigint
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  lc       erp.landed_cost%rowtype;
  d        erp.document%rowtype;
  v_total  numeric;
  r        record;
  v_share  bigint;
  v_spent  bigint := 0;
  v_rows   integer := 0;
  v_last   uuid;
begin
  select * into lc from erp.landed_cost
   where tenant_id = v_tenant and id = p_landed_cost_id for update;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_LANDED_COST: %', p_landed_cost_id using errcode = '23503';
  end if;

  if lc.allocated_at is not null then
    raise exception 'ERPWARE_LANDED_COST_ALREADY_ALLOCATED: %', lc.charge_code
      using errcode = '23505';
  end if;

  perform erp.authorise('procurement.match', null, null, null,
                        'landed_cost', p_landed_cost_id);

  select * into d from erp.document where tenant_id = v_tenant and id = lc.receipt_document_id;

  -- The denominator, by the configured basis.
  select sum(case lc.allocation_basis
               when 'weight' then ol.quantity * coalesce(i.net_weight_g, 0)
               when 'quantity' then ol.quantity
               else ol.quantity * ol.unit_price_minor
             end)
    into v_total
    from erp.document_line ol
    left join erp.item i on i.id = ol.item_id
   where ol.tenant_id = v_tenant and ol.document_id = lc.receipt_document_id
     and not ol.is_cancelled;

  if coalesce(v_total, 0) = 0 then
    raise exception
      'ERPWARE_NO_ALLOCATION_BASIS: this receipt has no % to apportion % by',
      lc.allocation_basis, lc.charge_code
      using errcode = '23514',
      hint = 'Allocating by weight needs weights on the items. Choose a basis '
             'the data supports rather than one that silently spreads evenly.';
  end if;

  -- Two passes, because rounding leaves pennies and they have to land
  -- somewhere. Apportioning and applying in one pass would either lose them or
  -- need the last share to be known before the loop reaches it; the allocated
  -- total has to equal the charge exactly, because the ledger will insist on it.
  create temporary table if not exists zz_landed_share
    (line_id uuid, item_id uuid, quantity numeric, share bigint) on commit drop;
  delete from zz_landed_share;

  for r in
    select ol.id, ol.item_id, ol.quantity, ol.unit_price_minor,
           coalesce(i.net_weight_g, 0) as weight
      from erp.document_line ol
      left join erp.item i on i.id = ol.item_id
     where ol.tenant_id = v_tenant and ol.document_id = lc.receipt_document_id
       and not ol.is_cancelled
     order by ol.line_no
  loop
    v_share := round(lc.amount_minor
                     * (case lc.allocation_basis
                          when 'weight' then r.quantity * r.weight
                          when 'quantity' then r.quantity
                          else r.quantity * r.unit_price_minor
                        end) / v_total)::bigint;
    insert into zz_landed_share values (r.id, r.item_id, r.quantity, v_share);
    v_spent := v_spent + v_share;
    v_rows := v_rows + 1;
    v_last := r.id;
  end loop;

  if v_rows = 0 then
    raise exception 'ERPWARE_NO_LINES_TO_ALLOCATE_TO: % has no receipt lines',
      lc.charge_code using errcode = '23514';
  end if;

  -- The rounding difference goes on the last line. Somewhere is arbitrary;
  -- nowhere is wrong.
  if v_spent <> lc.amount_minor then
    update zz_landed_share
       set share = share + (lc.amount_minor - v_spent)
     where line_id = v_last;
    v_spent := lc.amount_minor;
  end if;

  for r in select * from zz_landed_share where share > 0 loop
    perform erp.add_cost_to_stock(r.item_id, d.site_id, r.quantity, r.share);
  end loop;

  update erp.landed_cost set allocated_at = now(), updated_at = now()
   where id = p_landed_cost_id;

  return v_spent;
end;
$$;

comment on function erp.allocate_landed_cost(uuid) is
  'Spec 5.3: landed cost allocation. By value, weight or quantity, and refusing '
  'a basis the data does not support rather than silently spreading evenly — '
  'which would be a number that looks apportioned and is not.';

-- -----------------------------------------------------------------------------
-- Receiving and invoicing against an order
--
-- The link is the point. erp.document_relation has existed since B7 with line
-- columns on it and nothing has ever populated them, which is why the two
-- progress columns on the order line stayed null and why nothing could match.
-- -----------------------------------------------------------------------------

create or replace function erp.receive_against(
  p_receipt_id    uuid,
  p_order_line_id uuid,
  p_quantity      numeric,
  p_batch_id      uuid default null
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  ol        erp.document_line%rowtype;
  od        erp.document%rowtype;
  rd        erp.document%rowtype;
  v_line    uuid;
  v_no      integer;
  v_action  text;
  v_open    numeric;
  v_quarantine boolean;
begin
  select * into ol from erp.document_line
   where tenant_id = v_tenant and id = p_order_line_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_LINE: %', p_order_line_id using errcode = '23503';
  end if;

  select * into od from erp.document where tenant_id = v_tenant and id = ol.document_id;
  select * into rd from erp.document where tenant_id = v_tenant and id = p_receipt_id;

  perform erp.authorise('procurement.receive', rd.entity_id, rd.site_id, null,
                        'document', p_receipt_id);

  -- Tolerance is measured against what is still open, not against the whole
  -- order line: three receipts of a third each are not each a two-thirds
  -- under-delivery.
  v_open := ol.quantity - coalesce(ol.quantity_fulfilled, 0);
  v_action := erp.check_receipt_tolerance(ol.item_id, od.party_id, v_open, p_quantity);

  select i.quarantine_on_receipt into v_quarantine
    from erp.item i where i.id = ol.item_id;

  select coalesce(max(l.line_no), 0) + 1 into v_no
    from erp.document_line l
   where l.tenant_id = v_tenant and l.document_id = p_receipt_id;

  insert into erp.document_line (
    tenant_id, document_id, line_no, item_id, description, quantity, uom_id,
    unit_price_minor, net_minor, currency, batch_id, location_id)
  values (v_tenant, p_receipt_id, v_no, ol.item_id,
          coalesce(ol.description, 'received'), p_quantity, ol.uom_id,
          ol.unit_price_minor,
          -- net_minor is what erp.document_value_minor() sums. Writing a line
          -- without it gives a document that has lines and no value, which the
          -- ledger correctly refuses to post.
          round(p_quantity * ol.unit_price_minor)::bigint,
          coalesce(ol.currency, od.currency), p_batch_id,
          -- Quality routing. erp.item.quarantine_on_receipt has existed since
          -- B7 and nothing has ever read it, so an item that must be inspected
          -- went straight into available stock and could be picked before
          -- anybody looked at it.
          case when coalesce(v_quarantine, false) or v_action = 'quarantine'
               then (select l.id from erp.location l
                      where l.tenant_id = v_tenant and l.site_id = rd.site_id
                        and l.location_type = 'quarantine' and l.status = 'active'
                      order by l.code limit 1)
          end)
  returning id into v_line;

  if (coalesce(v_quarantine, false) or v_action = 'quarantine')
     and (select location_id from erp.document_line where id = v_line) is null then
    raise exception
      'ERPWARE_NO_QUARANTINE_LOCATION: % must be inspected on receipt and this '
      'site has no quarantine location', ol.item_id
      using errcode = '23503',
      hint = 'Configure one. Receiving an inspect-on-arrival item into '
             'available stock lets it be picked before anybody looks at it.';
  end if;

  insert into erp.document_relation (
    tenant_id, from_document_id, to_document_id, relation_kind,
    from_line_id, to_line_id, quantity)
  values (v_tenant, p_receipt_id, ol.document_id, 'fulfils',
          v_line, p_order_line_id, p_quantity);

  perform erp.refresh_order_line_progress(p_order_line_id);

  return v_line;
end;
$$;

create or replace function erp.invoice_against(
  p_invoice_id    uuid,
  p_order_line_id uuid,
  p_quantity      numeric,
  p_unit_price_minor bigint default null
) returns erp.match_status
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  ol       erp.document_line%rowtype;
  od       erp.document%rowtype;
  v_line   uuid;
  v_no     integer;
begin
  select * into ol from erp.document_line
   where tenant_id = v_tenant and id = p_order_line_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_LINE: %', p_order_line_id using errcode = '23503';
  end if;

  select * into od from erp.document where tenant_id = v_tenant and id = ol.document_id;

  perform erp.authorise('procurement.match', od.entity_id, od.site_id, null,
                        'document', p_invoice_id);

  select coalesce(max(l.line_no), 0) + 1 into v_no
    from erp.document_line l
   where l.tenant_id = v_tenant and l.document_id = p_invoice_id;

  insert into erp.document_line (
    tenant_id, document_id, line_no, item_id, description, quantity, uom_id,
    unit_price_minor, net_minor, currency)
  values (v_tenant, p_invoice_id, v_no, ol.item_id,
          coalesce(ol.description, 'invoiced'), p_quantity, ol.uom_id,
          coalesce(p_unit_price_minor, ol.unit_price_minor),
          round(p_quantity * coalesce(p_unit_price_minor, ol.unit_price_minor))::bigint,
          coalesce(ol.currency, od.currency))
  returning id into v_line;

  insert into erp.document_relation (
    tenant_id, from_document_id, to_document_id, relation_kind,
    from_line_id, to_line_id, quantity)
  values (v_tenant, p_invoice_id, ol.document_id, 'invoices',
          v_line, p_order_line_id, p_quantity);

  -- Matching on the way in rather than in a nightly job. An exception found
  -- three days later is one somebody has already paid.
  return erp.match_three_way(p_order_line_id);
end;
$$;

comment on function erp.invoice_against(uuid, uuid, numeric, bigint) is
  'Spec 5.3: matching happens as the invoice arrives, not in a nightly sweep. '
  'An exception found three days later is one somebody has already paid.';

-- -----------------------------------------------------------------------------
-- Procurement controls, installed
-- -----------------------------------------------------------------------------

create or replace function erp.configure_procurement_controls(
  p_approver_role text default 'administrator',
  p_over_receipt_pct numeric default 5,
  p_price_variance_pct numeric default 2,
  p_price_variance_minor bigint default 100
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
    'procurement-controls', 'Procurement controls',
    'What may be received against an order, what may be invoiced against a '
    'receipt, and who has to look when neither agrees.',
    jsonb_build_array(
      jsonb_build_object('kind','approval_chain','key','match_exception','payload',
        jsonb_build_object(
          'code','match_exception','name','Invoice match exception',
          'object_type','match_exception',
          'applies_when','true'::jsonb, 'priority',100,
          'material_fields', jsonb_build_array('quantity_variance','price_variance_minor'),
          'steps', jsonb_build_array(
            jsonb_build_object('seq',1,'code','buyer','name','Buyer',
              'approver_kind','role','role',p_approver_role,'min_approvals',1)))),

      jsonb_build_object('kind','receipt_tolerance','key','default','payload',
        jsonb_build_object(
          'code','default','name','Default receipt tolerance',
          'over_pct', p_over_receipt_pct,
          -- Under-delivery is not an error: the rest is still outstanding, and
          -- that is what the outstanding quantity is for.
          'under_pct', 100,
          'over_action','accept')),

      jsonb_build_object('kind','match_tolerance','key','default','payload',
        jsonb_build_object(
          'code','default','name','Default match tolerance',
          'quantity_pct', 0,
          'price_pct', p_price_variance_pct,
          'price_absolute_minor', p_price_variance_minor,
          'approval_chain','match_exception')),

      -- The purchase invoice, which procurement has been missing since it was
      -- built. Without it there is no third document to match against and, more
      -- pointedly, nothing ever debits goods-received-not-invoiced: the finance
      -- bridge credits 2100 on every receipt and the balance grows for ever.
      jsonb_build_object('kind','state_machine','key','purchase_invoice','payload',
        jsonb_build_object(
          'code','purchase_invoice','object_type','document','name','Purchase invoice',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','registered','name','Registered','is_committed',true,'sort_order',20),
            jsonb_build_object('code','paid','name','Paid','is_terminal',true,'is_committed',true,'sort_order',30),
            jsonb_build_object('code','disputed','name','Disputed','sort_order',40),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','register','name','Register','from','draft','to','registered','required_permission','procurement.match'),
            jsonb_build_object('code','dispute','name','Dispute','from','registered','to','disputed','required_permission','procurement.match'),
            jsonb_build_object('code','resolve','name','Resolve','from','disputed','to','registered','required_permission','procurement.match'),
            jsonb_build_object('code','pay','name','Record payment','from','registered','to','paid','required_permission','finance.post'),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','procurement.match')))),

      -- Registering the invoice is what clears GRNI: the receipt credited it,
      -- and this debits it and credits the supplier instead.
      jsonb_build_object('kind','posting_rule','key','purchase_invoice','payload',
        jsonb_build_object(
          'code','purchase_invoice','name','Purchase invoice','ledger','GL',
          'event_type','document.purchase_invoice.registered',
          'posting_lines', jsonb_build_array(
            jsonb_build_object('account','2100','side','debit','rate',1,
                               'description','Clearing goods received not invoiced'),
            jsonb_build_object('account','2000','side','credit','rate',1,
                               'description','Trade payable'))))));

  insert into erp.numbering_rule (
    tenant_id, code, entity_id, prefix, pad_to, reset_period, next_value)
  select v_tenant, 'purchase_invoice', e.id, 'PINV-', 6, 'yearly', 1
    from erp.entity e where e.tenant_id = v_tenant and e.status = 'active'
    order by e.code limit 1
  on conflict (tenant_id, code) do nothing;

  insert into erp.document_type (
    tenant_id, code, base_type_code, name, entity_id,
    state_machine_code, numbering_rule_id, posting_rule_code)
  select v_tenant, 'purchase_invoice', 'invoice_reference', 'Purchase invoice',
         n.entity_id, 'purchase_invoice', n.id, 'purchase_invoice'
    from erp.numbering_rule n
   where n.tenant_id = v_tenant and n.code = 'purchase_invoice'
  on conflict (tenant_id, code) do update
    set state_machine_code = excluded.state_machine_code,
        numbering_rule_id = excluded.numbering_rule_id,
        posting_rule_code = excluded.posting_rule_code;

  return v_cs;
end;
$$;

comment on function erp.configure_procurement_controls is
  'Spec 5.3 as configuration: receipt and match tolerances, and the chain an '
  'exception routes to. All three are the sort of number that gets argued about '
  'and should therefore be promoted rather than typed.';

-- -----------------------------------------------------------------------------
-- B6 learns tolerances and budgets
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

    else
      raise exception 'ERPWARE_PROMOTION_UNKNOWN_KIND: % cannot be promoted', i.object_kind
        using errcode = '23514',
              hint = 'Promotable kinds: config, terminology, legislation_binding, event_subscription, role, rule_set, state_machine, approval_chain, posting_rule, data_quality_rule, field_approval_rule, costing_policy, count_programme, receipt_tolerance, match_tolerance, budget';
  end case;
end;
$function$;

-- -----------------------------------------------------------------------------
-- Assertions
-- -----------------------------------------------------------------------------

create or replace function erp.procurement_configuration_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  select 'a match tolerance names an approval chain that does not exist',
         t.code, format('approval_chain_code = %s', t.approval_chain_code)
    from erp.match_tolerance t
   where t.status = 'active' and t.approval_chain_code is not null
     and not exists (select 1 from erp.approval_chain ac
                      where ac.tenant_id = t.tenant_id and ac.code = t.approval_chain_code
                        and ac.status = 'active')
  union all
  -- A tolerance of zero on both axes with no chain sends every difference
  -- nowhere: the exception is raised and there is no queue it lands in.
  select 'a match tolerance raises exceptions with nowhere to send them',
         t.code,
         'no approval chain, so every variance becomes a row nobody is asked '
         'to look at'
    from erp.match_tolerance t
   where t.status = 'active' and t.approval_chain_code is null
  union all
  select 'a budget names an approval chain that does not exist',
         b.code, format('approval_chain_code = %s', b.approval_chain_code)
    from erp.budget b
   where b.status = 'active' and b.approval_chain_code is not null
     and not exists (select 1 from erp.approval_chain ac
                      where ac.tenant_id = b.tenant_id and ac.code = b.approval_chain_code
                        and ac.status = 'active')
  union all
  -- A budget that routes to approval on exceed and names no chain would block
  -- nothing and approve nothing.
  select 'a budget approves overspend through no chain',
         b.code, 'on_exceed is approve and no chain is named'
    from erp.budget b
   where b.status = 'active' and b.on_exceed = 'approve'
     and b.approval_chain_code is null
  union all
  -- Quarantine on receipt with nowhere to put it fails at the worst moment:
  -- when the goods are on the dock.
  select 'an item must be quarantined on receipt and a site has no quarantine location',
         format('%s at %s', i.code, s.code),
         'the receipt will refuse, and it will refuse with the lorry outside'
    from erp.item i
    cross join erp.site s
   where i.tenant_id = s.tenant_id
     and i.quarantine_on_receipt
     and i.status = 'active' and s.status = 'active'
     and not exists (select 1 from erp.location l
                      where l.tenant_id = s.tenant_id and l.site_id = s.id
                        and l.location_type = 'quarantine' and l.status = 'active')
$$;

create or replace function erp.assert_procurement_controls_sane()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare v_count integer; v_detail text;
begin
  select count(*), string_agg(format('  %s [%s] %s', finding, reference, detail), E'\n')
    into v_count, v_detail from erp.procurement_configuration_report();
  if v_count > 0 then
    raise exception 'ERPWARE_PROCUREMENT_CONFIGURATION_DEAD: % finding(s)', v_count
      using errcode = 'P0001', detail = v_detail;
  end if;
  return 'procurement: every tolerance and budget can fire';
end;
$$;

-- -----------------------------------------------------------------------------
-- Public surface
-- -----------------------------------------------------------------------------

create or replace function public.erp_match_workbench()
returns jsonb language sql stable security invoker set search_path = ''
as $$ select coalesce(jsonb_agg(to_jsonb(w)), '[]'::jsonb)
        from erp.match_exception_workbench() w $$;

create or replace function public.erp_grni()
returns jsonb language sql stable security invoker set search_path = ''
as $$ select coalesce(jsonb_agg(to_jsonb(g)), '[]'::jsonb) from erp.grni_report() g $$;

create or replace function public.erp_supplier_qualification()
returns jsonb language sql stable security invoker set search_path = ''
as $$ select coalesce(jsonb_agg(to_jsonb(q)), '[]'::jsonb)
        from erp.supplier_qualification_report() q $$;

create or replace function public.erp_budget_position(p_code text)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select coalesce(jsonb_agg(to_jsonb(b)), '[]'::jsonb)
        from erp.budget_position(p_code) b $$;

create or replace function public.erp_configure_procurement_controls(
  p_approver_role text default 'administrator')
returns uuid language sql volatile security invoker set search_path = ''
as $$ select erp.configure_procurement_controls(p_approver_role) $$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.erp_match_workbench()', 'public.erp_grni()',
    'public.erp_supplier_qualification()', 'public.erp_budget_position(text)',
    'public.erp_configure_procurement_controls(text)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_configure_procurement_controls', 'erp.configure_procurement_controls',
   'Submits the receipt and match tolerances as a B6 change set the caller '
   'cannot approve; the installer authorises administration.configure.')
on conflict (function_name) do update
  set gate = excluded.gate, rationale = excluded.rationale;

-- -----------------------------------------------------------------------------
-- The suite
-- -----------------------------------------------------------------------------

create or replace function erp_test.procurement_controls_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  r record; a1 uuid := gen_random_uuid(); a2 uuid := gen_random_uuid();
  csf uuid; csp uuid; csi uuid; csc uuid; v_second uuid; v_tok text; res jsonb;
  v_uom uuid; v_site uuid; v_recv uuid; v_quar uuid;
  v_sup uuid; v_item uuid; v_item2 uuid;
  v_po uuid; v_pol uuid; v_pol2 uuid; v_pol3 uuid; v_pol4 uuid;
  v_grn uuid; v_inv uuid; v_lc uuid;
  v_status erp.match_status; v_n numeric; v_cost bigint;
  v_ok boolean; v_msg text; v_q record;
begin
  select * into r from erp.provision_tenant('zzproc','Proc Suite','a@zzproc.test','Suite Admin');
  perform set_config('request.jwt.claims', json_build_object('sub',a1)::text, true);
  perform erp.claim_invitation(r.admin_token);
  res := public.erp_invite_principal('second@zzproc.test','Second Admin');
  v_second := (res->>'app_user_id')::uuid; v_tok := res->>'token';
  perform erp.grant_role(v_second,'administrator',null,null,'co-administrator');

  csf := erp.configure_finance();
  csp := erp.configure_procurement(100000000);
  csi := erp.configure_inventory('average');
  csc := erp.configure_procurement_controls();

  perform set_config('request.jwt.claims', json_build_object('sub',a2)::text, true);
  perform erp.claim_invitation(v_tok);
  perform erp.approve_change_set(csf); perform erp.promote_change_set(csf);
  perform erp.approve_change_set(csp); perform erp.promote_change_set(csp);
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
  values (r.tenant_id,v_site,'QUAR','Quarantine','quarantine','active') returning id into v_quar;
  insert into erp.party (tenant_id,code,name,status)
  values (r.tenant_id,'SUP','Supplier','active') returning id into v_sup;
  insert into erp.item (tenant_id,code,name,stock_uom_id,net_weight_g,status)
  values (r.tenant_id,'WID','Widget',v_uom,100,'active') returning id into v_item;
  insert into erp.item (tenant_id,code,name,stock_uom_id,quarantine_on_receipt,net_weight_g,status)
  values (r.tenant_id,'MED','Inspect me',v_uom,true,900,'active') returning id into v_item2;

  -- ---------------------------------------------------------------------------
  -- Supplier qualification: three states, and the one that matters.
  -- ---------------------------------------------------------------------------
  insert into erp.party_role (tenant_id,party_id,role_kind,status)
  values (r.tenant_id,v_sup,'supplier','active');

  select * into v_q from erp.supplier_qualification(v_sup);
  return query select 'an unqualified supplier is not merely unapproved',
    v_q.status = 'never_approved',
    'never approved, approved and lapsed are three states, not two';

  begin
    perform erp.require_approved_supplier(v_sup);
    v_ok := false; v_msg := 'an unqualified supplier passed';
  exception when sqlstate '42501' then v_ok := true; v_msg := left(sqlerrm,54); end;
  return query select 'and it is refused', v_ok, v_msg;

  perform erp.qualify_supplier(v_sup, '1 year', 'audited on site');
  perform erp.require_approved_supplier(v_sup);
  return query select 'a qualified supplier passes, with an expiry date',
    (select q.status from erp.supplier_qualification(v_sup) q) = 'approved'
    and (select q.expires_at is not null from erp.supplier_qualification(v_sup) q),
    'an approval with no end date is one nobody ever revisits';

  update erp.party_role set approval_expires_at = now() - interval '1 day'
   where tenant_id = r.tenant_id and party_id = v_sup;

  begin
    perform erp.require_approved_supplier(v_sup);
    v_ok := false; v_msg := 'a lapsed qualification passed';
  exception when sqlstate '42501' then
    v_ok := (sqlerrm like '%LAPSED%'); v_msg := left(sqlerrm,54);
  end;
  return query select 'a lapsed qualification is caught, and named as lapsed',
    v_ok, v_msg;

  return query select 'and the worklist puts it first, with what is at stake',
    (select q.status from erp.supplier_qualification_report() q limit 1) = 'lapsed',
    'a lapsed supplier with nothing on order is admin; with orders it is a problem';

  perform erp.qualify_supplier(v_sup, '1 year', 'requalified');

  insert into erp.budget (tenant_id, entity_id, code, name, fiscal_year,
                          amount_minor, currency, on_exceed)
  values (r.tenant_id, r.entity_id, 'OPS', 'Operations',
          extract(year from current_date)::integer, 50000000, 'GBP', 'block');

  return query select 'a budget counts what is committed, not only what is spent',
    (select b.committed_minor from erp.budget_position('OPS') b) = 0,
    'no order names this budget yet';

  -- ---------------------------------------------------------------------------
  -- Three-way matching.
  -- ---------------------------------------------------------------------------
  v_po := erp.open_document('purchase_order', v_sup, null, v_site);
  v_pol := erp.add_document_line(v_po, v_item, 100, 1000, 'widgets');
  v_pol2 := erp.add_document_line(v_po, v_item2, 10, 5000, 'inspect me');
  v_pol3 := erp.add_document_line(v_po, v_item, 50, 1000, 'second line');
  v_pol4 := erp.add_document_line(v_po, v_item, 80, 1000, 'third line');
  update erp.document set attributes = jsonb_build_object('budget_code','OPS')
   where id = v_po;
  perform erp.transition_document(v_po,'submit');
  perform erp.transition_document(v_po,'approve');
  -- 'approved' is not 'sent'. A purchase order commits the organisation when it
  -- reaches the supplier, which is the state the machine marks committed — and
  -- taking the earlier state would have made the budget case pass while
  -- measuring nothing.
  perform erp.transition_document(v_po,'send');

  v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
  perform erp.receive_against(v_grn, v_pol, 100);

  return query select 'a receipt against an order line fills in what B7 left null',
    (select ol.quantity_fulfilled from erp.document_line ol where ol.id = v_pol) = 100,
    'quantity_fulfilled has existed since B7 and nothing had ever written it';

  perform erp.receive_against(v_grn, v_pol2, 10);
  return query select 'an inspect-on-arrival item is routed to quarantine',
    (select ol.location_id from erp.document_line ol
      where ol.document_id = v_grn and ol.item_id = v_item2) = v_quar
    and (select ol.location_id from erp.document_line ol
          where ol.document_id = v_grn and ol.item_id = v_item) is null,
    'erp.item.quarantine_on_receipt, read for the first time since B7';

  -- Invoiced for exactly what was received, at the agreed price.
  v_inv := erp.open_document('purchase_invoice', v_sup, null, v_site);
  v_status := erp.invoice_against(v_inv, v_pol, 100, 1000);
  return query select 'an invoice that agrees with the receipt matches',
    v_status = 'matched'
    and (select count(*) from erp.match_exception e where e.order_line_id = v_pol) = 0,
    'no exception, because there is nothing for anybody to look at';

  -- Now one that does not: billed at 1200 against 1000 agreed.
  perform erp.receive_against(v_grn, v_pol3, 50);
  v_status := erp.invoice_against(v_inv, v_pol3, 50, 1200);
  return query select 'a price above tolerance raises a price variance',
    v_status = 'price_variance',
    '1200 against 1000 agreed is twenty per cent, and tolerance is two';

  return query select 'and it is on the workbench, priced',
    (select w.value_at_risk_minor from erp.match_exception_workbench() w
      where w.line_no = 30) = 10000,
    -- Line numbers step by ten, which is why this reads 30 rather than 3.
    '200 minor over on fifty units, on the third order line';

  -- Being billed for more than arrived: sixty received, eighty invoiced.
  perform erp.receive_against(v_grn, v_pol4, 60);
  v_status := erp.invoice_against(v_inv, v_pol4, 80, 1000);
  return query select 'being billed for more than arrived is a quantity variance',
    v_status = 'quantity_variance',
    'invoiced against received, never against ordered';

  -- Deliberately not a tie. Both variances were twenty thousand in the first
  -- draft of this suite, so the ordering case passed or failed on the tie-break
  -- and proved nothing about the ordering.
  return query select 'the workbench is ordered by what the difference is worth',
    (select w.line_no from erp.match_exception_workbench() w limit 1) = 40,
    'twenty units at 1000 beats two hundred minor on fifty';

  -- The rest arrives, and the exception closes by matching rather than by
  -- somebody remembering to close it.
  perform erp.receive_against(v_grn, v_pol4, 20);
  v_status := erp.match_three_way(v_pol4);
  return query select 'a later receipt that closes the gap resolves the exception',
    v_status = 'matched'
    and (select bool_and(e.resolved_at is not null) from erp.match_exception e
          where e.order_line_id = v_pol4),
    'resolved by the match, not left for somebody to close by hand';

  -- ---------------------------------------------------------------------------
  -- GRNI.
  -- ---------------------------------------------------------------------------
  return query select 'GRNI shows what arrived and was not billed',
    (select count(*) from erp.grni_report() g where g.item_code = 'MED') = 1,
    'ten inspected units received against an order and never invoiced';

  return query select 'and it is aged, because an old one is a different problem',
    (select g.bucket from erp.grni_report() g where g.item_code = 'MED') = '0-30',
    'an old GRNI balance is an invoice nobody sent or a receipt that never was';

  -- ---------------------------------------------------------------------------
  -- Landed cost.
  -- ---------------------------------------------------------------------------
  perform erp.transition_document(v_grn,'post');

  select c.unit_cost_minor into v_cost from erp.item_cost c
   where c.tenant_id = r.tenant_id and c.item_id = v_item;
  return query select 'stock arrives at what was paid for it',
    v_cost = 1000, format('unit cost %s before freight', v_cost);

  insert into erp.landed_cost (
    tenant_id, receipt_document_id, charge_code, description,
    amount_minor, currency, allocation_basis)
  values (r.tenant_id, v_grn, 'FREIGHT', 'Sea freight', 100000, 'GBP', 'value')
  returning id into v_lc;

  v_n := erp.allocate_landed_cost(v_lc);
  return query select 'landed cost is allocated in full, to the penny',
    v_n = 100000,
    'rounding goes on the last line; somewhere is arbitrary, nowhere is wrong';

  select c.unit_cost_minor into v_cost from erp.item_cost c
   where c.tenant_id = r.tenant_id and c.item_id = v_item;
  return query select 'and the stock is now worth more than was paid the supplier',
    v_cost > 1000,
    format('unit cost %s after freight; valuing it as if it arrived free '
           'understates inventory', v_cost);

  begin
    perform erp.allocate_landed_cost(v_lc);
    v_ok := false; v_msg := 'a charge was allocated twice';
  exception when sqlstate '23505' then v_ok := true; v_msg := left(sqlerrm,54); end;
  return query select 'a charge cannot be allocated twice', v_ok, v_msg;

  -- ---------------------------------------------------------------------------
  -- Budget.
  -- ---------------------------------------------------------------------------
  return query select 'and a committed order reduces what is left',
    (select b.committed_minor from erp.budget_position('OPS') b) = 280000
    and (select b.remaining_minor from erp.budget_position('OPS') b) = 49720000,
    'a budget counting only invoices says there is money until every order lands';

  begin
    perform erp.check_budget('OPS', 100000000);
    v_ok := false; v_msg := 'an overspend passed a blocking budget';
  exception when sqlstate '42501' then v_ok := true; v_msg := left(sqlerrm,52); end;
  return query select 'a blocking budget refuses an overspend', v_ok, v_msg;

  -- ---------------------------------------------------------------------------
  -- Configuration assertions.
  -- ---------------------------------------------------------------------------
  return query select 'every promoted control can fire',
    (select count(*) from erp.procurement_configuration_report()) = 0,
    'an exception with no queue to land in is not a control';

  update erp.match_tolerance set approval_chain_code = null
   where tenant_id = r.tenant_id and code = 'default';
  return query select 'a match tolerance with nowhere to send exceptions fails the build',
    (select count(*) from erp.procurement_configuration_report()
      where finding = 'a match tolerance raises exceptions with nowhere to send them') = 1,
    'the variance would be raised and read by nobody';
  update erp.match_tolerance set approval_chain_code = 'match_exception'
   where tenant_id = r.tenant_id and code = 'default';

  set constraints all immediate;
  perform set_config('request.jwt.claims','',true);
  perform erp.begin_tenant_purge(r.tenant_id);
  delete from erp.tenant where id = r.tenant_id;
  perform erp.end_tenant_purge();
end;
$$;

create or replace function erp_test.assert_procurement_controls_suite()
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_pass integer; v_total integer; v_detail text;
  c_expected constant integer := 24;
begin
  create temporary table if not exists zz_proc_result
    (case_name text, passed boolean, detail text) on commit drop;
  delete from zz_proc_result;
  insert into zz_proc_result select * from erp_test.procurement_controls_suite();

  select count(*) filter (where passed), count(*),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_pass, v_total, v_detail from zz_proc_result;

  if v_total <> c_expected then
    raise exception 'ERPWARE_PROCUREMENT_CONTROLS_SUITE_INCOMPLETE: % cases, expected %',
      v_total, c_expected using errcode = 'P0001';
  end if;

  if v_pass < v_total then
    raise exception E'ERPWARE_PROCUREMENT_CONTROLS_SUITE_FAILED: %/%\n%',
      v_pass, v_total, v_detail using errcode = 'P0001';
  end if;

  return format('procurement controls: %s/%s', v_pass, v_total);
end;
$$;

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_procurement_controls_sane();
select erp.assert_no_dead_configuration();
select erp.assert_public_api_safe();
select erp.assert_resource_coverage('en');
select erp.assert_isolation();
