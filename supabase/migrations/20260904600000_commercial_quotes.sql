-- =============================================================================
-- Part 17 §17.7: the quote and pricing builder
--
-- Specification v1.5 §17.7, built on the primitives §17.5 insists on. A quote
-- is a quotation document of the platform organisation with its own lifecycle,
-- its lines are document lines whose products are price items, its discount
-- approval is an approval chain on the document, and its order form is an
-- output template rendered through Part 14.
--
--   "A quote is assembled from price items, not typed. Selecting a plan pulls
--   its capability set; adding a capability that has prerequisites offers them;
--   band selections validate against each other"
--   → erp.add_quote_line() refuses a second plan tier, refuses a feature whose
--     prerequisites are neither on the plan nor on the quote (naming them, which
--     is what "offers" means to a function), refuses a band that the plan
--     already includes, and takes the unit price from the rate card.
--
--   "Margin is shown live as the quote is built, per line and in total, against
--   the cost model. A discount that takes a line below cost is visible before
--   it is offered"
--   → erp.quote_margin() is the one reader, computed every time it is asked,
--     never stored. D36.
--
--   "Discounting is banded and approval-routed through the standard engine: a
--   discount within threshold needs nobody, beyond it needs the platform owner.
--   The approval is recorded against the quote version"
--   → the commercial_quote_terms approval chain: one step, conditional on
--     max_discount_pct, exactly as sales order terms are. A quote within the
--     threshold approves itself on submission; beyond it, a task opens and
--     erp.approve_quote() refuses until it is decided.
--
--   "Quotes are versioned and expiring, with a validity date and a clear
--   supersession chain"
--   → erp.revise_quote() opens the next version as a new document carrying
--     the lines and the supersession both ways; the previous one moves to
--     superseded. Every version is retained. A scheduled job expires what
--     passed its validity.
--
--   "Quote to order form is a conversion, not a re-key. The order form renders
--   through Part 14, carries the quote version, and is issued for signature"
--   → erp.issue_quote() renders the order_form template against the document
--     and records the render with its checksum against the quote.
-- =============================================================================

-- ── The quote, alongside its document ────────────────────────────────────────

create table if not exists erp.commercial_quote (
  id                        uuid primary key default gen_random_uuid(),
  tenant_id                 uuid not null references erp.tenant (id) on delete cascade,
  document_id               uuid not null,
  customer_tenant_code      text,
  price_book_code           text not null,
  price_book_version        integer not null,
  term_kind                 text not null,
  term_months               integer not null default 12,
  currency                  char(3) not null,
  valid_until               date not null,
  version                   integer not null default 1,
  supersedes_document_id    uuid,
  superseded_by_document_id uuid,
  order_form_render_id      uuid,
  order_form_issued_at      timestamptz,
  notes                     text,
  created_at                timestamptz not null default now(),
  created_by                uuid,
  updated_at                timestamptz not null default now(),
  updated_by                uuid,
  constraint commercial_quote_term_known check (term_kind in ('annual', 'multi_year', 'monthly')),
  constraint commercial_quote_term_positive check (term_months > 0),
  constraint commercial_quote_version_positive check (version >= 1),
  constraint commercial_quote_one_per_document unique (tenant_id, document_id),
  constraint commercial_quote_tenant_id_key unique (tenant_id, id),
  constraint commercial_quote_document_fk
    foreign key (tenant_id, document_id) references erp.document (tenant_id, id) on delete cascade
);

comment on table erp.commercial_quote is
  'Specification v1.5 §17.7: what a quotation document of the platform '
  'organisation carries beyond the document spine — the price book version it '
  'was raised against, its term, its validity, its version in a supersession '
  'chain, and the order form rendered from it. The lines are document lines; '
  'the lifecycle is the document''s state machine.';

-- ── The installer: the commercial module as a change set ─────────────────────

create or replace function erp.configure_commercial(
  p_discount_threshold_pct numeric default 10,
  p_approver_role text default 'administrator')
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_entity uuid;
  v_cs     uuid;
  v_blocks jsonb := jsonb_build_array(
    jsonb_build_object('kind', 'title', 'fields', jsonb_build_array('brand_name', 'document_number', 'document_date')),
    jsonb_build_object('kind', 'counterparty', 'fields', jsonb_build_array('party_name', 'party_address')),
    jsonb_build_object('kind', 'summary', 'fields', jsonb_build_array('our_reference', 'currency', 'entity_name')),
    jsonb_build_object('kind', 'lines', 'fields', jsonb_build_array('line_no', 'item_code', 'description', 'quantity', 'unit_price', 'net_amount')),
    jsonb_build_object('kind', 'totals', 'fields', jsonb_build_array('total_net', 'total_gross', 'line_count')),
    jsonb_build_object('kind', 'note', 'fields', jsonb_build_array('notes')),
    jsonb_build_object('kind', 'signature', 'fields', jsonb_build_array()));
begin
  perform erp.require_platform_organisation();
  select e.id into v_entity from erp.entity e where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;
  if v_entity is null then
    raise exception 'ERPWARE_NO_ENTITY: the platform organisation needs a company before it can quote' using errcode = '23503';
  end if;

  v_cs := erp.install_module_config(
    'commercial', 'Commercial',
    'The platform''s own commercial process: the quote lifecycle, discount approval banded on the same engine as every other approval, and the order form template.',
    jsonb_build_array(
      jsonb_build_object('kind', 'state_machine', 'key', 'commercial_quote', 'payload',
        jsonb_build_object(
          'code', 'commercial_quote', 'object_type', 'document', 'name', 'Commercial quote',
          'states', jsonb_build_array(
            jsonb_build_object('code', 'draft', 'name', 'Draft', 'is_initial', true, 'sort_order', 10),
            jsonb_build_object('code', 'pending_approval', 'name', 'Pending approval', 'sort_order', 20),
            jsonb_build_object('code', 'approved', 'name', 'Approved', 'sort_order', 30),
            jsonb_build_object('code', 'issued', 'name', 'Issued', 'sort_order', 40),
            jsonb_build_object('code', 'accepted', 'name', 'Accepted', 'is_terminal', true, 'sort_order', 50),
            jsonb_build_object('code', 'declined', 'name', 'Declined', 'is_terminal', true, 'sort_order', 80),
            jsonb_build_object('code', 'expired', 'name', 'Expired', 'is_terminal', true, 'sort_order', 85),
            jsonb_build_object('code', 'superseded', 'name', 'Superseded', 'is_terminal', true, 'sort_order', 90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code', 'submit', 'name', 'Submit', 'from', 'draft', 'to', 'pending_approval', 'required_permission', 'sales.order'),
            jsonb_build_object('code', 'approve', 'name', 'Approve', 'from', 'pending_approval', 'to', 'approved', 'required_permission', 'sales.order'),
            jsonb_build_object('code', 'reject', 'name', 'Return to draft', 'from', 'pending_approval', 'to', 'draft', 'required_permission', 'sales.order'),
            jsonb_build_object('code', 'issue', 'name', 'Issue', 'from', 'approved', 'to', 'issued', 'required_permission', 'sales.order'),
            jsonb_build_object('code', 'accept', 'name', 'Accept', 'from', 'issued', 'to', 'accepted', 'required_permission', 'sales.order'),
            jsonb_build_object('code', 'decline', 'name', 'Decline', 'from', 'issued', 'to', 'declined', 'required_permission', 'sales.order'),
            jsonb_build_object('code', 'expire', 'name', 'Expire', 'from', 'issued', 'to', 'expired', 'required_permission', 'sales.order'),
            jsonb_build_object('code', 'supersede_draft', 'name', 'Supersede', 'from', 'draft', 'to', 'superseded', 'required_permission', 'sales.order'),
            jsonb_build_object('code', 'supersede_approved', 'name', 'Supersede', 'from', 'approved', 'to', 'superseded', 'required_permission', 'sales.order'),
            jsonb_build_object('code', 'supersede_issued', 'name', 'Supersede', 'from', 'issued', 'to', 'superseded', 'required_permission', 'sales.order')))),

      -- §17.7: "a discount within threshold needs nobody, beyond it needs the
      -- platform owner". The same shape as sales order terms: one conditional
      -- step over the context every document transition already carries.
      jsonb_build_object('kind', 'approval_chain', 'key', 'commercial_quote_terms', 'payload',
        jsonb_build_object(
          'code', 'commercial_quote_terms', 'name', 'Commercial quote discount approval',
          'object_type', 'document',
          'applies_when', jsonb_build_object('==', jsonb_build_array(
            jsonb_build_object('var', 'document_type'), 'commercial_quote')),
          'value_field', 'total_minor', 'priority', 100,
          'material_fields', jsonb_build_array('total_minor', 'party_id', 'max_discount_pct'),
          'steps', jsonb_build_array(
            jsonb_build_object('seq', 1, 'code', 'discount', 'name', 'Discount beyond threshold',
              'approver_kind', 'role', 'role', p_approver_role, 'min_approvals', 1,
              'condition', jsonb_build_object('>', jsonb_build_array(
                jsonb_build_object('var', 'max_discount_pct'), p_discount_threshold_pct)))))),

      -- §17.7: the order form, through Part 14.
      jsonb_build_object('kind', 'output_template', 'key', 'order_form', 'payload',
        jsonb_build_object(
          'code', 'order_form', 'name_key', 'output.template.order_form',
          'kind', 'document', 'base_type', 'quotation', 'page', 'A4', 'blocks', v_blocks,
          'version', jsonb_build_object(
            'rendering_engine', 'pdf', 'page', '{}'::jsonb, 'blocks', v_blocks,
            'required_permission', 'sales.order'))),

      -- §17.7: "quotes are versioned and expiring". The sweep that expires them.
      jsonb_build_object('kind', 'job', 'key', 'expire_commercial_quotes', 'payload',
        jsonb_build_object(
          'code', 'expire_commercial_quotes', 'name', 'Expire commercial quotes',
          'handler_code', 'commercial.expire_quotes', 'schedule_kind', 'interval',
          'interval_seconds', 3600, 'timeout_seconds', 300, 'is_enabled', true))));

  insert into erp.numbering_rule (tenant_id, code, entity_id, prefix, pad_to, reset_period, next_value)
  values (v_tenant, 'commercial_quote', v_entity, 'CQ-', 6, 'yearly', 1)
  on conflict (tenant_id, code) do nothing;

  insert into erp.document_type (
    tenant_id, code, base_type_code, name, entity_id, state_machine_code, approval_chain_code, numbering_rule_id)
  select v_tenant, 'commercial_quote', 'quotation', 'Commercial quote', v_entity,
         'commercial_quote', 'commercial_quote_terms', n.id
    from erp.numbering_rule n where n.tenant_id = v_tenant and n.code = 'commercial_quote'
  on conflict (tenant_id, code) do update set
    state_machine_code = excluded.state_machine_code,
    approval_chain_code = excluded.approval_chain_code,
    numbering_rule_id = excluded.numbering_rule_id;

  return v_cs;
end;
$$;

comment on function erp.configure_commercial is
  'Specification v1.5 §17.5 and §17.7: installs the commercial module in the '
  'platform organisation through a change set — the quote lifecycle, the '
  'discount approval chain with its threshold, the order form template and the '
  'expiry job — then binds the commercial_quote document type to them.';

insert into erp_ref.job_handler
  (code, name_key, description, module_code, parameter_schema, default_timeout_seconds, forbids_overlap, is_current, sql_function)
values
  ('commercial.expire_quotes', 'job_handler.expire_commercial_quotes.name',
   'Moves every issued quote past its validity date to expired. §17.7: quotes are versioned and expiring.',
   'commercial', '{"type": "object", "additionalProperties": false}'::jsonb, 300, true, true, 'expire_commercial_quotes')
on conflict (code) do update set
  description = excluded.description, sql_function = excluded.sql_function, is_current = excluded.is_current, module_code = excluded.module_code;

-- ── Reading a quote's position ───────────────────────────────────────────────

create or replace function erp.quote_discount_threshold()
returns numeric
language sql
stable
set search_path = ''
as $$
  -- The threshold lives in one place: the condition on the discount step of the
  -- chain in force. Read from there rather than copied, so the number the
  -- builder shows is the number the engine routes on.
  select (s.condition -> '>' -> 1)::numeric
    from erp.approval_chain c
    join erp.approval_chain_version v on v.tenant_id = c.tenant_id and v.approval_chain_id = c.id and v.status = 'active'
    join erp.approval_step s on s.tenant_id = v.tenant_id and s.approval_chain_version_id = v.id and s.code = 'discount'
   where c.tenant_id = erp.require_tenant_id() and c.code = 'commercial_quote_terms'
   order by v.version desc
   limit 1
$$;

create or replace function erp.quote_margin(p_document_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with q as (
    select cq.*, d.currency as doc_currency
      from erp.commercial_quote cq
      join erp.document d on d.tenant_id = cq.tenant_id and d.id = cq.document_id
     where cq.tenant_id = erp.require_tenant_id() and cq.document_id = p_document_id),
  lines as (
    select l.id as line_id, l.line_no, i.code as item_code, i.name, pi.kind, l.quantity,
           l.unit_price_minor as list_minor, l.discount_pct,
           round(l.unit_price_minor * (1 - coalesce(l.discount_pct, 0) / 100.0))::bigint as quoted_unit_minor,
           erp.unit_cost_for(l.item_id, q.currency) as cost_unit_minor,
           pi.plan_code, pi.capability_code, pi.entitlement_code, pi.band_from, pi.band_to,
           pi.support_severity_code, pi.legislation_pack_code
      from q
      join erp.document_line l on l.tenant_id = q.tenant_id and l.document_id = q.document_id and not l.is_cancelled
      join erp.item i on i.tenant_id = l.tenant_id and i.id = l.item_id
      left join erp.price_item pi on pi.tenant_id = l.tenant_id and pi.item_id = l.item_id),
  priced as (
    select *, round(quoted_unit_minor * quantity)::bigint as quoted_minor,
           round(list_minor * quantity)::bigint as list_total_minor,
           round(cost_unit_minor * quantity)::bigint as cost_minor,
           round(quoted_unit_minor * quantity - coalesce(cost_unit_minor, 0) * quantity)::bigint as margin_minor
      from lines)
  select jsonb_build_object(
    'currency', (select currency from q),
    'threshold_pct', erp.quote_discount_threshold(),
    'lines', coalesce((select jsonb_agg(jsonb_build_object(
               'line_id', p.line_id, 'line_no', p.line_no, 'item_code', p.item_code, 'name', p.name, 'kind', p.kind,
               'quantity', p.quantity, 'list_minor', p.list_minor, 'discount_pct', p.discount_pct,
               'quoted_unit_minor', p.quoted_unit_minor, 'quoted_minor', p.quoted_minor,
               'cost_unit_minor', p.cost_unit_minor, 'cost_minor', p.cost_minor,
               'margin_minor', case when p.cost_unit_minor is null then null else p.margin_minor end,
               'margin_pct', case when p.cost_unit_minor is null or p.quoted_minor = 0 then null
                                  else round(100.0 * p.margin_minor / p.quoted_minor, 1) end,
               'below_cost', p.cost_unit_minor is not null and p.quoted_unit_minor < p.cost_unit_minor,
               'plan_code', p.plan_code, 'capability_code', p.capability_code,
               'entitlement_code', p.entitlement_code, 'band_from', p.band_from, 'band_to', p.band_to,
               'support_severity_code', p.support_severity_code, 'legislation_pack_code', p.legislation_pack_code)
             order by p.line_no) from priced p), '[]'::jsonb),
    'totals', (select jsonb_build_object(
               'list_minor', coalesce(sum(list_total_minor), 0),
               'quoted_minor', coalesce(sum(quoted_minor), 0),
               'cost_minor', coalesce(sum(cost_minor), 0),
               'margin_minor', coalesce(sum(quoted_minor), 0) - coalesce(sum(cost_minor), 0),
               'margin_pct', case when coalesce(sum(quoted_minor), 0) = 0 then null
                                  else round(100.0 * (sum(quoted_minor) - coalesce(sum(cost_minor), 0)) / sum(quoted_minor), 1) end,
               'max_discount_pct', coalesce(max(discount_pct), 0),
               'below_cost_lines', count(*) filter (where cost_unit_minor is not null and quoted_unit_minor < cost_unit_minor),
               'uncosted_lines', count(*) filter (where cost_unit_minor is null and kind <> 'legislation_pack'))
              from priced))
$$;

comment on function erp.quote_margin is
  'Specification v1.5 §17.7 and D36: margin per line and in total against the '
  'cost model, computed every time it is read and never stored, so what the '
  'builder shows while a discount is being typed is what the quote carries.';

-- ── The writers ──────────────────────────────────────────────────────────────

create or replace function erp.open_commercial_quote(
  p_party_code text, p_party_name text,
  p_price_book_code text, p_term_kind text default 'annual', p_term_months integer default 12,
  p_currency char(3) default 'GBP', p_valid_days integer default 30,
  p_customer_tenant_code text default null, p_notes text default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_party  uuid;
  v_entity uuid;
  v_doc    uuid;
  b        record;
begin
  perform erp.require_platform_organisation();
  perform erp.authorise('sales.order', null, null, null, 'commercial_quote', null);
  if not exists (select 1 from erp.document_type dt where dt.tenant_id = v_tenant and dt.code = 'commercial_quote' and dt.status = 'active') then
    raise exception 'ERPWARE_COMMERCIAL_NOT_INSTALLED: install the commercial module before quoting'
      using errcode = '23503', hint = 'erp_configure_commercial() installs the quote lifecycle, the discount approval and the order form.';
  end if;
  if p_term_kind not in ('annual', 'multi_year', 'monthly') then
    raise exception 'ERPWARE_UNKNOWN_TERM: % is not annual, multi_year or monthly', p_term_kind using errcode = '23514';
  end if;
  select * into b from erp.price_book_in_force(p_price_book_code);
  if not found then
    raise exception 'ERPWARE_UNKNOWN_PRICE_BOOK: % has no version in force', p_price_book_code using errcode = '23503';
  end if;
  if not (p_currency = any (b.currencies)) then
    raise exception 'ERPWARE_CURRENCY_NOT_ON_BOOK: % is not maintained on %', p_currency, p_price_book_code using errcode = '23514';
  end if;

  -- The prospect is a business partner of the platform organisation. Created
  -- through the ordinary writer, so it scores, deduplicates and audits like any
  -- other customer.
  select p.id into v_party from erp.party p where p.tenant_id = v_tenant and p.code = p_party_code;
  if v_party is null then
    v_party := erp.create_party(p_party_code, p_party_name, array['customer']::erp.party_role_kind[]);
  end if;
  select e.id into v_entity from erp.entity e where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;

  v_doc := erp.open_document('commercial_quote', v_party, v_entity, null, null, null, p_currency);
  update erp.document set notes = p_notes, our_reference = p_price_book_code || ' v' || b.version, updated_at = now()
   where id = v_doc;

  insert into erp.commercial_quote
    (tenant_id, document_id, customer_tenant_code, price_book_code, price_book_version, term_kind, term_months,
     currency, valid_until, notes)
  values (v_tenant, v_doc, p_customer_tenant_code, p_price_book_code, b.version, p_term_kind, p_term_months,
          p_currency, current_date + greatest(p_valid_days, 1), p_notes);
  return v_doc;
end;
$$;

comment on function erp.open_commercial_quote is
  'Specification v1.5 §17.7: raises a quote as a quotation document of the '
  'platform organisation, naming the price book version in force, the term, '
  'the currency and the validity date. The prospect is an ordinary business '
  'partner.';

create or replace function erp.require_quote_in_draft(p_document_id uuid)
returns erp.commercial_quote
language plpgsql
stable
set search_path = ''
as $$
declare q erp.commercial_quote; v_state text;
begin
  select * into q from erp.commercial_quote cq where cq.tenant_id = erp.require_tenant_id() and cq.document_id = p_document_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_QUOTE: %', p_document_id using errcode = '23503';
  end if;
  v_state := erp.object_current_state('document', p_document_id);
  if v_state <> 'draft' then
    raise exception 'ERPWARE_QUOTE_NOT_IN_DRAFT: version % is %, and only a draft is edited', q.version, v_state
      using errcode = '23514', hint = 'Revise the quote to open the next version and edit that.';
  end if;
  return q;
end;
$$;

create or replace function erp.add_quote_line(p_document_id uuid, p_item_code text, p_quantity numeric default 1, p_discount_pct numeric default 0)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  q        erp.commercial_quote;
  v_item   uuid;
  pi       erp.price_item%rowtype;
  v_plan   text;
  v_rate   bigint;
  v_line   uuid;
  v_missing text := '';
  v_limit  numeric;
  r        record;
begin
  perform erp.require_platform_organisation();
  perform erp.authorise('sales.order', null, null, null, 'commercial_quote', p_document_id);
  q := erp.require_quote_in_draft(p_document_id);

  select i.id into v_item from erp.item i where i.tenant_id = v_tenant and i.code = p_item_code and i.status = 'active';
  select * into pi from erp.price_item x where x.tenant_id = v_tenant and x.item_id = v_item and x.status = 'active';
  if v_item is null or pi.id is null then
    raise exception 'ERPWARE_NOT_A_PRICE_ITEM: % is not on the price book', p_item_code using errcode = '23503';
  end if;
  if coalesce(p_discount_pct, 0) < 0 or coalesce(p_discount_pct, 0) > 100 then
    raise exception 'ERPWARE_DISCOUNT_OUT_OF_RANGE: % is not a percentage', p_discount_pct using errcode = '23514';
  end if;

  -- The plan already on the quote, if any: what the feature and band checks
  -- below are measured against.
  select x.plan_code into v_plan
    from erp.document_line l
    join erp.price_item x on x.tenant_id = l.tenant_id and x.item_id = l.item_id
   where l.tenant_id = v_tenant and l.document_id = p_document_id and not l.is_cancelled and x.kind = 'plan_tier'
   limit 1;

  case pi.kind
    when 'plan_tier' then
      if v_plan is not null then
        raise exception 'ERPWARE_QUOTE_HAS_A_PLAN: this quote already carries the % plan; a quote names one plan', v_plan
          using errcode = '23514', hint = 'Remove the plan line first, or revise the quote.';
      end if;
    when 'capability_addon' then
      -- "adding a capability that has prerequisites offers them": what is
      -- offered is named, and the line is refused until they are there.
      for r in
        select d.requires_code, d.rationale from erp_ref.capability_dependency d
         where d.capability_code = pi.capability_code
           and not exists (select 1 from erp_meta.plan_capability pc
                            where pc.plan_code = v_plan and pc.capability_code = d.requires_code)
           and not exists (select 1 from erp.document_line l
                            join erp.price_item x on x.tenant_id = l.tenant_id and x.item_id = l.item_id
                           where l.tenant_id = v_tenant and l.document_id = p_document_id and not l.is_cancelled
                             and x.kind = 'capability_addon' and x.capability_code = d.requires_code)
      loop
        v_missing := v_missing || format(E'  %s — %s\n', r.requires_code, r.rationale);
      end loop;
      if v_missing <> '' then
        raise exception E'ERPWARE_QUOTE_NEEDS_PREREQUISITE: % requires features that are neither on the plan nor on the quote\n%',
          pi.capability_code, v_missing
          using errcode = '23514', hint = 'Add these first, as add-ons or by choosing a plan that includes them.';
      end if;
      if v_plan is not null and exists (select 1 from erp_meta.plan_capability pc where pc.plan_code = v_plan and pc.capability_code = pi.capability_code) then
        raise exception 'ERPWARE_FEATURE_ON_PLAN: the % plan already includes %', v_plan, pi.capability_code
          using errcode = '23514', hint = 'A feature the plan carries is not sold twice.';
      end if;
    when 'user_band', 'company_band', 'site_band', 'volume_band', 'storage_band', 'retention_band', 'environment' then
      -- "band selections validate against each other": one band per
      -- entitlement, and a band the plan already includes is nothing.
      if exists (select 1 from erp.document_line l
                  join erp.price_item x on x.tenant_id = l.tenant_id and x.item_id = l.item_id
                 where l.tenant_id = v_tenant and l.document_id = p_document_id and not l.is_cancelled
                   and x.entitlement_code = pi.entitlement_code) then
        raise exception 'ERPWARE_QUOTE_HAS_A_BAND: this quote already carries a band for %', pi.entitlement_code
          using errcode = '23514';
      end if;
      if v_plan is not null then
        select pe.limit_value into v_limit from erp_meta.plan_entitlement pe
         where pe.plan_code = v_plan and pe.entitlement_code = pi.entitlement_code;
        if v_limit is null and exists (select 1 from erp_meta.plan_entitlement pe where pe.plan_code = v_plan and pe.entitlement_code = pi.entitlement_code) then
          raise exception 'ERPWARE_BAND_WITHIN_PLAN: the % plan already has unlimited %', v_plan, pi.entitlement_code using errcode = '23514';
        end if;
        if v_limit is not null and pi.band_to <= v_limit then
          raise exception 'ERPWARE_BAND_WITHIN_PLAN: the % plan already includes % %, so a band to % sells nothing',
            v_plan, v_limit, pi.entitlement_code, pi.band_to using errcode = '23514';
        end if;
      end if;
    else
      null;
  end case;

  v_rate := erp.rate_for(v_item, q.price_book_code, q.term_kind, q.currency);
  if v_rate is null then
    raise exception 'ERPWARE_NO_RATE_ON_BOOK: % has no % rate in % on %', p_item_code, q.term_kind, q.currency, q.price_book_code
      using errcode = '23503', hint = 'Set the rate on the price book; a quote is assembled from the rate card, not typed.';
  end if;

  v_line := erp.add_document_line(p_document_id, v_item, greatest(p_quantity, 1), v_rate,
                                  (select i.name from erp.item i where i.id = v_item));
  if coalesce(p_discount_pct, 0) > 0 and pi.kind <> 'legislation_pack' then
    update erp.document_line set discount_pct = p_discount_pct, updated_at = now() where id = v_line;
  end if;
  return v_line;
end;
$$;

comment on function erp.add_quote_line is
  'Specification v1.5 §17.7: one price item onto a draft quote at the rate card '
  'price. Refuses a second plan, a feature whose prerequisites are absent '
  '(naming them), a feature the plan already carries, a second band for one '
  'entitlement and a band the plan already includes. Security definer only to '
  'read erp_meta.plan_capability and plan_entitlement.';

create or replace function erp.set_quote_line_discount(p_line_id uuid, p_discount_pct numeric)
returns void
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); v_doc uuid; v_kind text;
begin
  perform erp.require_platform_organisation();
  select l.document_id, pi.kind into v_doc, v_kind
    from erp.document_line l
    left join erp.price_item pi on pi.tenant_id = l.tenant_id and pi.item_id = l.item_id
   where l.tenant_id = v_tenant and l.id = p_line_id and not l.is_cancelled;
  if v_doc is null then
    raise exception 'ERPWARE_UNKNOWN_QUOTE_LINE: %', p_line_id using errcode = '23503';
  end if;
  perform erp.authorise('sales.order', null, null, null, 'commercial_quote', v_doc);
  perform erp.require_quote_in_draft(v_doc);
  if coalesce(p_discount_pct, 0) < 0 or coalesce(p_discount_pct, 0) > 100 then
    raise exception 'ERPWARE_DISCOUNT_OUT_OF_RANGE: % is not a percentage', p_discount_pct using errcode = '23514';
  end if;
  update erp.document_line set discount_pct = case when v_kind = 'legislation_pack' then 0 else coalesce(p_discount_pct, 0) end,
         updated_at = now()
   where id = p_line_id;
end;
$$;

create or replace function erp.remove_quote_line(p_line_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); v_doc uuid;
begin
  perform erp.require_platform_organisation();
  select l.document_id into v_doc from erp.document_line l where l.tenant_id = v_tenant and l.id = p_line_id;
  if v_doc is null then
    raise exception 'ERPWARE_UNKNOWN_QUOTE_LINE: %', p_line_id using errcode = '23503';
  end if;
  perform erp.authorise('sales.order', null, null, null, 'commercial_quote', v_doc);
  perform erp.require_quote_in_draft(v_doc);
  update erp.document_line set is_cancelled = true, line_state = 'cancelled', updated_at = now() where id = p_line_id;
end;
$$;

create or replace function erp.submit_quote(p_document_id uuid)
returns text
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); v_state text; v_status erp.approval_status;
begin
  perform erp.require_platform_organisation();
  perform erp.require_quote_in_draft(p_document_id);
  if not exists (select 1 from erp.document_line l where l.tenant_id = v_tenant and l.document_id = p_document_id and not l.is_cancelled) then
    raise exception 'ERPWARE_QUOTE_IS_EMPTY: a quote is assembled from price items before it is submitted' using errcode = '23514';
  end if;
  if not exists (select 1 from erp.document_line l
                  join erp.price_item pi on pi.tenant_id = l.tenant_id and pi.item_id = l.item_id
                 where l.tenant_id = v_tenant and l.document_id = p_document_id and not l.is_cancelled and pi.kind = 'plan_tier') then
    raise exception 'ERPWARE_QUOTE_HAS_NO_PLAN: a quote names the plan it sells' using errcode = '23514';
  end if;
  -- The transition requests approval through the chain; the chain decides
  -- whether anybody is needed. A discount within threshold leaves no step
  -- applying, the request approves itself, and the quote moves straight on.
  v_state := erp.transition_document(p_document_id, 'submit');
  select a.status into v_status from erp.approval_state('document', p_document_id) a limit 1;
  if v_status = 'approved' then
    v_state := erp.transition_document(p_document_id, 'approve', 'within the discount threshold');
  end if;
  return v_state;
end;
$$;

create or replace function erp.approve_quote(p_document_id uuid)
returns text
language plpgsql
set search_path = ''
as $$
declare v_status erp.approval_status; v_outstanding bigint;
begin
  perform erp.require_platform_organisation();
  select a.status, a.outstanding into v_status, v_outstanding
    from erp.approval_state('document', p_document_id) a limit 1;
  if v_status is distinct from 'approved' then
    raise exception 'ERPWARE_QUOTE_NOT_APPROVED: the discount on this quote is %, with % task(s) outstanding',
      coalesce(v_status::text, 'not yet requested'), coalesce(v_outstanding, 0)
      using errcode = '23514', hint = 'The approver decides the task under My approvals; the quote moves on once they have.';
  end if;
  return erp.transition_document(p_document_id, 'approve');
end;
$$;

comment on function erp.approve_quote is
  'Specification v1.5 §17.7: moves an approved quote on. Refuses while the '
  'discount approval is pending or rejected, so the transition cannot outrun '
  'the engine that was asked.';

create or replace function erp.issue_quote(p_document_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  q        erp.commercial_quote;
  v_render jsonb; v_content text; v_req jsonb; v_render_id uuid; v_state text;
begin
  perform erp.require_platform_organisation();
  select * into q from erp.commercial_quote cq where cq.tenant_id = v_tenant and cq.document_id = p_document_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_QUOTE: %', p_document_id using errcode = '23503';
  end if;
  if q.valid_until < current_date then
    raise exception 'ERPWARE_QUOTE_EXPIRED: version % was valid until %', q.version, q.valid_until
      using errcode = '23514', hint = 'Revise the quote; the next version takes a new validity date.';
  end if;
  v_state := erp.transition_document(p_document_id, 'issue');

  -- §17.7: "quote to order form is a conversion, not a re-key". The order form
  -- is the document rendered through the order_form template, archived with
  -- its checksum and the quote version it carries.
  v_render := erp.render_output_template('order_form', p_document_id, 'en')
              || jsonb_build_object('quote_version', q.version, 'price_book', q.price_book_code || ' v' || q.price_book_version,
                                    'term_kind', q.term_kind, 'term_months', q.term_months, 'valid_until', q.valid_until,
                                    'margin', erp.quote_margin(p_document_id) - 'lines');
  v_content := v_render::text;
  v_req := erp.request_output('order_form', 'document', p_document_id, 'archive_only', null, 'en', 1, 'commercial.quote_issued');
  -- The render is written whole, content included: erp.output_render is
  -- append-only, so an archive entry is never written and then filled in.
  insert into erp.output_render
    (tenant_id, output_request_id, template_version_id, version, format, checksum, byte_size,
     data_snapshot, document_reference, content)
  select v_tenant, r.id, r.template_version_id, tv.version, 'json', md5(v_content), octet_length(v_content),
         jsonb_build_object('quote_version', q.version, 'valid_until', q.valid_until),
         (select d.document_number from erp.document d where d.id = p_document_id), v_content
    from erp.output_request r
    join erp.output_template_version tv on tv.tenant_id = r.tenant_id and tv.id = r.template_version_id
   where r.tenant_id = v_tenant and r.id = (v_req ->> 'request_id')::uuid
  returning id into v_render_id;
  update erp.commercial_quote set order_form_render_id = v_render_id, order_form_issued_at = now(), updated_at = now()
   where id = q.id;
  return jsonb_build_object('state', v_state, 'render_id', v_render_id, 'checksum', md5(v_content), 'version', q.version);
end;
$$;

create or replace function erp.revise_quote(p_document_id uuid, p_reason text default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  q        erp.commercial_quote;
  d        erp.document%rowtype;
  v_state  text;
  v_new    uuid;
  l        record;
  v_line   uuid;
begin
  perform erp.require_platform_organisation();
  perform erp.authorise('sales.order', null, null, null, 'commercial_quote', p_document_id);
  select * into q from erp.commercial_quote cq where cq.tenant_id = v_tenant and cq.document_id = p_document_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_QUOTE: %', p_document_id using errcode = '23503';
  end if;
  if q.superseded_by_document_id is not null then
    raise exception 'ERPWARE_QUOTE_ALREADY_SUPERSEDED: version % was superseded; revise the latest version', q.version
      using errcode = '23514';
  end if;
  v_state := erp.object_current_state('document', p_document_id);
  if v_state not in ('draft', 'approved', 'issued', 'pending_approval') then
    raise exception 'ERPWARE_QUOTE_IS_%: a % quote is not revised', upper(v_state), v_state using errcode = '23514';
  end if;
  select * into d from erp.document x where x.id = p_document_id;

  -- The next version: a new document, the same party, book and term, the lines
  -- carried across with their discounts. Both documents point at each other,
  -- and the old one closes as superseded — a version, retained, not an edit.
  v_new := erp.open_document('commercial_quote', d.party_id, d.entity_id, null, null, null, d.currency);
  update erp.document set notes = d.notes, our_reference = d.our_reference, updated_at = now() where id = v_new;
  insert into erp.commercial_quote
    (tenant_id, document_id, customer_tenant_code, price_book_code, price_book_version, term_kind, term_months,
     currency, valid_until, version, supersedes_document_id, notes)
  values (v_tenant, v_new, q.customer_tenant_code, q.price_book_code, q.price_book_version, q.term_kind, q.term_months,
          q.currency, current_date + 30, q.version + 1, p_document_id, coalesce(p_reason, q.notes));
  for l in
    select x.item_id, x.quantity, x.unit_price_minor, x.description, x.discount_pct
      from erp.document_line x where x.tenant_id = v_tenant and x.document_id = p_document_id and not x.is_cancelled
     order by x.line_no
  loop
    v_line := erp.add_document_line(v_new, l.item_id, l.quantity, l.unit_price_minor, l.description);
    update erp.document_line set discount_pct = coalesce(l.discount_pct, 0), updated_at = now() where id = v_line;
  end loop;

  if v_state = 'pending_approval' then
    perform erp.transition_document(p_document_id, 'reject', coalesce(p_reason, 'revised'));
    v_state := 'draft';
  end if;
  perform erp.transition_document(p_document_id, 'supersede_' || v_state, coalesce(p_reason, 'revised as version ' || (q.version + 1)));
  update erp.commercial_quote set superseded_by_document_id = v_new, updated_at = now() where id = q.id;
  return v_new;
end;
$$;

comment on function erp.revise_quote is
  'Specification v1.5 §17.7: "a customer negotiating over six weeks generates '
  'six versions, all retained". The next version is a new document carrying the '
  'lines; the previous one is superseded, and each names the other.';

create or replace function erp.quote_transition(p_document_id uuid, p_transition_code text, p_reason text default null)
returns text
language plpgsql
set search_path = ''
as $$
begin
  perform erp.require_platform_organisation();
  if p_transition_code not in ('accept', 'decline', 'expire', 'reject') then
    raise exception 'ERPWARE_QUOTE_TRANSITION_HAS_A_DOOR: % is done through its own function', p_transition_code
      using errcode = '23514', hint = 'submit_quote, approve_quote, issue_quote and revise_quote each carry their own checks.';
  end if;
  return erp.transition_document(p_document_id, p_transition_code, p_reason);
end;
$$;

create or replace function erp.expire_commercial_quotes()
returns table(document_id uuid, document_number text, valid_until date)
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); r record;
begin
  for r in
    select cq.document_id, d.document_number, cq.valid_until
      from erp.commercial_quote cq
      join erp.document d on d.tenant_id = cq.tenant_id and d.id = cq.document_id
     where cq.tenant_id = v_tenant and cq.valid_until < current_date
       and erp.object_current_state('document', cq.document_id) = 'issued'
  loop
    perform erp.transition_document(r.document_id, 'expire', 'validity passed on ' || r.valid_until);
    document_id := r.document_id; document_number := r.document_number; valid_until := r.valid_until;
    return next;
  end loop;
end;
$$;

-- ── What the screens read ────────────────────────────────────────────────────

create or replace function erp.commercial_quotes_report()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'is_platform_organisation', erp.is_platform_organisation(),
    'installed', exists (select 1 from erp.document_type dt where dt.tenant_id = erp.require_tenant_id() and dt.code = 'commercial_quote' and dt.status = 'active'),
    'threshold_pct', erp.quote_discount_threshold(),
    'quotes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'document_id', cq.document_id, 'document_number', d.document_number, 'version', cq.version,
               'party_code', p.code, 'party_name', p.name, 'customer_tenant_code', cq.customer_tenant_code,
               'price_book', cq.price_book_code || ' v' || cq.price_book_version,
               'term_kind', cq.term_kind, 'term_months', cq.term_months, 'currency', cq.currency,
               'valid_until', cq.valid_until, 'state', erp.object_current_state('document', cq.document_id),
               'supersedes', cq.supersedes_document_id, 'superseded_by', cq.superseded_by_document_id,
               'issued_at', cq.order_form_issued_at,
               'total_minor', (erp.quote_margin(cq.document_id) -> 'totals' ->> 'quoted_minor')::bigint,
               'margin_pct', (erp.quote_margin(cq.document_id) -> 'totals' ->> 'margin_pct')::numeric,
               'created_at', cq.created_at)
             order by d.document_number desc, cq.version desc)
        from erp.commercial_quote cq
        join erp.document d on d.tenant_id = cq.tenant_id and d.id = cq.document_id
        left join erp.party p on p.tenant_id = d.tenant_id and p.id = d.party_id
       where cq.tenant_id = erp.require_tenant_id()), '[]'::jsonb),
    'price_books', coalesce((
      select jsonb_agg(distinct co.code) from erp.config_object co
       where co.tenant_id = erp.require_tenant_id() and co.config_type_code = 'commercial.price_book' and co.status = 'active'), '[]'::jsonb),
    'price_items', coalesce((
      select jsonb_agg(jsonb_build_object('code', i.code, 'name', i.name, 'kind', pi.kind) order by pi.kind, i.code)
        from erp.price_item pi join erp.item i on i.tenant_id = pi.tenant_id and i.id = pi.item_id
       where pi.tenant_id = erp.require_tenant_id() and pi.status = 'active'), '[]'::jsonb))
$$;

create or replace function erp.commercial_quote_detail(p_document_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'document_id', cq.document_id, 'document_number', d.document_number, 'version', cq.version,
    'party_code', p.code, 'party_name', p.name, 'customer_tenant_code', cq.customer_tenant_code,
    'price_book_code', cq.price_book_code, 'price_book_version', cq.price_book_version,
    'term_kind', cq.term_kind, 'term_months', cq.term_months, 'currency', cq.currency,
    'valid_until', cq.valid_until, 'notes', cq.notes,
    'state', erp.object_current_state('document', cq.document_id),
    'supersedes', cq.supersedes_document_id, 'superseded_by', cq.superseded_by_document_id,
    'margin', erp.quote_margin(cq.document_id),
    'approval', (select jsonb_build_object('status', a.status, 'chain_code', a.chain_code, 'outstanding', a.outstanding,
                                           'requested_at', a.requested_at, 'decided_at', a.decided_at)
                   from erp.approval_state('document', cq.document_id) a limit 1),
    'order_form', (select jsonb_build_object('render_id', o.id, 'checksum', o.checksum, 'rendered_at', o.rendered_at,
                                             'byte_size', o.byte_size, 'content', o.content::jsonb)
                     from erp.output_render o where o.tenant_id = cq.tenant_id and o.id = cq.order_form_render_id),
    'transitions', coalesce((select jsonb_agg(jsonb_build_object('code', t.transition_code, 'name', t.name, 'to_state', t.to_state, 'permitted', t.permitted))
                               from erp.available_transitions('document', cq.document_id, erp.document_transition_context(cq.document_id, null)) t), '[]'::jsonb))
    from erp.commercial_quote cq
    join erp.document d on d.tenant_id = cq.tenant_id and d.id = cq.document_id
    left join erp.party p on p.tenant_id = d.tenant_id and p.id = d.party_id
   where cq.tenant_id = erp.require_tenant_id() and cq.document_id = p_document_id
$$;

-- ── The findings and the assertion ───────────────────────────────────────────

create or replace function erp.commercial_quote_report()
returns table(finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  -- §17.7: an approved quote whose approval is not approved. The wrapper
  -- refuses it; this catches a transition made around the wrapper.
  select 'a quote is past pending approval while its discount approval is not approved', d.document_number,
         coalesce((select a.status::text from erp.approval_state('document', cq.document_id) a limit 1), 'no request')
    from erp.commercial_quote cq
    join erp.document d on d.tenant_id = cq.tenant_id and d.id = cq.document_id
   where erp.object_current_state('document', cq.document_id) in ('approved', 'issued', 'accepted')
     and coalesce((select a.status::text from erp.approval_state('document', cq.document_id) a limit 1), 'none') <> 'approved'
  union all
  -- §17.7: an issued quote with no order form is a conversion that did not happen.
  select 'an issued quote has no order form rendered', d.document_number, 'issue_quote renders it'
    from erp.commercial_quote cq
    join erp.document d on d.tenant_id = cq.tenant_id and d.id = cq.document_id
   where erp.object_current_state('document', cq.document_id) in ('issued', 'accepted') and cq.order_form_render_id is null
  union all
  -- The supersession chain points both ways or not at all.
  select 'a superseded quote does not name what superseded it', d.document_number, 'superseded_by is null'
    from erp.commercial_quote cq
    join erp.document d on d.tenant_id = cq.tenant_id and d.id = cq.document_id
   where erp.object_current_state('document', cq.document_id) = 'superseded' and cq.superseded_by_document_id is null
  order by 1, 2
$$;

create or replace function erp.assert_commercial_quotes_sound()
returns text
language plpgsql
set search_path = ''
as $$
declare v_count integer; v_detail text; v_quotes integer;
begin
  select count(*), string_agg(format('  %s — %s: %s', finding, reference, detail), E'\n')
    into v_count, v_detail from erp.commercial_quote_report();
  if v_count > 0 then
    raise exception 'ERPWARE_COMMERCIAL_QUOTES_UNSOUND: % finding(s)', v_count
      using errcode = 'P0001', detail = v_detail,
            hint = '§17.7: approval is recorded against the version, an issued quote carries its order form, and every version names its successor.';
  end if;
  select count(*) into v_quotes from erp.commercial_quote;
  return format('commercial quotes: %s version(s), approval recorded against each', v_quotes);
end;
$$;

-- ── The doors ────────────────────────────────────────────────────────────────

create or replace function public.erp_configure_commercial(p_discount_threshold_pct numeric default 10, p_approver_role text default 'administrator')
returns uuid language sql set search_path = '' as $$ select erp.configure_commercial(p_discount_threshold_pct, p_approver_role); $$;

create or replace function public.erp_open_commercial_quote(
  p_party_code text, p_party_name text, p_price_book_code text, p_term_kind text default 'annual',
  p_term_months integer default 12, p_currency text default 'GBP', p_valid_days integer default 30,
  p_customer_tenant_code text default null, p_notes text default null)
returns uuid language sql set search_path = '' as $$
  select erp.open_commercial_quote(p_party_code, p_party_name, p_price_book_code, p_term_kind, p_term_months,
                                   p_currency::char(3), p_valid_days, p_customer_tenant_code, p_notes);
$$;

create or replace function public.erp_add_quote_line(p_document_id uuid, p_item_code text, p_quantity numeric default 1, p_discount_pct numeric default 0)
returns uuid language sql set search_path = '' as $$ select erp.add_quote_line(p_document_id, p_item_code, p_quantity, p_discount_pct); $$;

create or replace function public.erp_set_quote_line_discount(p_line_id uuid, p_discount_pct numeric)
returns void language sql set search_path = '' as $$ select erp.set_quote_line_discount(p_line_id, p_discount_pct); $$;

create or replace function public.erp_remove_quote_line(p_line_id uuid)
returns void language sql set search_path = '' as $$ select erp.remove_quote_line(p_line_id); $$;

create or replace function public.erp_submit_quote(p_document_id uuid)
returns text language sql set search_path = '' as $$ select erp.submit_quote(p_document_id); $$;

create or replace function public.erp_approve_quote(p_document_id uuid)
returns text language sql set search_path = '' as $$ select erp.approve_quote(p_document_id); $$;

create or replace function public.erp_issue_quote(p_document_id uuid)
returns jsonb language sql set search_path = '' as $$ select erp.issue_quote(p_document_id); $$;

create or replace function public.erp_revise_quote(p_document_id uuid, p_reason text default null)
returns uuid language sql set search_path = '' as $$ select erp.revise_quote(p_document_id, p_reason); $$;

create or replace function public.erp_quote_transition(p_document_id uuid, p_transition_code text, p_reason text default null)
returns text language sql set search_path = '' as $$ select erp.quote_transition(p_document_id, p_transition_code, p_reason); $$;

create or replace function public.erp_quote_margin(p_document_id uuid)
returns jsonb language sql stable set search_path = '' as $$ select erp.quote_margin(p_document_id); $$;

create or replace function public.erp_commercial_quotes()
returns jsonb language sql stable set search_path = '' as $$ select erp.commercial_quotes_report(); $$;

create or replace function public.erp_commercial_quote(p_document_id uuid)
returns jsonb language sql stable set search_path = '' as $$ select erp.commercial_quote_detail(p_document_id); $$;

revoke all on function
  public.erp_configure_commercial(numeric, text),
  public.erp_open_commercial_quote(text, text, text, text, integer, text, integer, text, text),
  public.erp_add_quote_line(uuid, text, numeric, numeric),
  public.erp_set_quote_line_discount(uuid, numeric),
  public.erp_remove_quote_line(uuid),
  public.erp_submit_quote(uuid),
  public.erp_approve_quote(uuid),
  public.erp_issue_quote(uuid),
  public.erp_revise_quote(uuid, text),
  public.erp_quote_transition(uuid, text, text),
  public.erp_quote_margin(uuid),
  public.erp_commercial_quotes(),
  public.erp_commercial_quote(uuid)
  from public, anon;

grant execute on function
  public.erp_configure_commercial(numeric, text),
  public.erp_open_commercial_quote(text, text, text, text, integer, text, integer, text, text),
  public.erp_add_quote_line(uuid, text, numeric, numeric),
  public.erp_set_quote_line_discount(uuid, numeric),
  public.erp_remove_quote_line(uuid),
  public.erp_submit_quote(uuid),
  public.erp_approve_quote(uuid),
  public.erp_issue_quote(uuid),
  public.erp_revise_quote(uuid, text),
  public.erp_quote_transition(uuid, text, text),
  public.erp_quote_margin(uuid),
  public.erp_commercial_quotes(),
  public.erp_commercial_quote(uuid)
  to authenticated, service_role;

-- ── Registration ─────────────────────────────────────────────────────────────

insert into erp_meta.table_policy (schema_name, table_name, table_class, note) values
  ('erp','commercial_quote','tenant_scoped',
   'Part 17 §17.7. What a quotation of the platform organisation carries beyond the document spine: price book version, term, validity, version and supersession, the order form render.')
on conflict (schema_name, table_name) do nothing;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_configure_commercial', 'erp.configure_commercial',
   'Installs the commercial module through a change set. Refused outside the platform organisation; administration.configure inside erp.install_module_config.'),
  ('erp_open_commercial_quote', 'erp.open_commercial_quote',
   'Raises a quote as a quotation document. Refused outside the platform organisation; sales.order inside it, and the document type''s own create permission.'),
  ('erp_add_quote_line', 'erp.add_quote_line',
   'One price item onto a draft quote at the rate card price, with the plan, prerequisite and band checks. sales.order in the platform organisation.'),
  ('erp_set_quote_line_discount', 'erp.set_quote_line_discount', 'A discount on a draft line; the approval chain decides whether it needs anybody. sales.order.'),
  ('erp_remove_quote_line', 'erp.remove_quote_line', 'Cancels a draft line. sales.order.'),
  ('erp_submit_quote', 'erp.submit_quote',
   'Submits a draft: the transition requests approval through the chain; within threshold it approves itself. sales.order through the transition.'),
  ('erp_approve_quote', 'erp.approve_quote',
   'Moves an approved quote on; refuses while the discount approval is pending or rejected. sales.order through the transition.'),
  ('erp_issue_quote', 'erp.issue_quote',
   'Issues an approved quote and renders its order form through the output subsystem. sales.order through the transition and the template''s required permission.'),
  ('erp_revise_quote', 'erp.revise_quote', 'Opens the next version and supersedes this one. sales.order.'),
  ('erp_quote_transition', 'erp.quote_transition', 'Accept, decline, expire or return to draft, through the document''s own state machine. sales.order.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp', 'add_quote_line',
   'Reads erp_meta.plan_capability and erp_meta.plan_entitlement to validate a feature or band against the plan on the quote. Writes only the caller''s own organisation''s document lines, and refuses any organisation that is not the platform''s.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('commercial_quotes', 'Commercial quotes sound', 'assertion', 'platform',
   'erp', 'assert_commercial_quotes_sound', '', 'commercial_quote_report', '',
   'Part 17''s quotes: no quote moves past approval without its discount approved, every issued quote carries its order form, and every superseded version names its successor.',
   true, 71)
on conflict (code) do update set
  title = excluded.title, blurb = excluded.blurb, function_name = excluded.function_name,
  detail_function = excluded.detail_function, seq = excluded.seq;

insert into erp_ref.product_decision_check (decision_code, schema_name, routine_name, note) values
  ('D36', 'erp', 'assert_commercial_quotes_sound',
   'D36 says margin is visible while quoting; erp.quote_margin() is the one reader and the quote screen shows it per line and in total.'),
  ('D37', 'erp', 'assert_commercial_quotes_sound',
   'D37 says quotes are documents with state machines and discounting uses the approval engine; the assertion reads the document state and the approval request, not a table of its own.')
on conflict (decision_code, schema_name, routine_name) do update set note = excluded.note;

insert into erp_meta.policy_decision (code, title, spec_reference, decision, rationale, status, evidence) values
  ('quote_approval_is_a_wrapper_over_the_engine',
   'A quote moves past approval only when the approval engine says so',
   'v1.5 §17.7',
   'The document state machine declares the approve transition with a permission, as every machine does. erp.approve_quote() reads erp.approval_state() and refuses the transition until the request is approved; erp.submit_quote() takes the quote straight through when no step applied. The assertion fails any quote found past approval without an approved request.',
   'The state machine engine is deliberately unaware of the approval engine: a guard is JsonLogic over the transition context, and the context is built per document type. Teaching every machine about approvals would couple two engines that are separate on purpose. A wrapper per document family that reads the request is the smaller change, and the assertion is what makes it a rule rather than a convention.',
   'accepted',
   'erp.approve_quote(); erp.submit_quote(); erp.assert_commercial_quotes_sound(); the same shape as sales order terms in erp.configure_sales().')
on conflict (code) do update set
  title = excluded.title, decision = excluded.decision, rationale = excluded.rationale,
  status = excluded.status, evidence = excluded.evidence;

-- ── Resources, help ──────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description) values
('output.template.order_form', 'en', 'Order form',
 'The order form rendered from a commercial quote: the quote version, the lines, the totals and the terms, issued for signature.'),
('job_handler.expire_commercial_quotes.name', 'en', 'Expire commercial quotes', 'The scheduled job that expires issued quotes past their validity date.'),
('nav.commercial_quotes', 'en', 'Quotes',
 'Navigation label for the platform organisation''s quotes: assembled from price items, margin live, discount approval routed, versioned and expiring, converted to an order form.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(t.text), 'en', t.text,
       'Screen wording, keyed by its own source text so a tenant can rename it.'
  from (values
    ('Quotes'),
    ('A quote is assembled from price items, not typed. Margin shows live per line and in total against the cost model; a discount beyond the threshold is routed for approval; every version is retained; the order form is the quote rendered, not re-keyed.'),
    ('The commercial module is not installed. Installing it is a configuration change: the quote lifecycle, the discount approval chain with its threshold, the order form template and the expiry job.'),
    ('Install the commercial module'),
    ('Discount threshold'),
    ('Open a quote'),
    ('No quote has been raised.'),
    ('Business partner code'),
    ('Business partner name'),
    ('Customer organisation code'),
    ('Term months'),
    ('Valid for days'),
    ('Add a line'),
    ('Discount'),
    ('Remove'),
    ('List'),
    ('Quoted'),
    ('Below cost'),
    ('No cost is recorded for this line, so its margin is invisible; set the cost on the price book.'),
    ('Submit'),
    ('Approve'),
    ('Issue'),
    ('Revise'),
    ('Accept'),
    ('Decline'),
    ('Order form'),
    ('Approval'),
    ('Within the threshold, nobody is needed.'),
    ('Beyond the threshold: routed for approval.'),
    ('Version'),
    ('Supersedes'),
    ('Superseded by'),
    ('Valid until'),
    ('Totals'),
    ('Back to quotes'),
    ('Threshold')
  ) t(text)
on conflict (key, locale) do nothing;

insert into erp_ref.help_topic (screen_path, nav_key, module_code, summary, steps, next_action, actions) values
  ('/commercial/quotes', 'nav.commercial_quotes', 'commercial',
   'The platform''s quotes, on its own primitives: a quotation document with its own lifecycle, lines assembled from price items at the rate card price, margin live per line and in total, a discount beyond the threshold routed through the approval engine, every version retained in a supersession chain, and the order form rendered through the output subsystem.',
   '["Install the commercial module once; it is a change set like every module.","Open a quote for a business partner against a price book, a term and a currency.","Add the plan first, then features, bands and services; prerequisites are named, a band the plan already includes is refused.","Watch the margin as you discount. Submit: within the threshold it approves itself, beyond it a task opens for the approver.","Issue the approved quote to render its order form. Revise to open the next version."]',
   'Install the commercial module, then open a quote.',
   '{erp_configure_commercial,erp_open_commercial_quote,erp_add_quote_line,erp_submit_quote,erp_issue_quote,erp_revise_quote}')
on conflict (screen_path) do update set
  nav_key = excluded.nav_key, module_code = excluded.module_code, summary = excluded.summary,
  steps = excluded.steps, next_action = excluded.next_action, actions = excluded.actions;

-- ── The suite ─────────────────────────────────────────────────────────────────

create or replace function erp_test.commercial_quote_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  r record;
  ad uuid := gen_random_uuid(); ow uuid := gen_random_uuid(); ap uuid := gen_random_uuid();
  v_tenant uuid; v_code text := 'zzcq-' || substr(md5(random()::text), 1, 6);
  v_second uuid; v_tok text; res jsonb; v_ok boolean; v_msg text;
  v_q uuid; v_q2 uuid; v_line uuid; v_state text; t record; v_n integer;
begin
  select * into r from erp.provision_tenant(v_code, 'Clove Platform Quotes', 'admin@zzcq.test', 'Platform Admin');
  v_tenant := r.tenant_id;
  insert into auth.users (id, email) values (ad, 'admin@zzcq.test'), (ow, 'owner@zzcq.test'), (ap, 'approver@zzcq.test');
  insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
  values ('owner@zzcq.test', ow, 'Platform Owner', 'owner');
  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  perform erp.claim_invitation(r.admin_token);
  perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
  perform erp.designate_platform_organisation(v_code);
  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);

  -- A second administrator, so an approval has somebody other than the author.
  res := public.erp_invite_principal('approver@zzcq.test', 'Quote Approver');
  v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
  perform erp.grant_role(v_second, 'administrator', null, null, 'suite');
  perform set_config('request.jwt.claims', json_build_object('sub', ap)::text, true);
  perform erp.claim_invitation(v_tok);
  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);

  -- ── The module, the book ─────────────────────────────────────────────────

  begin
    perform erp.open_commercial_quote('ACME', 'Acme Foods', 'PB-2026');
    v_ok := false; v_msg := 'a quote was raised with no module installed';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_COMMERCIAL_NOT_INSTALLED%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a quote needs the commercial module installed first', v_ok, v_msg;

  perform erp_test.reopen_bootstrap_window(v_tenant);
  perform erp.configure_commercial(10, 'administrator');
  perform erp.open_price_book('PB-2026', 'List 2026', array['GBP'], current_date - 1, null);
  perform erp_test.close_bootstrap_window(v_tenant);
  return query select 'installing the commercial module is a change set carrying the lifecycle, the chain, the template and the job',
    exists (select 1 from erp.state_machine m where m.tenant_id = v_tenant and m.code = 'commercial_quote' and m.status = 'active')
    and exists (select 1 from erp.approval_chain c where c.tenant_id = v_tenant and c.code = 'commercial_quote_terms')
    and exists (select 1 from erp.output_template o where o.tenant_id = v_tenant and o.code = 'order_form')
    and exists (select 1 from erp.job j where j.tenant_id = v_tenant and j.handler_code = 'commercial.expire_quotes')
    and exists (select 1 from erp.document_type dt where dt.tenant_id = v_tenant and dt.code = 'commercial_quote'),
    format('threshold %s%%', erp.quote_discount_threshold());

  perform erp.upsert_price_item('PLAN-START', 'Starter plan', 'plan_tier', 'starter');
  perform erp.upsert_price_item('PLAN-STD', 'Standard plan', 'plan_tier', 'standard');
  perform erp.upsert_price_item('CAP-BATCH', 'Batch control', 'capability_addon', null, 'batch_control');
  perform erp.upsert_price_item('CAP-EXPIRY', 'Expiry control', 'capability_addon', null, 'expiry_control');
  perform erp.upsert_price_item('USERS-100', 'Up to 100 users', 'user_band', null, null, 'users', 11, 100);
  perform erp.upsert_price_item('USERS-5', 'Up to 5 users', 'user_band', null, null, 'users', 1, 5);
  perform erp.upsert_price_item('SVC-IMPL', 'Implementation', 'service');
  perform erp.upsert_price_item('LEG-VAT', 'Example VAT pack', 'legislation_pack', null, null, null, null, null, 'example_vat');
  perform erp.set_rate('PB-2026', 'PLAN-START', 'GBP', 300000);
  perform erp.set_rate('PB-2026', 'PLAN-STD', 'GBP', 1200000);
  perform erp.set_rate('PB-2026', 'CAP-BATCH', 'GBP', 100000);
  perform erp.set_rate('PB-2026', 'CAP-EXPIRY', 'GBP', 80000);
  perform erp.set_rate('PB-2026', 'USERS-100', 'GBP', 300000);
  perform erp.set_rate('PB-2026', 'USERS-5', 'GBP', 50000);
  perform erp.set_rate('PB-2026', 'SVC-IMPL', 'GBP', 800000);
  perform erp.set_rate('PB-2026', 'LEG-VAT', 'GBP', 0);
  perform erp.set_cost_model('PLAN-START', 'GBP', 100000, 50000, 0);
  perform erp.set_cost_model('PLAN-STD', 'GBP', 300000, 100000, 50000);
  perform erp.set_cost_model('CAP-BATCH', 'GBP', 10000, 10000, 0);
  perform erp.set_cost_model('CAP-EXPIRY', 'GBP', 10000, 5000, 0);
  perform erp.set_cost_model('USERS-100', 'GBP', 50000, 25000, 0);
  perform erp.set_cost_model('USERS-5', 'GBP', 5000, 2500, 0);
  perform erp.set_cost_model('SVC-IMPL', 'GBP', 0, 600000, 0);

  -- ── §17.7 assembling a quote ─────────────────────────────────────────────

  v_q := erp.open_commercial_quote('ACME', 'Acme Foods', 'PB-2026', 'annual', 12, 'GBP', 30, null, 'first conversation');
  return query select 'a quote is a quotation document of the platform organisation, naming the price book version',
    v_q is not null
    and (select cq.price_book_version from erp.commercial_quote cq where cq.document_id = v_q) = 1
    and erp.object_current_state('document', v_q) = 'draft'
    and exists (select 1 from erp.party p where p.tenant_id = v_tenant and p.code = 'ACME'),
    (select d.document_number from erp.document d where d.id = v_q);

  begin
    perform erp.add_quote_line(v_q, 'CAP-EXPIRY');
    v_ok := false; v_msg := 'a feature was added without its prerequisite';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_QUOTE_NEEDS_PREREQUISITE%' and sqlerrm like '%batch_control%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'a feature with prerequisites offers them by name and waits', v_ok, v_msg;

  v_line := erp.add_quote_line(v_q, 'PLAN-START');
  begin
    perform erp.add_quote_line(v_q, 'PLAN-STD');
    v_ok := false; v_msg := 'a second plan was added';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_QUOTE_HAS_A_PLAN%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a quote names one plan', v_ok, v_msg;

  perform erp.add_quote_line(v_q, 'CAP-BATCH');
  perform erp.add_quote_line(v_q, 'CAP-EXPIRY');
  return query select 'with the prerequisite on the quote, the feature is accepted',
    (select count(*) from erp.document_line l where l.document_id = v_q and not l.is_cancelled) = 3, 'plan, batch control, expiry control';

  begin
    perform erp.add_quote_line(v_q, 'USERS-5');
    v_ok := false; v_msg := 'a band inside the plan was sold';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_BAND_WITHIN_PLAN%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'a band the plan already includes sells nothing and is refused', v_ok, v_msg;
  perform erp.add_quote_line(v_q, 'USERS-100');
  begin
    perform erp.add_quote_line(v_q, 'USERS-100');
    v_ok := false; v_msg := 'two bands for one entitlement';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_QUOTE_HAS_A_BAND%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'bands validate against each other: one per entitlement', v_ok, v_msg;

  perform erp.add_quote_line(v_q, 'LEG-VAT', 1, 50);
  return query select 'a legislation pack sits on the quote at nil whatever discount is typed',
    (select l.unit_price_minor = 0 and l.discount_pct = 0 from erp.document_line l
      join erp.item i on i.id = l.item_id where l.document_id = v_q and i.code = 'LEG-VAT'), 'nil, and no discount to give';

  perform erp.add_quote_line(v_q, 'SVC-IMPL', 1, 5);
  res := erp.quote_margin(v_q);
  return query select 'margin shows live per line and in total against the cost model',
    (res -> 'totals' ->> 'quoted_minor')::bigint = 300000 + 100000 + 80000 + 300000 + 0 + 760000
    and (res -> 'totals' ->> 'cost_minor')::bigint = 150000 + 20000 + 15000 + 75000 + 600000
    and (select (x ->> 'margin_pct')::numeric from jsonb_array_elements(res -> 'lines') x where x ->> 'item_code' = 'PLAN-START') = 50.0
    and (res -> 'totals' ->> 'max_discount_pct')::numeric = 5,
    format('quoted %s, cost %s, margin %s%%', res -> 'totals' ->> 'quoted_minor', res -> 'totals' ->> 'cost_minor', res -> 'totals' ->> 'margin_pct');

  select l.id into v_line from erp.document_line l join erp.item i on i.id = l.item_id where l.document_id = v_q and i.code = 'SVC-IMPL';
  perform erp.set_quote_line_discount(v_line, 30);
  res := erp.quote_margin(v_q);
  return query select 'a discount that takes a line below cost is visible before it is offered',
    (select (x ->> 'below_cost')::boolean from jsonb_array_elements(res -> 'lines') x where x ->> 'item_code' = 'SVC-IMPL')
    and (res -> 'totals' ->> 'below_cost_lines')::integer = 1,
    'implementation at 30% off is 5,600 against a cost of 6,000';
  perform erp.set_quote_line_discount(v_line, 5);

  -- ── §17.7 discount within the threshold needs nobody ─────────────────────

  v_state := erp.submit_quote(v_q);
  return query select 'a discount within the threshold approves itself on submission',
    v_state = 'approved'
    and (select a.status from erp.approval_state('document', v_q) a limit 1) = 'approved',
    'no step applied; the request approved itself and the quote moved on';

  res := erp.issue_quote(v_q);
  return query select 'issuing renders the order form through the output subsystem, with its checksum',
    erp.object_current_state('document', v_q) = 'issued'
    and (res ->> 'render_id') is not null
    and exists (select 1 from erp.output_render o where o.id = (res ->> 'render_id')::uuid
                 and o.checksum = res ->> 'checksum' and o.content is not null
                 and (o.content::jsonb ->> 'quote_version')::integer = 1)
    and exists (select 1 from erp.output_request q where q.tenant_id = v_tenant and q.object_id = v_q and q.triggering_event = 'commercial.quote_issued'),
    res ->> 'checksum';

  begin
    perform erp.add_quote_line(v_q, 'SVC-IMPL');
    v_ok := false; v_msg := 'an issued quote was edited';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_QUOTE_NOT_IN_DRAFT%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'an issued quote is not edited; it is revised', v_ok, v_msg;

  -- ── §17.7 versions ───────────────────────────────────────────────────────

  v_q2 := erp.revise_quote(v_q, 'customer asked for a bigger discount');
  return query select 'revising opens the next version carrying the lines, and supersedes this one',
    erp.object_current_state('document', v_q) = 'superseded'
    and erp.object_current_state('document', v_q2) = 'draft'
    and (select cq.version from erp.commercial_quote cq where cq.document_id = v_q2) = 2
    and (select cq.supersedes_document_id from erp.commercial_quote cq where cq.document_id = v_q2) = v_q
    and (select cq.superseded_by_document_id from erp.commercial_quote cq where cq.document_id = v_q) = v_q2
    and (select count(*) from erp.document_line l where l.document_id = v_q2 and not l.is_cancelled) = 6,
    'version 1 superseded by version 2, six lines carried';

  -- ── §17.7 beyond the threshold needs the approver ────────────────────────

  select l.id into v_line from erp.document_line l join erp.item i on i.id = l.item_id where l.document_id = v_q2 and i.code = 'PLAN-START';
  perform erp.set_quote_line_discount(v_line, 25);
  v_state := erp.submit_quote(v_q2);
  select count(*) into v_n from erp.approval_task tk
    join erp.approval_request q on q.id = tk.approval_request_id
   where q.object_id = v_q2 and tk.step_code = 'discount' and tk.status = 'pending';
  return query select 'a discount beyond the threshold opens the discount step for the approver',
    v_state = 'pending_approval' and v_n >= 1, format('%s pending task(s) on version 2', v_n);

  begin
    perform erp.approve_quote(v_q2);
    v_ok := false; v_msg := 'the quote moved on before the approver decided';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_QUOTE_NOT_APPROVED%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'and the quote cannot move on until it is decided', v_ok, v_msg;

  perform set_config('request.jwt.claims', json_build_object('sub', ap)::text, true);
  for t in select tk.id from erp.approval_task tk join erp.approval_request q on q.id = tk.approval_request_id
            where q.object_id = v_q2 and tk.step_code = 'discount' and tk.status = 'pending' and tk.assignee_user_id = v_second
  loop perform erp.decide_approval_task(t.id, true, 'agreed for the first year'); end loop;
  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  v_state := erp.approve_quote(v_q2);
  return query select 'the approval is recorded against the quote version and the quote moves on',
    v_state = 'approved'
    and (select a.status from erp.approval_state('document', v_q2) a limit 1) = 'approved'
    and (select q.object_version from erp.approval_request q where q.object_id = v_q2 and q.status = 'approved' limit 1) = 1,
    'decided by the second administrator';

  res := erp.issue_quote(v_q2);
  perform erp.quote_transition(v_q2, 'accept', 'signed order form returned');
  return query select 'an issued quote is accepted through its own lifecycle',
    erp.object_current_state('document', v_q2) = 'accepted', 'accepted';

  return query select 'the assertion passes over both versions',
    erp.assert_commercial_quotes_sound() like 'commercial quotes: 2 version(s)%', erp.assert_commercial_quotes_sound();

  -- ── §17.7 expiring ───────────────────────────────────────────────────────

  v_q := erp.open_commercial_quote('ACME', 'Acme Foods', 'PB-2026', 'annual', 12, 'GBP', 1);
  perform erp.add_quote_line(v_q, 'PLAN-START');
  perform erp.submit_quote(v_q);
  perform erp.issue_quote(v_q);
  update erp.commercial_quote set valid_until = current_date - 1 where document_id = v_q;
  select count(*) into v_n from erp.expire_commercial_quotes();
  return query select 'an issued quote past its validity is expired by the sweep',
    v_n = 1 and erp.object_current_state('document', v_q) = 'expired', 'expired';

  -- ── Clean up ──────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  delete from erp_meta.platform_organisation where tenant_id = v_tenant;
  perform erp.begin_tenant_purge(v_tenant);
  delete from erp.tenant where id = v_tenant;
  perform erp.end_tenant_purge();
  delete from erp_meta.platform_staff where email like '%@zzcq.test';
  delete from auth.users where id in (ad, ow, ap);
  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant tn where tn.id = v_tenant)
    and not exists (select 1 from erp.commercial_quote cq where cq.tenant_id = v_tenant), 'organisation and quotes gone';
end;
$$;

create or replace function erp_test.assert_commercial_quote_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _commercial_quote_result on commit drop as
    select * from erp_test.commercial_quote_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_total, v_passed, v_detail
    from _commercial_quote_result;
  if v_passed < v_total then
    raise exception E'ERPWARE_COMMERCIAL_QUOTE_SUITE_FAILED: %/%\n%', v_passed, v_total, v_detail
      using errcode = 'P0001';
  end if;
  return format('commercial quotes: %s/%s', v_passed, v_total);
end;
$$;

-- ── The generators, then the assertions ──────────────────────────────────────

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_configuration_promotable();
select erp.assert_no_dead_configuration();
select erp.assert_diagnostics_registered();
select erp.assert_job_handlers_resolvable();
select erp.assert_commercial_sound();
select erp.assert_commercial_quotes_sound();
select erp.assert_product_decisions_enforced();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
select erp.assert_guidance_sound();
