-- =============================================================================
-- Part 17 §17.10 and §17.11: renewal and revenue, and what the customer sees
--
-- §17.10 "Renewals are generated, not remembered: at the notice lead time, a
-- renewal quote is produced from the current contract with the uplift rule
-- applied, ready to send." A sweep proposes the renewal (erp_meta.renewal)
-- with the uplift computed from the rule — fixed, index-linked, or capped —
-- and the platform organisation raises the quote from the proposal with one
-- call, the original lines uplifted, through the same builder as any quote.
-- Accepting it renews the contract as a signed, provisioned amendment.
--
-- "Invoice schedules generate from the contract term and billing frequency,
-- reconciled against the metering in §17.2 so a usage overage appears on the
-- invoice and in the customer's own usage view identically." The schedule is
-- rows of erp_meta.contract_invoice; issuing one reconciles the period's meters
-- against the entitlement in force and prices the overage from the price book.
--
-- "Reporting the platform owner needs, derived from contracts rather than
-- assembled by hand" — erp.revenue_report().
--
-- §17.11, D38: "an organisation should never have to ask its supplier what it
-- is entitled to, what it is using, or what it will pay next." erp_my_agreement()
-- is one door that returns the organisation's own contract and its documents,
-- its entitlement in the contract's terms, its live usage, its invoices with
-- the metering behind them, its renewal date, notice deadline and uplift rule,
-- and the sub-processor list with every change to it.
-- =============================================================================

-- ── §17.10 renewals ──────────────────────────────────────────────────────────

create table if not exists erp_meta.index_rate (
  index_code    text not null,
  period        date not null,
  rate_pct      numeric not null,
  source        text,
  registered_at timestamptz not null default now(),
  primary key (index_code, period)
);

comment on table erp_meta.index_rate is
  'Specification v1.5 §17.8: the published rate an index-linked uplift refers '
  'to, per period. A renewal price is calculated from the rate in force at the '
  'proposal, never negotiated from memory.';

create table if not exists erp_meta.renewal (
  id                             uuid primary key default gen_random_uuid(),
  contract_id                    uuid not null references erp_meta.contract (id) on delete cascade,
  proposed_at                    timestamptz not null default now(),
  term_start                     date not null,
  term_end                       date not null,
  uplift_rule                    jsonb not null,
  uplift_pct                     numeric not null,
  previous_annual_value_minor    bigint not null,
  proposed_annual_value_minor    bigint not null,
  currency                       char(3) not null,
  notice_deadline                date,
  status                         text not null default 'proposed',
  quote_document_id              uuid,
  decided_at                     timestamptz,
  decision_note                  text,
  constraint renewal_status_known check (status in ('proposed', 'quoted', 'accepted', 'declined', 'lapsed')),
  constraint renewal_once_per_term unique (contract_id, term_start)
);

comment on table erp_meta.renewal is
  'Specification v1.5 §17.10: a renewal generated at the notice lead time from '
  'the contract with its uplift rule applied. Quoted by the platform '
  'organisation from this row; accepted as a signed amendment.';

create table if not exists erp_meta.contract_invoice (
  id                  uuid primary key default gen_random_uuid(),
  contract_id         uuid not null references erp_meta.contract (id) on delete cascade,
  tenant_id           uuid not null,
  tenant_code         text not null,
  seq                 integer not null,
  reference           text not null,
  period_start        date not null,
  period_end          date not null,
  due_on              date not null,
  currency            char(3) not null,
  subscription_minor  bigint not null,
  overage_minor       bigint not null default 0,
  total_minor         bigint not null,
  lines               jsonb not null default '[]'::jsonb,
  status              text not null default 'scheduled',
  issued_at           timestamptz,
  paid_at             timestamptz,
  payment_reference   text,
  created_at          timestamptz not null default now(),
  constraint contract_invoice_status_known check (status in ('scheduled', 'issued', 'paid', 'void')),
  constraint contract_invoice_period_ordered check (period_end > period_start),
  constraint contract_invoice_once unique (contract_id, period_start),
  constraint contract_invoice_reference_unique unique (reference)
);

comment on table erp_meta.contract_invoice is
  'Specification v1.5 §17.10: the invoice schedule from the contract term and '
  'billing frequency, each reconciled against the metering when it is issued '
  'so an overage appears here and in the customer''s own usage view '
  'identically. No foreign key to erp.tenant: the billing record outlives a '
  'purge by design (§17.2).';

insert into erp_ref.event_type
  (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current) values
('commercial.contract_renewed', 1, 'tenant', 'administration', 'event.commercial.contract_renewed',
 'The organisation''s contract was renewed for a further term. §17.10.',
 '{"type":"object","required":["contract_id"],"properties":{"contract_id":{"type":"string"},"term_start":{"type":"string"},"term_end":{"type":"string"},"annual_value_minor":{"type":"number"}}}'::jsonb, true),
('commercial.non_renewal_recorded', 1, 'tenant', 'administration', 'event.commercial.non_renewal_recorded',
 'The organisation''s contract will not renew; the notice period is honoured and export offered before any restriction. §17.10, §17.3.',
 '{"type":"object","required":["contract_id"],"properties":{"contract_id":{"type":"string"},"term_end":{"type":"string"},"note":{"type":"string"}}}'::jsonb, true),
('commercial.term_ended', 1, 'tenant', 'administration', 'event.commercial.term_ended',
 'The contract''s term ended without renewal; the organisation is in grace, with service continuing and export available. §17.3.',
 '{"type":"object","required":["contract_id"],"properties":{"contract_id":{"type":"string"},"term_end":{"type":"string"}}}'::jsonb, true),
('commercial.invoice_issued', 1, 'tenant', 'administration', 'event.commercial.invoice_issued',
 'An invoice was issued to the organisation, reconciled against its metering. §17.10.',
 '{"type":"object","required":["invoice_id","reference"],"properties":{"invoice_id":{"type":"string"},"reference":{"type":"string"},"total_minor":{"type":"number"},"overage_minor":{"type":"number"}}}'::jsonb, true)
on conflict (code, version) do update set
  description = excluded.description, payload_schema = excluded.payload_schema, is_current = excluded.is_current;

create or replace function erp.uplift_pct_for(p_rule jsonb, p_on date default current_date)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  -- The rule as recorded on the contract: a fixed percentage, an index
  -- reference, or a capped combination. Null where an index rule has no
  -- published rate, which the sweep reports rather than guesses.
  select case p_rule ->> 'kind'
    when 'none' then 0
    when 'fixed_pct' then (p_rule ->> 'pct')::numeric
    when 'index' then (select r.rate_pct from erp_meta.index_rate r
                        where r.index_code = p_rule ->> 'index_code' and r.period <= p_on
                        order by r.period desc limit 1)
    when 'capped' then least((select r.rate_pct from erp_meta.index_rate r
                                where r.index_code = p_rule ->> 'index_code' and r.period <= p_on
                                order by r.period desc limit 1),
                             (p_rule ->> 'cap_pct')::numeric)
    end
$$;

create or replace function erp.propose_renewals()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare c record; v_pct numeric; v_raised integer := 0; v_deadline date;
begin
  if not erp.session_is_trusted() then
    raise exception 'ERPWARE_UNTRUSTED_SWEEP: this runs across every organisation, so it needs a session whose role bypasses row-level security; % does not', current_user
      using errcode = '42501';
  end if;
  for c in
    select * from erp_meta.contract x
     where x.status = 'active' and x.renewal_kind <> 'none'
       and (x.current_term_end - x.notice_days - x.lead_days) <= current_date
       and not exists (select 1 from erp_meta.renewal r where r.contract_id = x.id and r.term_start = x.current_term_end)
     order by x.tenant_code
  loop
    v_pct := erp.uplift_pct_for(c.uplift_rule, current_date);
    continue when v_pct is null;      -- an index with no rate: reported, not guessed
    v_deadline := (c.current_term_end - c.notice_days)::date;
    insert into erp_meta.renewal
      (contract_id, term_start, term_end, uplift_rule, uplift_pct, previous_annual_value_minor,
       proposed_annual_value_minor, currency, notice_deadline)
    values (c.id, c.current_term_end, (c.current_term_end + make_interval(months => c.initial_term_months))::date,
            c.uplift_rule, v_pct, c.annual_value_minor,
            round(c.annual_value_minor * (1 + v_pct / 100.0))::bigint, c.currency, v_deadline);
    v_raised := v_raised + 1;
  end loop;
  return v_raised;
end;
$$;

comment on function erp.propose_renewals is
  'Specification v1.5 §17.10: "renewals are generated, not remembered". At the '
  'notice lead time, proposes the next term from the contract with the uplift '
  'rule applied, once per term. An index-linked rule with no published rate is '
  'a finding, not a guess.';

create or replace function erp.open_renewal_quote(p_renewal_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  r erp_meta.renewal; c erp_meta.contract; d erp.document%rowtype; q erp.commercial_quote;
  v_new uuid; l record; v_line uuid; b record;
begin
  perform erp.require_platform_organisation();
  perform erp.authorise('sales.order', null, null, null, 'commercial_quote', null);
  select * into r from erp_meta.renewal where id = p_renewal_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_RENEWAL: %', p_renewal_id using errcode = '23503';
  end if;
  if r.status <> 'proposed' then
    raise exception 'ERPWARE_RENEWAL_NOT_PROPOSED: the renewal is %', r.status using errcode = '23514';
  end if;
  select * into c from erp_meta.contract where id = r.contract_id;
  if c.platform_tenant_id <> v_tenant then
    raise exception 'ERPWARE_NOT_THE_PLATFORM_ORGANISATION' using errcode = '42501';
  end if;
  select cq.* into q from erp.commercial_quote cq where cq.tenant_id = v_tenant and cq.document_id = c.quote_document_id;
  select * into d from erp.document x where x.id = c.quote_document_id;
  select * into b from erp.price_book_in_force(q.price_book_code);
  if not found then
    raise exception 'ERPWARE_UNKNOWN_PRICE_BOOK: % has no version in force for the renewal', q.price_book_code using errcode = '23503';
  end if;

  -- The current contract's lines, uplifted by the rule, as a new quote through
  -- the same builder: versioned, expiring, approval-routed like any other.
  v_new := erp.open_document('commercial_quote', d.party_id, d.entity_id, null, null, null, q.currency);
  update erp.document set notes = format('Renewal of contract %s from %s, uplift %s%%', c.id, r.term_start, r.uplift_pct),
         our_reference = q.price_book_code || ' v' || b.version, updated_at = now()
   where id = v_new;
  insert into erp.commercial_quote
    (tenant_id, document_id, customer_tenant_code, price_book_code, price_book_version, term_kind, term_months,
     currency, valid_until, notes)
  values (v_tenant, v_new, c.tenant_code, q.price_book_code, b.version, q.term_kind, q.term_months,
          q.currency, case when r.notice_deadline > current_date then least(r.notice_deadline, current_date + 30)
                           else current_date + 30 end,
          format('Renewal from %s; uplift %s%% by rule %s', r.term_start, r.uplift_pct, r.uplift_rule ->> 'kind'));
  for l in
    select x.item_id, x.quantity, x.unit_price_minor, x.description, x.discount_pct
      from erp.document_line x where x.tenant_id = v_tenant and x.document_id = c.quote_document_id and not x.is_cancelled
     order by x.line_no
  loop
    v_line := erp.add_document_line(v_new, l.item_id, l.quantity,
                                    round(l.unit_price_minor * (1 + r.uplift_pct / 100.0))::bigint, l.description);
    update erp.document_line set discount_pct = coalesce(l.discount_pct, 0), updated_at = now() where id = v_line;
  end loop;
  update erp_meta.renewal set status = 'quoted', quote_document_id = v_new where id = p_renewal_id;
  return v_new;
end;
$$;

comment on function erp.open_renewal_quote is
  'Specification v1.5 §17.10: the renewal quote, "produced from the current '
  'contract with the uplift rule applied, ready to send". Raised by the '
  'platform organisation from the proposal, through the same builder as every '
  'quote. Security definer to read the proposal in erp_meta; refused outside '
  'the platform organisation.';

create or replace function erp.renew_contract(p_renewal_id uuid, p_customer_signer text, p_platform_signer text, p_signature_meaning text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff erp_meta.platform_staff; r erp_meta.renewal; c erp_meta.contract; v_state text; v_seq integer;
  v_amend uuid; v_annual bigint; m jsonb; v_sub uuid;
begin
  v_staff := erp_meta.require_platform('operator');
  select * into r from erp_meta.renewal where id = p_renewal_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_RENEWAL: %', p_renewal_id using errcode = '23503';
  end if;
  if r.status <> 'quoted' or r.quote_document_id is null then
    raise exception 'ERPWARE_RENEWAL_NOT_QUOTED: the renewal is %', r.status using errcode = '23514';
  end if;
  select * into c from erp_meta.contract where id = r.contract_id;
  select s.code into v_state
    from erp.object_state os join erp.state s on s.id = os.current_state_id
   where os.tenant_id = c.platform_tenant_id and os.object_type = 'document' and os.object_id = r.quote_document_id;
  if v_state <> 'accepted' then
    raise exception 'ERPWARE_QUOTE_NOT_ACCEPTED: the renewal quote is %', v_state using errcode = '23514';
  end if;
  if coalesce(btrim(p_customer_signer), '') = '' or coalesce(btrim(p_platform_signer), '') = '' or coalesce(btrim(p_signature_meaning), '') = '' then
    raise exception 'ERPWARE_SIGNATURE_INCOMPLETE: a signature names both signers and what signing means (§9.3)' using errcode = '23514';
  end if;

  perform set_config('erp.job_tenant_id', c.platform_tenant_id::text, true);
  m := erp.quote_margin(r.quote_document_id);
  perform set_config('erp.job_tenant_id', '', true);
  v_annual := (m -> 'totals' ->> 'quoted_minor')::bigint * case c.term_kind when 'monthly' then 12 else 1 end;

  -- A renewal is an amendment: signed, held as an addendum, provisioned from
  -- its effective date — the day the new term starts.
  select coalesce(max(a.seq), 0) + 1 into v_seq from erp_meta.contract_amendment a where a.contract_id = c.id;
  insert into erp_meta.contract_amendment
    (contract_id, seq, title, effective_from, changes, rationale, signed_at, signed_by_customer, signed_by_platform,
     signature_meaning, provisioned_at, created_by)
  values (c.id, v_seq, format('Renewal from %s', r.term_start), r.term_start,
          jsonb_build_object('term_start', r.term_start, 'term_end', r.term_end, 'annual_value_minor', v_annual,
                             'uplift_pct', r.uplift_pct, 'renewal_quote', r.quote_document_id),
          format('uplift %s%% by rule %s', r.uplift_pct, r.uplift_rule ->> 'kind'),
          now(), btrim(p_customer_signer), btrim(p_platform_signer), btrim(p_signature_meaning), now(), v_staff.email)
  returning id into v_amend;
  insert into erp_meta.contract_document (contract_id, kind, version, title, content, checksum, signed_at, signed_by_customer, signed_by_platform, signature_meaning)
  select c.id, 'amendment', v_seq, format('Renewal from %s', r.term_start), o.content, o.checksum, now(),
         btrim(p_customer_signer), btrim(p_platform_signer), btrim(p_signature_meaning)
    from erp.commercial_quote cq join erp.output_render o on o.tenant_id = cq.tenant_id and o.id = cq.order_form_render_id
   where cq.tenant_id = c.platform_tenant_id and cq.document_id = r.quote_document_id;

  update erp_meta.contract
     set current_term_start = r.term_start, current_term_end = r.term_end, annual_value_minor = v_annual,
         status = 'active', updated_at = now()
   where id = c.id;
  update erp_meta.renewal set status = 'accepted', decided_at = now() where id = p_renewal_id;
  v_sub := erp.provision_entitlement_from_contract(c.id);
  perform erp.generate_invoice_schedule(c.id);

  perform set_config('erp.job_tenant_id', c.tenant_id::text, true);
  perform erp.append_event('commercial.contract_renewed', 'tenant', c.tenant_id,
    jsonb_build_object('contract_id', c.id, 'term_start', r.term_start, 'term_end', r.term_end, 'annual_value_minor', v_annual));
  perform set_config('erp.job_tenant_id', '', true);
  perform erp_meta.platform_log(v_staff, 'platform.contract_renewed', c.tenant_id, c.id::text,
                                format('renewed to %s at %s', r.term_end, v_annual), jsonb_build_object('renewal_id', r.id));
  return v_amend;
end;
$$;

create or replace function erp.decline_renewal(p_renewal_id uuid, p_note text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_staff erp_meta.platform_staff; r erp_meta.renewal; c erp_meta.contract;
begin
  v_staff := erp_meta.require_platform('operator');
  select * into r from erp_meta.renewal where id = p_renewal_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_RENEWAL: %', p_renewal_id using errcode = '23503';
  end if;
  if coalesce(btrim(p_note), '') = '' then
    raise exception 'ERPWARE_NON_RENEWAL_HAS_NO_NOTE: a non-renewal says why' using errcode = '23514';
  end if;
  select * into c from erp_meta.contract where id = r.contract_id;
  update erp_meta.renewal set status = 'declined', decided_at = now(), decision_note = btrim(p_note) where id = p_renewal_id;
  -- §17.10: "non-renewal follows the lifecycle in §17.3 with the notice period
  -- honoured and export offered before any restriction". The contract runs to
  -- its term end as terminating; the subscription stops renewing; the
  -- organisation is told now, with its term end.
  update erp_meta.contract set status = 'terminating', renewal_kind = 'none', updated_at = now() where id = c.id;
  update erp_meta.subscription set renews = false, updated_at = now() where tenant_id = c.tenant_id and status <> 'terminated';
  perform set_config('erp.job_tenant_id', c.tenant_id::text, true);
  perform erp.append_event('commercial.non_renewal_recorded', 'tenant', c.tenant_id,
    jsonb_build_object('contract_id', c.id, 'term_end', c.current_term_end, 'note', btrim(p_note)));
  perform set_config('erp.job_tenant_id', '', true);
  perform erp_meta.platform_log(v_staff, 'platform.non_renewal_recorded', c.tenant_id, c.id::text, btrim(p_note), '{}'::jsonb);
end;
$$;

create or replace function erp.expire_contracts()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare c record; v_n integer := 0;
begin
  if not erp.session_is_trusted() then
    raise exception 'ERPWARE_UNTRUSTED_SWEEP: this runs across every organisation, so it needs a session whose role bypasses row-level security; % does not', current_user
      using errcode = '42501';
  end if;
  for c in select * from erp_meta.contract x where x.status in ('active', 'terminating') and x.current_term_end < current_date loop
    update erp_meta.contract set status = 'expired', updated_at = now() where id = c.id;
    update erp_meta.renewal set status = 'lapsed', decided_at = now() where contract_id = c.id and status in ('proposed', 'quoted');
    -- §17.3: grace — service continues, administrators notified, no functional
    -- change. Restriction is a platform operator's act after the notice, never
    -- a sweep's.
    update erp_meta.subscription set status = 'grace', renews = false, updated_at = now()
     where tenant_id = c.tenant_id and status = 'active';
    perform set_config('erp.job_tenant_id', c.tenant_id::text, true);
    perform erp.append_event('commercial.term_ended', 'tenant', c.tenant_id,
      jsonb_build_object('contract_id', c.id, 'term_end', c.current_term_end));
    v_n := v_n + 1;
  end loop;
  perform set_config('erp.job_tenant_id', '', true);
  return v_n;
end;
$$;

-- ── §17.10 invoices ──────────────────────────────────────────────────────────

create or replace function erp.generate_invoice_schedule(p_contract_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare c erp_meta.contract; v_months integer; v_start date; v_seq integer; v_n integer := 0; v_periods integer; v_end date;
begin
  select * into c from erp_meta.contract where id = p_contract_id;
  if not found or c.status not in ('active', 'terminating') then
    return 0;
  end if;
  v_months := case c.billing_frequency when 'annual' then 12 when 'quarterly' then 3 else 1 end;
  v_start := c.current_term_start;
  select coalesce(max(i.seq), 0) into v_seq from erp_meta.contract_invoice i where i.contract_id = c.id;
  v_periods := 0;
  while v_start < c.current_term_end loop
    v_end := least((v_start + make_interval(months => v_months))::date, c.current_term_end);
    if not exists (select 1 from erp_meta.contract_invoice i where i.contract_id = c.id and i.period_start = v_start) then
      v_seq := v_seq + 1;
      insert into erp_meta.contract_invoice
        (contract_id, tenant_id, tenant_code, seq, reference, period_start, period_end, due_on, currency,
         subscription_minor, total_minor)
      values (c.id, c.tenant_id, c.tenant_code, v_seq,
              format('INV-%s-%s-%s', upper(c.tenant_code), to_char(v_start, 'YYYYMM'), lpad(v_seq::text, 3, '0')),
              v_start, v_end, v_start, c.currency,
              round(c.annual_value_minor * v_months / 12.0)::bigint,
              round(c.annual_value_minor * v_months / 12.0)::bigint);
      v_n := v_n + 1;
    end if;
    v_start := v_end;
    v_periods := v_periods + 1;
    exit when v_periods > 120;
  end loop;
  return v_n;
end;
$$;

comment on function erp.generate_invoice_schedule is
  'Specification v1.5 §17.10: "invoice schedules generate from the contract '
  'term and billing frequency". One row per period, the subscription charge '
  'apportioned; the overage is reconciled when each is issued.';

create or replace function erp.generate_invoice_schedules()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare c record; v_n integer := 0;
begin
  if not erp.session_is_trusted() then
    raise exception 'ERPWARE_UNTRUSTED_SWEEP: this runs across every organisation, so it needs a session whose role bypasses row-level security; % does not', current_user
      using errcode = '42501';
  end if;
  for c in select id from erp_meta.contract where status in ('active', 'terminating') loop
    v_n := v_n + erp.generate_invoice_schedule(c.id);
  end loop;
  return v_n;
end;
$$;

create or replace function erp.invoice_overage_lines(p_invoice_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  i erp_meta.contract_invoice; c erp_meta.contract; k record; mth date; v_used numeric; v_limit numeric;
  v_over numeric; v_unit numeric; v_lines jsonb := '[]'::jsonb; pi record;
begin
  select * into i from erp_meta.contract_invoice where id = p_invoice_id;
  select * into c from erp_meta.contract where id = i.contract_id;
  -- §17.10: "reconciled against the metering in §17.2". For each month of the
  -- period and each metered band, what the organisation used against what
  -- its contract entitles, priced from the volume band on the price book at
  -- the rate per unit of the band — the same figures the customer's own usage
  -- view shows, because they come from the same meter.
  for k in select code, unit from erp_meta.entitlement_kind where code in ('documents_per_month', 'movements_per_month') loop
    mth := date_trunc('month', i.period_start)::date;
    while mth < i.period_end loop
      select coalesce(sum(m.quantity), 0) into v_used from erp_meta.usage_meter m
       where m.tenant_id = c.tenant_id
         and m.meter_code = case k.code when 'documents_per_month' then 'documents_posted' else 'movements_recorded' end
         and m.period_start >= mth and m.period_end < mth + interval '1 month';
      select ce.limit_value into v_limit
        from erp_meta.contract_entitlement ce
       where ce.contract_id = c.id and ce.entitlement_code = k.code
         and ce.effective_from <= mth and (ce.effective_to is null or ce.effective_to > mth)
       order by ce.effective_from desc limit 1;
      if not found then
        select pe.limit_value into v_limit from erp_meta.plan_entitlement pe where pe.plan_code = c.plan_code and pe.entitlement_code = k.code;
      end if;
      v_over := case when v_limit is null then 0 else greatest(v_used - v_limit, 0) end;
      if v_over > 0 then
        -- The band on the book that covers the overage, priced per unit of the band.
        select x.amount_minor, x.band_from, x.band_to, x.code into pi
          from (select p.amount_minor, pi2.band_from, pi2.band_to, it.code
                  from erp.price_item pi2
                  join erp.item it on it.tenant_id = pi2.tenant_id and it.id = pi2.item_id
                  join erp.item_price p on p.tenant_id = pi2.tenant_id and p.item_id = pi2.item_id
                   and p.price_kind = 'sales_list' and p.currency = c.currency
                   and p.price_list_code like '%/' || c.term_kind
                 where pi2.tenant_id = c.platform_tenant_id and pi2.kind = 'volume_band'
                   and pi2.entitlement_code = k.code and pi2.status = 'active'
                   and pi2.band_to > coalesce(v_limit, 0)
                 order by pi2.band_to limit 1) x;
        -- Bands are inclusive at both ends: 50,001 to 100,000 is 50,000 units.
        v_unit := case when pi.amount_minor is null then null
                       else pi.amount_minor / greatest(pi.band_to - coalesce(pi.band_from, 1) + 1, 1) end;
        v_lines := v_lines || jsonb_build_array(jsonb_build_object(
          'kind', 'overage', 'entitlement_code', k.code, 'unit', k.unit, 'month', mth,
          'used', v_used, 'limit_value', v_limit, 'over', v_over,
          'unit_minor', v_unit, 'band', pi.code,
          'net_minor', case when v_unit is null then 0 else round(v_over * v_unit)::bigint end,
          'unpriced', v_unit is null));
      end if;
      mth := (mth + interval '1 month')::date;
    end loop;
  end loop;
  return v_lines;
end;
$$;

create or replace function erp.issue_contract_invoice(p_invoice_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_staff erp_meta.platform_staff; i erp_meta.contract_invoice; c erp_meta.contract; v_over jsonb; v_over_minor bigint; v_lines jsonb;
begin
  v_staff := erp_meta.require_platform('operator');
  select * into i from erp_meta.contract_invoice where id = p_invoice_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_INVOICE: %', p_invoice_id using errcode = '23503';
  end if;
  if i.status <> 'scheduled' then
    raise exception 'ERPWARE_INVOICE_NOT_SCHEDULED: % is %', i.reference, i.status using errcode = '23514';
  end if;
  select * into c from erp_meta.contract where id = i.contract_id;
  v_over := erp.invoice_overage_lines(p_invoice_id);
  select coalesce(sum((x ->> 'net_minor')::bigint), 0) into v_over_minor from jsonb_array_elements(v_over) x;
  v_lines := jsonb_build_array(jsonb_build_object(
               'kind', 'subscription', 'description', format('%s plan, %s to %s', c.plan_code, i.period_start, i.period_end),
               'net_minor', i.subscription_minor)) || v_over;
  update erp_meta.contract_invoice
     set status = 'issued', issued_at = now(), lines = v_lines, overage_minor = v_over_minor,
         total_minor = i.subscription_minor + v_over_minor
   where id = p_invoice_id;
  perform set_config('erp.job_tenant_id', c.tenant_id::text, true);
  perform erp.append_event('commercial.invoice_issued', 'tenant', c.tenant_id,
    jsonb_build_object('invoice_id', i.id, 'reference', i.reference, 'total_minor', i.subscription_minor + v_over_minor, 'overage_minor', v_over_minor));
  perform set_config('erp.job_tenant_id', '', true);
  perform erp_meta.platform_log(v_staff, 'platform.invoice_issued', c.tenant_id, i.reference,
                                format('%s %s, overage %s', i.subscription_minor + v_over_minor, i.currency, v_over_minor), '{}'::jsonb);
  return jsonb_build_object('invoice_id', i.id, 'reference', i.reference, 'total_minor', i.subscription_minor + v_over_minor,
                            'overage_minor', v_over_minor, 'lines', v_lines);
end;
$$;

comment on function erp.issue_contract_invoice is
  'Specification v1.5 §17.10: issues a scheduled invoice, reconciling the '
  'period against the metering so the overage on the invoice is the overage '
  'the customer''s own usage view shows. Operator; recorded in the platform log '
  'and raised as an event in the customer''s organisation.';

create or replace function erp.record_invoice_paid(p_invoice_id uuid, p_payment_reference text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_staff erp_meta.platform_staff; i erp_meta.contract_invoice;
begin
  v_staff := erp_meta.require_platform('operator');
  select * into i from erp_meta.contract_invoice where id = p_invoice_id;
  if not found or i.status <> 'issued' then
    raise exception 'ERPWARE_INVOICE_NOT_ISSUED: %', p_invoice_id using errcode = '23514';
  end if;
  update erp_meta.contract_invoice set status = 'paid', paid_at = now(), payment_reference = p_payment_reference where id = p_invoice_id;
  perform erp_meta.platform_log(v_staff, 'platform.invoice_paid', i.tenant_id, i.reference, p_payment_reference, '{}'::jsonb);
end;
$$;

-- ── §17.10 the reporting the platform owner needs ───────────────────────────

create or replace function erp.revenue_report()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_platform uuid; v_margin jsonb := '[]'::jsonb; c record; m jsonb;
begin
  select po.tenant_id into v_platform from erp_meta.platform_organisation po;
  -- Gross margin per organisation, from the cost model behind the quote each
  -- contract was made from. Read in the platform organisation's context.
  if v_platform is not null then
    perform set_config('erp.job_tenant_id', v_platform::text, true);
    for c in select x.id, x.tenant_code, x.quote_document_id, x.annual_value_minor, x.currency from erp_meta.contract x where x.status in ('active', 'terminating') loop
      m := erp.quote_margin(c.quote_document_id);
      v_margin := v_margin || jsonb_build_array(jsonb_build_object(
        'tenant_code', c.tenant_code, 'annual_value_minor', c.annual_value_minor, 'currency', c.currency,
        'cost_minor', m -> 'totals' -> 'cost_minor', 'margin_minor', m -> 'totals' -> 'margin_minor',
        'margin_pct', m -> 'totals' -> 'margin_pct'));
    end loop;
    perform set_config('erp.job_tenant_id', '', true);
  end if;
  return jsonb_build_object(
    'arr_minor', (select coalesce(sum(annual_value_minor), 0) from erp_meta.contract where status in ('active', 'terminating')),
    'mrr_minor', (select round(coalesce(sum(annual_value_minor), 0) / 12.0)::bigint from erp_meta.contract where status in ('active', 'terminating')),
    'contracts_in_force', (select count(*) from erp_meta.contract where status in ('active', 'terminating')),
    'average_contract_value_minor', (select round(coalesce(avg(annual_value_minor), 0))::bigint from erp_meta.contract where status in ('active', 'terminating')),
    'by_plan', coalesce((select jsonb_agg(jsonb_build_object('plan_code', x.plan_code, 'contracts', x.n, 'arr_minor', x.v) order by x.v desc)
                           from (select plan_code, count(*) n, sum(annual_value_minor) v from erp_meta.contract where status in ('active', 'terminating') group by plan_code) x), '[]'::jsonb),
    'by_capability', coalesce((select jsonb_agg(jsonb_build_object('capability_code', x.capability_code, 'contracts', x.n) order by x.n desc)
                                 from (select cc.capability_code, count(distinct cc.contract_id) n
                                         from erp_meta.contract_capability cc join erp_meta.contract ct on ct.id = cc.contract_id
                                        where ct.status in ('active', 'terminating') and cc.effective_from <= current_date and (cc.effective_to is null or cc.effective_to > current_date)
                                        group by cc.capability_code) x), '[]'::jsonb),
    'gross_margin', v_margin,
    'renewals_last_12_months', jsonb_build_object(
      'accepted', (select count(*) from erp_meta.renewal where status = 'accepted' and decided_at >= now() - interval '12 months'),
      'declined', (select count(*) from erp_meta.renewal where status = 'declined' and decided_at >= now() - interval '12 months'),
      'lapsed', (select count(*) from erp_meta.renewal where status = 'lapsed' and decided_at >= now() - interval '12 months'),
      'renewal_rate_pct', (select case when count(*) = 0 then null else round(100.0 * count(*) filter (where status = 'accepted') / count(*), 1) end
                             from erp_meta.renewal where status in ('accepted', 'declined', 'lapsed') and decided_at >= now() - interval '12 months')),
    'churn', jsonb_build_object(
      'contracts_ended_last_12_months', (select count(*) from erp_meta.contract where status in ('expired', 'terminated') and updated_at >= now() - interval '12 months'),
      'arr_lost_minor', (select coalesce(sum(annual_value_minor), 0) from erp_meta.contract where status in ('expired', 'terminated') and updated_at >= now() - interval '12 months')),
    'revenue_at_risk', coalesce((
      -- Within the next two notice windows, with no renewal accepted.
      select jsonb_agg(jsonb_build_object('tenant_code', x.tenant_code, 'annual_value_minor', x.annual_value_minor,
                                          'notice_deadline', (x.current_term_end - x.notice_days)::date, 'renewal_status',
                                          (select r.status from erp_meta.renewal r where r.contract_id = x.id and r.term_start = x.current_term_end))
                       order by x.current_term_end)
        from erp_meta.contract x
       where x.status in ('active', 'terminating')
         and (x.current_term_end - x.notice_days)::date <= current_date + 2 * x.notice_days
         and not exists (select 1 from erp_meta.renewal r where r.contract_id = x.id and r.term_start = x.current_term_end and r.status = 'accepted')), '[]'::jsonb),
    'revenue_at_risk_minor', (select coalesce(sum(x.annual_value_minor), 0) from erp_meta.contract x
                               where x.status in ('active', 'terminating')
                                 and (x.current_term_end - x.notice_days)::date <= current_date + 2 * x.notice_days
                                 and not exists (select 1 from erp_meta.renewal r where r.contract_id = x.id and r.term_start = x.current_term_end and r.status = 'accepted')),
    'invoices', jsonb_build_object(
      'scheduled_minor', (select coalesce(sum(total_minor), 0) from erp_meta.contract_invoice where status = 'scheduled'),
      'issued_minor', (select coalesce(sum(total_minor), 0) from erp_meta.contract_invoice where status = 'issued'),
      'paid_minor', (select coalesce(sum(total_minor), 0) from erp_meta.contract_invoice where status = 'paid'),
      'overage_issued_minor', (select coalesce(sum(overage_minor), 0) from erp_meta.contract_invoice where status in ('issued', 'paid'))),
    'renewals', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'tenant_code', ct.tenant_code, 'term_start', r.term_start, 'term_end', r.term_end,
                                                              'uplift_pct', r.uplift_pct, 'previous_annual_value_minor', r.previous_annual_value_minor,
                                                              'proposed_annual_value_minor', r.proposed_annual_value_minor, 'currency', r.currency,
                                                              'notice_deadline', r.notice_deadline, 'status', r.status, 'quote_document_id', r.quote_document_id)
                                         order by r.term_start)
                            from erp_meta.renewal r join erp_meta.contract ct on ct.id = r.contract_id), '[]'::jsonb));
end;
$$;

-- ── §17.11 what the customer sees ────────────────────────────────────────────

create or replace function erp.my_agreement()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); c erp_meta.contract; v_pos jsonb;
begin
  perform erp.authorise('administration.read');
  select * into c from erp_meta.contract x
   where x.tenant_id = v_tenant
   order by case x.status when 'active' then 0 when 'terminating' then 1 when 'expired' then 2 else 3 end, x.commencement desc
   limit 1;
  v_pos := case when c.id is null then null else erp.contract_position(c.id) - 'notices' end;
  return jsonb_build_object(
    'contract', v_pos,
    'documents', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'version', d.version, 'title', d.title,
                                                              'checksum', d.checksum, 'signed_at', d.signed_at, 'superseded_by', d.superseded_by,
                                                              'byte_size', octet_length(d.content), 'created_at', d.created_at)
                                            order by d.kind, d.version)
                             from erp_meta.contract_document d join erp_meta.contract ct on ct.id = d.contract_id
                            where ct.tenant_id = v_tenant), '[]'::jsonb),
    'entitlements', coalesce((select jsonb_agg(jsonb_build_object('entitlement_code', e.entitlement_code, 'title', e.title, 'unit', e.unit,
                                                                 'limit_value', e.limit_value, 'used', e.used, 'remaining', e.remaining, 'breached', e.breached,
                                                                 'source', case when exists (select 1 from erp_meta.contract_entitlement ce join erp_meta.contract ct on ct.id = ce.contract_id
                                                                                              where ct.tenant_id = v_tenant and ct.status in ('active', 'terminating') and ce.entitlement_code = e.entitlement_code
                                                                                                and ce.effective_from <= current_date and (ce.effective_to is null or ce.effective_to > current_date))
                                                                                then 'contract' else 'plan' end)
                                               order by e.entitlement_code)
                                from erp.entitlement_report(v_tenant) e), '[]'::jsonb),
    'capabilities', coalesce((select jsonb_agg(x.code order by x.code) from (
                                select pc.capability_code as code from erp_meta.plan_capability pc where pc.plan_code = erp.tenant_plan_code(v_tenant)
                                union
                                select cc.capability_code from erp_meta.contract_capability cc join erp_meta.contract ct on ct.id = cc.contract_id
                                 where ct.tenant_id = v_tenant and ct.status in ('active', 'terminating')
                                   and cc.effective_from <= current_date and (cc.effective_to is null or cc.effective_to > current_date)) x), '[]'::jsonb),
    'meters', coalesce((select jsonb_agg(jsonb_build_object('meter_code', m.meter_code, 'title', k.title, 'unit', k.unit,
                                                           'period_start', m.period_start, 'period_end', m.period_end,
                                                           'quantity', m.quantity, 'measured_at', m.measured_at)
                                         order by m.period_start desc, m.meter_code)
                          from (select * from erp_meta.usage_meter u where u.tenant_id = v_tenant order by u.period_start desc, u.meter_code limit 48) m
                          left join erp_meta.meter_kind k on k.code = m.meter_code), '[]'::jsonb),
    'invoices', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'reference', i.reference, 'period_start', i.period_start, 'period_end', i.period_end,
                                                             'due_on', i.due_on, 'currency', i.currency, 'subscription_minor', i.subscription_minor,
                                                             'overage_minor', i.overage_minor, 'total_minor', i.total_minor, 'status', i.status,
                                                             'issued_at', i.issued_at, 'paid_at', i.paid_at,
                                                             'lines', case when i.status = 'scheduled' then erp.invoice_overage_lines(i.id) else i.lines end)
                                           order by i.period_start)
                            from erp_meta.contract_invoice i where i.tenant_id = v_tenant), '[]'::jsonb),
    'renewal', (select jsonb_build_object('term_start', r.term_start, 'term_end', r.term_end, 'uplift_pct', r.uplift_pct,
                                          'proposed_annual_value_minor', r.proposed_annual_value_minor, 'currency', r.currency,
                                          'notice_deadline', r.notice_deadline, 'status', r.status)
                  from erp_meta.renewal r where r.contract_id = c.id order by r.term_start desc limit 1),
    'subscription', (select jsonb_build_object('plan_code', s.plan_code, 'term_start', s.term_start, 'term_end', s.term_end,
                                               'renews', s.renews, 'currency', s.currency, 'status', s.status)
                       from erp_meta.subscription s where s.tenant_id = v_tenant and s.status <> 'terminated' limit 1),
    'sub_processors', coalesce((select jsonb_agg(jsonb_build_object('code', sp.code, 'name', sp.name, 'purpose', sp.purpose, 'location', sp.location,
                                                                   'added_at', sp.added_at, 'notified_at', sp.notified_at, 'withdrawn_at', sp.withdrawn_at)
                                                 order by sp.added_at desc, sp.code)
                                  from erp_meta.sub_processor sp), '[]'::jsonb),
    'service_commitments', coalesce((select jsonb_agg(jsonb_build_object('code', sc.code, 'title', sc.title, 'commitment', sc.commitment,
                                                                        'derived_from', sc.derived_from, 'remedy', sc.remedy) order by sc.seq)
                                       from erp_meta.service_commitment sc), '[]'::jsonb));
end;
$$;

comment on function erp.my_agreement is
  'Specification v1.5 §17.11, D38: the organisation''s own contract, documents, '
  'entitlement in the contract''s terms, live usage, invoices with the metering '
  'behind them, renewal date, notice deadline, uplift rule and the '
  'sub-processor list with its changes. Security definer because erp_meta is '
  'platform-internal; scoped to the caller''s organisation and nothing else.';

create or replace function erp.my_contract_document(p_document_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id();
begin
  perform erp.authorise('administration.read');
  return (select jsonb_build_object('id', d.id, 'kind', d.kind, 'version', d.version, 'title', d.title, 'content', d.content,
                                    'checksum', d.checksum, 'signed_at', d.signed_at, 'signed_by_customer', d.signed_by_customer,
                                    'signed_by_platform', d.signed_by_platform, 'signature_meaning', d.signature_meaning)
            from erp_meta.contract_document d join erp_meta.contract c on c.id = d.contract_id
           where d.id = p_document_id and c.tenant_id = v_tenant);
end;
$$;

-- ── The findings and the assertion (D38, §17.4) ──────────────────────────────

create or replace function erp.customer_view_report()
returns table(finding text, reference text, detail text)
language sql
stable
security definer
set search_path = ''
as $$
  -- §17.4: "sub-processors are listed, with notification before any addition".
  select 'a sub-processor was added without notice to the organisations', sp.code,
         format('added %s, notified %s', sp.added_at, coalesce(sp.notified_at::text, 'never'))
    from erp_meta.sub_processor sp
   where sp.withdrawn_at is null and (sp.notified_at is null or sp.notified_at > sp.added_at)
  union all
  -- §17.10: a contract in force with no invoice schedule is a customer who
  -- cannot see what it will pay next.
  select 'a contract in force has no invoice schedule', c.tenant_code, c.id::text
    from erp_meta.contract c
   where c.status in ('active', 'terminating')
     and not exists (select 1 from erp_meta.contract_invoice i where i.contract_id = c.id)
  union all
  -- An issued invoice whose overage could not be priced: the customer sees a
  -- figure the book cannot explain.
  select 'an issued invoice carries an overage the price book could not price', i.reference, x ->> 'entitlement_code'
    from erp_meta.contract_invoice i cross join lateral jsonb_array_elements(i.lines) x
   where i.status in ('issued', 'paid') and (x ->> 'unpriced')::boolean
  union all
  -- §17.10: an index-linked contract whose renewal window is open with no rate
  -- published — the renewal cannot be generated, only remembered.
  select 'an index-linked contract in its renewal window has no index rate published', c.tenant_code, c.uplift_rule ->> 'index_code'
    from erp_meta.contract c
   where c.status = 'active' and c.renewal_kind <> 'none'
     and c.uplift_rule ->> 'kind' in ('index', 'capped')
     and (c.current_term_end - c.notice_days - c.lead_days) <= current_date
     and erp.uplift_pct_for(c.uplift_rule, current_date) is null
  order by 1, 2
$$;

create or replace function erp.assert_customer_view_sound()
returns text
language plpgsql
set search_path = ''
as $$
declare v_count integer; v_detail text;
begin
  select count(*), string_agg(format('  %s — %s: %s', finding, reference, detail), E'\n')
    into v_count, v_detail from erp.customer_view_report();
  if v_count > 0 then
    raise exception 'ERPWARE_CUSTOMER_VIEW_UNSOUND: % finding(s)', v_count
      using errcode = 'P0001', detail = v_detail,
            hint = 'D38: the organisation sees its own contract, entitlement, usage, invoices and renewal terms without asking, and every figure it sees is one the platform can explain.';
  end if;
  return format('customer view: %s invoice(s) scheduled or issued, %s sub-processor(s) listed with notice',
                (select count(*) from erp_meta.contract_invoice), (select count(*) from erp_meta.sub_processor where withdrawn_at is null));
end;
$$;

insert into erp_ref.job_handler
  (code, name_key, description, module_code, parameter_schema, default_timeout_seconds, forbids_overlap, is_current, sql_function)
values
  ('commercial.propose_renewals', 'job_handler.propose_renewals.name',
   'Proposes the next term for every contract entering its notice lead time, with the uplift rule applied. §17.10.',
   null, '{"type": "object", "additionalProperties": false}'::jsonb, 300, true, true, 'propose_renewals'),
  ('commercial.expire_contracts', 'job_handler.expire_contracts.name',
   'Expires contracts past their term without an accepted renewal and moves their organisations to grace. §17.3, §17.10.',
   null, '{"type": "object", "additionalProperties": false}'::jsonb, 300, true, true, 'expire_contracts'),
  ('commercial.generate_invoice_schedules', 'job_handler.generate_invoice_schedules.name',
   'Generates the invoice schedule for every contract in force from its term and billing frequency. §17.10.',
   null, '{"type": "object", "additionalProperties": false}'::jsonb, 300, true, true, 'generate_invoice_schedules')
on conflict (code) do update set
  description = excluded.description, sql_function = excluded.sql_function, is_current = excluded.is_current;

-- ── The doors ────────────────────────────────────────────────────────────────

create or replace function public.erp_my_agreement()
returns jsonb language sql stable set search_path = '' as $$ select erp.my_agreement(); $$;

create or replace function public.erp_my_contract_document(p_document_id uuid)
returns jsonb language sql stable set search_path = '' as $$ select erp.my_contract_document(p_document_id); $$;

create or replace function public.erp_open_renewal_quote(p_renewal_id uuid)
returns uuid language sql set search_path = '' as $$ select erp.open_renewal_quote(p_renewal_id); $$;

create or replace function public.erp_commercial_renewals()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_tenant uuid := erp.require_tenant_id();
begin
  perform erp.authorise('sales.order', null, null, null, 'renewal', null);
  perform erp.require_platform_organisation();
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'tenant_code', c.tenant_code, 'customer_legal_name', c.customer_legal_name,
                                                       'term_start', r.term_start, 'term_end', r.term_end, 'uplift_pct', r.uplift_pct,
                                                       'previous_annual_value_minor', r.previous_annual_value_minor,
                                                       'proposed_annual_value_minor', r.proposed_annual_value_minor, 'currency', r.currency,
                                                       'notice_deadline', r.notice_deadline, 'status', r.status, 'quote_document_id', r.quote_document_id)
                                    order by r.notice_deadline, c.tenant_code)
                     from erp_meta.renewal r join erp_meta.contract c on c.id = r.contract_id
                    where c.platform_tenant_id = v_tenant and r.status in ('proposed', 'quoted')), '[]'::jsonb);
end;
$$;

create or replace function public.erp_platform_propose_renewals()
returns integer language sql set search_path = '' as $$ select erp.propose_renewals(); $$;

create or replace function public.erp_platform_renew_contract(p_renewal_id uuid, p_customer_signer text, p_platform_signer text, p_signature_meaning text)
returns uuid language sql set search_path = '' as $$ select erp.renew_contract(p_renewal_id, p_customer_signer, p_platform_signer, p_signature_meaning); $$;

create or replace function public.erp_platform_decline_renewal(p_renewal_id uuid, p_note text)
returns void language sql set search_path = '' as $$ select erp.decline_renewal(p_renewal_id, p_note); $$;

create or replace function public.erp_platform_generate_invoices(p_contract_id uuid)
returns integer language plpgsql security definer set search_path = '' as $$
declare v erp_meta.platform_staff;
begin
  v := erp_meta.require_platform('operator');
  return erp.generate_invoice_schedule(p_contract_id);
end;
$$;

create or replace function public.erp_platform_issue_invoice(p_invoice_id uuid)
returns jsonb language sql set search_path = '' as $$ select erp.issue_contract_invoice(p_invoice_id); $$;

create or replace function public.erp_platform_record_invoice_paid(p_invoice_id uuid, p_payment_reference text)
returns void language sql set search_path = '' as $$ select erp.record_invoice_paid(p_invoice_id, p_payment_reference); $$;

create or replace function public.erp_platform_invoices(p_contract_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v erp_meta.platform_staff;
begin
  v := erp_meta.require_platform('support');
  return coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'reference', i.reference, 'period_start', i.period_start, 'period_end', i.period_end,
                                                       'due_on', i.due_on, 'currency', i.currency, 'subscription_minor', i.subscription_minor,
                                                       'overage_minor', i.overage_minor, 'total_minor', i.total_minor, 'status', i.status,
                                                       'issued_at', i.issued_at, 'paid_at', i.paid_at, 'payment_reference', i.payment_reference,
                                                       'lines', case when i.status = 'scheduled' then erp.invoice_overage_lines(i.id) else i.lines end)
                                    order by i.period_start)
                     from erp_meta.contract_invoice i where i.contract_id = p_contract_id), '[]'::jsonb);
end;
$$;

create or replace function public.erp_platform_revenue()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v erp_meta.platform_staff;
begin
  v := erp_meta.require_platform('support');
  return erp.revenue_report();
end;
$$;

create or replace function public.erp_platform_set_index_rate(p_index_code text, p_period date, p_rate_pct numeric, p_source text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare v erp_meta.platform_staff;
begin
  v := erp_meta.require_platform('operator');
  insert into erp_meta.index_rate (index_code, period, rate_pct, source) values (p_index_code, p_period, p_rate_pct, p_source)
  on conflict (index_code, period) do update set rate_pct = excluded.rate_pct, source = excluded.source;
  perform erp_meta.platform_log(v, 'platform.index_rate_published', null, p_index_code, format('%s: %s%%', p_period, p_rate_pct), '{}'::jsonb);
end;
$$;

revoke all on function
  public.erp_my_agreement(),
  public.erp_my_contract_document(uuid),
  public.erp_open_renewal_quote(uuid),
  public.erp_commercial_renewals(),
  public.erp_platform_propose_renewals(),
  public.erp_platform_renew_contract(uuid, text, text, text),
  public.erp_platform_decline_renewal(uuid, text),
  public.erp_platform_generate_invoices(uuid),
  public.erp_platform_issue_invoice(uuid),
  public.erp_platform_record_invoice_paid(uuid, text),
  public.erp_platform_invoices(uuid),
  public.erp_platform_revenue(),
  public.erp_platform_set_index_rate(text, date, numeric, text)
  from public, anon;

grant execute on function
  public.erp_my_agreement(),
  public.erp_my_contract_document(uuid),
  public.erp_open_renewal_quote(uuid),
  public.erp_commercial_renewals(),
  public.erp_platform_propose_renewals(),
  public.erp_platform_renew_contract(uuid, text, text, text),
  public.erp_platform_decline_renewal(uuid, text),
  public.erp_platform_generate_invoices(uuid),
  public.erp_platform_issue_invoice(uuid),
  public.erp_platform_record_invoice_paid(uuid, text),
  public.erp_platform_invoices(uuid),
  public.erp_platform_revenue(),
  public.erp_platform_set_index_rate(text, date, numeric, text)
  to authenticated, service_role;

-- ── Registration ─────────────────────────────────────────────────────────────

insert into erp_meta.table_policy (schema_name, table_name, table_class, note) values
  ('erp_meta','index_rate','platform_internal','Part 17 §17.8. Published index rates an uplift rule refers to.'),
  ('erp_meta','renewal','platform_internal','Part 17 §17.10. Renewals generated at the notice lead time with the uplift applied.'),
  ('erp_meta','contract_invoice','platform_internal','Part 17 §17.10. The invoice schedule, reconciled against metering when issued; outlives a purge.')
on conflict (schema_name, table_name) do nothing;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_open_renewal_quote', 'erp.open_renewal_quote', 'Raises the renewal quote from a proposal. Refused outside the platform organisation; sales.order inside it.'),
  ('erp_platform_propose_renewals', 'erp.propose_renewals', 'Runs the renewal sweep on demand. Refuses any session whose role does not bypass row-level security; writes proposals only.'),
  ('erp_platform_renew_contract', 'erp.renew_contract', 'Renews a contract from an accepted renewal quote as a signed, provisioned amendment. Operator.'),
  ('erp_platform_decline_renewal', 'erp.decline_renewal', 'Records a non-renewal with its note; the contract runs to its term end. Operator.'),
  ('erp_platform_generate_invoices', 'erp.generate_invoice_schedule', 'Generates a contract''s invoice schedule from its term and frequency. Operator, on the first line.'),
  ('erp_platform_issue_invoice', 'erp.issue_contract_invoice', 'Issues a scheduled invoice, reconciled against the metering. Operator.'),
  ('erp_platform_record_invoice_paid', 'erp.record_invoice_paid', 'Records payment against an issued invoice. Operator.'),
  ('erp_platform_set_index_rate', 'erp_meta.require_platform', 'Publishes an index rate an uplift rule refers to. Operator, on the first line; recorded in the platform log.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp', 'uplift_pct_for', 'Reads erp_meta.index_rate to evaluate an uplift rule. Returns one number.'),
  ('erp', 'propose_renewals', 'Sweeps every contract in force and writes proposals; refuses any session whose role does not already bypass row-level security.'),
  ('erp', 'open_renewal_quote', 'Reads the proposal and contract in erp_meta and writes a quote in the caller''s own organisation, which must be the platform''s.'),
  ('erp', 'renew_contract', 'Reads the renewal quote across the tenant boundary and writes the amendment, the contract and the subscription. Operator on the first line.'),
  ('erp', 'decline_renewal', 'Writes the renewal, the contract and the subscription, and raises the event in the customer''s organisation. Operator.'),
  ('erp', 'expire_contracts', 'Sweeps every contract past its term; refuses any session whose role does not already bypass row-level security.'),
  ('erp', 'generate_invoice_schedule', 'Writes erp_meta.contract_invoice from one contract. Called by renewal, by the sweep and by the operator door.'),
  ('erp', 'generate_invoice_schedules', 'Sweeps every contract in force; refuses any session whose role does not already bypass row-level security.'),
  ('erp', 'invoice_overage_lines', 'Reads the customer''s meters, the contract''s bands and the platform organisation''s price book to price an overage. Returns lines for one invoice.'),
  ('erp', 'issue_contract_invoice', 'Issues an invoice and raises the event in the customer''s organisation. Operator on the first line.'),
  ('erp', 'record_invoice_paid', 'Writes payment against an invoice. Operator on the first line.'),
  ('erp', 'revenue_report', 'Reads every contract, renewal and invoice for the platform owner; reads margin in the platform organisation''s context. Called only through a door gated at support.'),
  ('erp', 'my_agreement', 'Reads erp_meta for the caller''s own organisation only: its contract, documents, entitlement, invoices, renewal, and the product-wide sub-processor and commitment lists. Gated by administration.read.'),
  ('erp', 'my_contract_document', 'Returns one contract document''s text only where the contract is the caller''s own organisation''s. Gated by administration.read.'),
  ('erp', 'customer_view_report', 'Reads erp_meta registers to find what a customer would see and the platform could not explain. Names organisations by code only.'),
  ('public', 'erp_commercial_renewals', 'Lists proposals for the platform organisation to quote. Refused outside it.'),
  ('public', 'erp_platform_generate_invoices', 'Operator door; gated by erp_meta.require_platform(''operator'') on its first line.'),
  ('public', 'erp_platform_invoices', 'Console read of a contract''s invoices. Gated by erp_meta.require_platform(''support'').'),
  ('public', 'erp_platform_revenue', 'Console read of the revenue report. Gated by erp_meta.require_platform(''support'').'),
  ('public', 'erp_platform_set_index_rate', 'Operator door; gated by erp_meta.require_platform(''operator'') on its first line.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('customer_view', 'Customer view sound', 'assertion', 'platform',
   'erp', 'assert_customer_view_sound', '', 'customer_view_report', '',
   'D38: every contract in force has an invoice schedule the customer can see, every overage on an issued invoice is priced from the book, every sub-processor was notified before it was added, and an index-linked renewal has its rate published.',
   true, 73)
on conflict (code) do update set
  title = excluded.title, blurb = excluded.blurb, function_name = excluded.function_name,
  detail_function = excluded.detail_function, seq = excluded.seq;

insert into erp_ref.product_decision (code, seq, title, decision, rationale, cost, spec_reference) values
  ('D38', 38, 'An organisation can always see its own contract, entitlement, usage and renewal terms',
   'Contract documents, entitlements, live usage, invoices, notice deadlines and uplift rules are visible to the customer without asking.',
   'Having to request a copy of your own agreement is the failure this product was conceived in reaction to.',
   'The commercial record is designed to be shown, so nothing in it may be phrased for the platform''s eyes only.', 'v1.5 §17.11, Part 22 D38')
on conflict (code) do update set
  seq = excluded.seq, title = excluded.title, decision = excluded.decision,
  rationale = excluded.rationale, cost = excluded.cost, spec_reference = excluded.spec_reference;

insert into erp_ref.product_decision_check (decision_code, schema_name, routine_name, note) values
  ('D38', 'erp', 'assert_customer_view_sound',
   'D38 says the organisation sees its own agreement without asking. erp_my_agreement() is the door; the assertion fails what the door would show and the platform could not explain: a contract with no invoice schedule, an unpriced overage, a sub-processor added without notice.')
on conflict (decision_code, schema_name, routine_name) do update set note = excluded.note;

insert into erp_meta.policy_decision (code, title, spec_reference, decision, rationale, status, evidence) values
  ('renewal_is_proposed_by_sweep_and_quoted_by_a_person',
   'A renewal is generated by the platform and quoted by the platform organisation',
   'v1.5 §17.10',
   'erp.propose_renewals() generates the next term with the uplift rule applied, once, at the notice lead time. erp.open_renewal_quote() turns the proposal into a quote through the same builder as every quote, raised by a person in the platform organisation; accepting it renews the contract as a signed amendment through erp.renew_contract().',
   'A sweep has no principal, and a quote is a document that authorises, approves and audits against one. Splitting the generation (which needs no person) from the raising (which does) keeps every quote on the same rails, including the renewal''s discount approval and its order form.',
   'accepted',
   'erp_meta.renewal; erp.propose_renewals(); erp.open_renewal_quote(); erp.renew_contract(); erp_test.commercial_renewal_suite().'),
  ('non_renewal_ends_in_grace_not_restriction',
   'A term that ends without renewal moves the organisation to grace; restriction is an operator''s act',
   'v1.5 §17.3, §17.10',
   'erp.expire_contracts() marks the contract expired and the subscription grace: service continues, the organisation is told, and its export remains available. Moving an organisation to restricted or suspended stays a platform operator''s recorded decision through the existing lifecycle door.',
   '§17.3 orders the states — grace, restricted, suspended — and says an organisation that cannot pay must still retrieve its records. A sweep that restricted on a date would decide a collection matter nobody looked at.',
   'accepted',
   'erp.expire_contracts(); erp_platform_set_tenant_status() for restriction; erp.assert_contract_provisions_entitlement() allows a grace subscription against an expired contract.')
on conflict (code) do update set
  title = excluded.title, decision = excluded.decision, rationale = excluded.rationale,
  status = excluded.status, evidence = excluded.evidence;

-- ── Resources, help ──────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description) values
('event.commercial.contract_renewed', 'en', 'Contract renewed', 'The organisation''s contract was renewed for a further term.'),
('event.commercial.non_renewal_recorded', 'en', 'Non-renewal recorded', 'The organisation''s contract will not renew; the notice period is honoured.'),
('event.commercial.term_ended', 'en', 'Term ended', 'The contract''s term ended without renewal; service continues in grace.'),
('event.commercial.invoice_issued', 'en', 'Invoice issued', 'An invoice was issued, reconciled against the organisation''s metering.'),
('job_handler.propose_renewals.name', 'en', 'Propose renewals', 'The scheduled sweep that generates each renewal at the notice lead time with the uplift applied.'),
('job_handler.expire_contracts.name', 'en', 'Expire contracts', 'The scheduled sweep that expires contracts past their term without renewal.'),
('job_handler.generate_invoice_schedules.name', 'en', 'Generate invoice schedules', 'The scheduled sweep that generates each contract''s invoice schedule from its term and billing frequency.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(t.text), 'en', t.text,
       'Screen wording, keyed by its own source text so a tenant can rename it.'
  from (values
    ('Your agreement'),
    ('What this organisation is entitled to, what it is using, what it will pay next and when its term ends, without asking. The contract is the source; the entitlement enforced is derived from it.'),
    ('No contract is recorded for this organisation yet. The plan below is the platform''s default until one is signed.'),
    ('Documents'),
    ('Every document that constitutes the agreement, versioned and signed, with the checksum of what was signed.'),
    ('Term'),
    ('Notice deadline'),
    ('Uplift rule'),
    ('Renewal'),
    ('What you will pay next'),
    ('Each invoice in the schedule, and the metering behind any overage. A scheduled invoice shows the overage it would carry today, from the same meters you see above.'),
    ('Nothing is scheduled.'),
    ('Overage'),
    ('Subscription'),
    ('Sub-processors'),
    ('Who processes your data on the platform''s behalf, when each was added, and when you were told. A sub-processor is notified before it is added.'),
    ('None is listed.'),
    ('Service commitments'),
    ('Renewals'),
    ('Generated at the notice lead time from the contract with its uplift rule applied. Raise the quote here; it goes through the same builder, approval and order form as any other.'),
    ('No renewal is proposed.'),
    ('Raise the renewal quote'),
    ('Proposed value'),
    ('Previous value'),
    ('Uplift')
  ) t(text)
on conflict (key, locale) do nothing;

update erp_ref.help_topic set
  summary = 'The organisation''s own agreement: its contract and the documents that constitute it, its entitlement in the contract''s terms, its live usage, its invoices with the metering behind them, its renewal date, notice deadline and uplift rule, and the sub-processor list with every change to it. Nothing here has to be asked for.',
  steps = '["Read the contract and download its documents; each carries the checksum of what was signed.","Compare each entitlement against what is used; a contract band overrides the plan''s figure.","Read what you will pay next: the schedule, and the overage a scheduled invoice would carry today from the same meters.","Note the notice deadline and the uplift rule; a renewal is proposed at the lead time and shown here."]',
  next_action = 'Read the notice deadline and the next invoice.'
where screen_path = '/administration/commercial';

-- ── The suite ─────────────────────────────────────────────────────────────────

create or replace function erp_test.commercial_renewal_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  rp record; rc record;
  ad uuid := gen_random_uuid(); ow uuid := gen_random_uuid(); ca uuid := gen_random_uuid();
  v_platform uuid; v_pcode text := 'zzrnp-' || substr(md5(random()::text), 1, 6);
  v_customer uuid; v_ccode text := 'zzrnc-' || substr(md5(random()::text), 1, 6);
  v_q uuid; v_q2 uuid; v_contract uuid; v_renewal uuid; v_inv uuid; res jsonb; v_ok boolean; v_msg text; v_n integer;
begin
  select * into rp from erp.provision_tenant(v_pcode, 'Clove Platform Renewals', 'admin@zzrn.test', 'Platform Admin');
  v_platform := rp.tenant_id;
  select * into rc from erp.provision_tenant(v_ccode, 'Beta Pharma Ltd', 'admin@zzrnc.test', 'Customer Admin');
  v_customer := rc.tenant_id;
  insert into auth.users (id, email) values (ad, 'admin@zzrn.test'), (ow, 'owner@zzrn.test'), (ca, 'admin@zzrnc.test');
  insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
  values ('owner@zzrn.test', ow, 'Platform Owner', 'owner');
  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  perform erp.claim_invitation(rp.admin_token);
  perform set_config('request.jwt.claims', json_build_object('sub', ca)::text, true);
  perform erp.claim_invitation(rc.admin_token);
  perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
  perform erp.designate_platform_organisation(v_pcode);

  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  perform erp_test.reopen_bootstrap_window(v_platform);
  perform erp.configure_commercial(10, 'administrator');
  perform erp.open_price_book('PB-2026', 'List 2026', array['GBP'], current_date - 1, null);
  perform erp_test.close_bootstrap_window(v_platform);
  perform erp.upsert_price_item('PLAN-STD', 'Standard plan', 'plan_tier', 'standard');
  perform erp.upsert_price_item('DOCS-100K', 'Up to 100,000 documents a month', 'volume_band', null, null, 'documents_per_month', 50001, 100000);
  perform erp.set_rate('PB-2026', 'PLAN-STD', 'GBP', 1200000);
  perform erp.set_rate('PB-2026', 'DOCS-100K', 'GBP', 500000);
  perform erp.set_cost_model('PLAN-STD', 'GBP', 300000, 100000, 50000);
  perform erp.set_cost_model('DOCS-100K', 'GBP', 100000, 0, 0);
  v_q := erp.open_commercial_quote('BETA', 'Beta Pharma Ltd', 'PB-2026', 'annual', 12, 'GBP', 30, v_ccode);
  perform erp.add_quote_line(v_q, 'PLAN-STD');
  perform erp.submit_quote(v_q);
  perform erp.issue_quote(v_q);
  perform erp.quote_transition(v_q, 'accept', 'signed');
  perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
  v_contract := erp.create_contract_from_quote(v_q, v_ccode, 'Beta Pharma Ltd', 'Clove Ltd', current_date - 300, 12, 'automatic', 90,
                                               'England and Wales', 'quarterly', '{"kind": "fixed_pct", "pct": 5}'::jsonb, '{}'::jsonb, null, 30);
  perform erp.sign_contract(v_contract, 'B. Customer', 'P. Owner', 'Agreement to the order form and the terms it names');

  -- ── §17.10 invoices from the term, reconciled against metering ───────────

  return query select 'a contract in force with no invoice schedule is a finding the customer would feel',
    exists (select 1 from erp.customer_view_report() f where f.finding like 'a contract in force has no invoice schedule%' and f.reference = v_ccode), 'D38';
  v_n := erp.generate_invoice_schedule(v_contract);
  return query select 'the invoice schedule generates from the term and the billing frequency',
    v_n = 4 and (select sum(i.subscription_minor) from erp_meta.contract_invoice i where i.contract_id = v_contract) = 1200000
    and (select count(*) from erp_meta.contract_invoice i where i.contract_id = v_contract and i.status = 'scheduled') = 4,
    'four quarterly invoices of 3,000';
  return query select 'and generating again adds nothing', erp.generate_invoice_schedule(v_contract) = 0, 'idempotent';

  -- The customer posts beyond its band this month; the meter the platform
  -- already keeps says so.
  perform erp.record_meter('documents_posted', 60000, v_customer);
  select i.id into v_inv from erp_meta.contract_invoice i where i.contract_id = v_contract and i.period_start <= current_date and i.period_end > current_date;
  res := erp.issue_contract_invoice(v_inv);
  return query select 'issuing an invoice reconciles the period against the metering and prices the overage from the book',
    (res ->> 'overage_minor')::bigint = 100000
    and (res ->> 'total_minor')::bigint = 300000 + 100000
    and exists (select 1 from jsonb_array_elements(res -> 'lines') x where x ->> 'kind' = 'overage' and (x ->> 'over')::numeric = 10000 and (x ->> 'unit_minor')::numeric = 10),
    '10,000 documents over 50,000 at 10p each from the DOCS-100K band';
  return query select 'and the customer''s organisation is told',
    exists (select 1 from erp.event e where e.tenant_id = v_customer and e.event_type = 'commercial.invoice_issued'), 'commercial.invoice_issued';

  -- ── §17.11 what the customer sees ────────────────────────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', ca)::text, true);
  res := erp.my_agreement();
  return query select 'the organisation sees its contract, documents, entitlement, usage and invoices without asking',
    res -> 'contract' ->> 'plan_code' = 'standard'
    and jsonb_array_length(res -> 'documents') >= 1
    and exists (select 1 from jsonb_array_elements(res -> 'entitlements') e where e ->> 'entitlement_code' = 'documents_per_month' and (e ->> 'used')::numeric = 60000)
    and exists (select 1 from jsonb_array_elements(res -> 'invoices') i where i ->> 'status' = 'issued' and (i ->> 'overage_minor')::bigint = 100000)
    and exists (select 1 from jsonb_array_elements(res -> 'contract' -> 'key_dates') k where k ->> 'kind' = 'notice_deadline')
    and res -> 'contract' -> 'uplift_rule' ->> 'kind' = 'fixed_pct',
    'the same overage the invoice carries, the notice deadline, the uplift rule';
  return query select 'the invoice the customer sees is the invoice that was issued, line for line',
    (select i -> 'lines' from jsonb_array_elements(res -> 'invoices') i where i ->> 'status' = 'issued') = erp_test.res_lines(v_inv),
    'identical';
  res := erp.my_contract_document((select d.id from erp_meta.contract_document d where d.contract_id = v_contract and d.kind = 'order_form'));
  return query select 'and can read a document in full, with the checksum of what was signed',
    res ->> 'content' is not null and res ->> 'checksum' = md5(res ->> 'content') and res ->> 'signed_by_customer' = 'B. Customer', 'order form';

  -- Another organisation sees nothing of it.
  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  res := erp.my_agreement();
  return query select 'another organisation sees nothing of it',
    res -> 'contract' is null or res -> 'contract' = 'null'::jsonb, 'scoped by construction';
  return query select 'and cannot read its documents',
    erp.my_contract_document((select d.id from erp_meta.contract_document d where d.contract_id = v_contract limit 1)) is null, 'null';

  -- ── §17.10 renewals generated, not remembered ────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  v_n := erp.propose_renewals();
  return query select 'at the notice lead time a renewal is proposed with the uplift rule applied',
    v_n = 1 and exists (select 1 from erp_meta.renewal r where r.contract_id = v_contract and r.status = 'proposed'
                         and r.uplift_pct = 5 and r.proposed_annual_value_minor = 1260000
                         and r.term_start = (select c.current_term_end from erp_meta.contract c where c.id = v_contract)),
    '1,200,000 uplifted 5% to 1,260,000';
  return query select 'and proposed once', erp.propose_renewals() = 0, 'no second proposal';
  select r.id into v_renewal from erp_meta.renewal r where r.contract_id = v_contract;

  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  v_q2 := erp.open_renewal_quote(v_renewal);
  res := erp.quote_margin(v_q2);
  return query select 'the platform organisation raises the renewal quote from the proposal, lines uplifted',
    v_q2 is not null and (res -> 'totals' ->> 'quoted_minor')::bigint = 1260000
    and (select r.status from erp_meta.renewal r where r.id = v_renewal) = 'quoted'
    and (select cq.customer_tenant_code from erp.commercial_quote cq where cq.document_id = v_q2) = v_ccode,
    'a quote like any other, at 1,260,000';

  perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
  begin
    perform erp.renew_contract(v_renewal, 'B. Customer', 'P. Owner', 'Agreement to renew');
    v_ok := false; v_msg := 'the contract renewed before the quote was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_QUOTE_NOT_ACCEPTED%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'the contract renews only on an accepted renewal quote', v_ok, v_msg;

  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  perform erp.submit_quote(v_q2);
  perform erp.issue_quote(v_q2);
  perform erp.quote_transition(v_q2, 'accept', 'renewal signed');
  perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
  perform erp.renew_contract(v_renewal, 'B. Customer', 'P. Owner', 'Agreement to renew on the uplifted order form');
  return query select 'renewal extends the term as a signed, provisioned amendment and schedules the next term''s invoices',
    (select c.current_term_end from erp_meta.contract c where c.id = v_contract) = ((current_date - 300) + interval '24 months')::date
    and (select c.annual_value_minor from erp_meta.contract c where c.id = v_contract) = 1260000
    and exists (select 1 from erp_meta.contract_amendment a where a.contract_id = v_contract and a.signed_at is not null and a.provisioned_at is not null and a.changes ? 'term_end')
    and (select s.term_end from erp_meta.subscription s where s.tenant_id = v_customer and s.status <> 'terminated') = ((current_date - 300) + interval '24 months')::date
    and (select count(*) from erp_meta.contract_invoice i where i.contract_id = v_contract) = 8
    and exists (select 1 from erp.event e where e.tenant_id = v_customer and e.event_type = 'commercial.contract_renewed'),
    'term to +24 months at 1,260,000; eight invoices in all';
  return query select 'the assertions pass over the renewed position',
    erp.assert_contract_provisions_entitlement() like 'contracts: 1 in force%' and erp.assert_customer_view_sound() is not null, 'D35 and D38';

  -- ── §17.10 revenue, derived from contracts ───────────────────────────────

  res := erp.revenue_report();
  return query select 'the revenue report is derived from the contracts',
    (res ->> 'arr_minor')::bigint = 1260000 and (res ->> 'mrr_minor')::bigint = 105000
    and (res -> 'by_plan' -> 0 ->> 'plan_code') = 'standard'
    and jsonb_array_length(res -> 'gross_margin') = 1
    and (res -> 'renewals_last_12_months' ->> 'accepted')::integer = 1
    and (res -> 'renewals_last_12_months' ->> 'renewal_rate_pct')::numeric = 100,
    format('ARR %s, MRR %s, renewal rate %s%%', res ->> 'arr_minor', res ->> 'mrr_minor', res -> 'renewals_last_12_months' ->> 'renewal_rate_pct');

  -- ── §17.10 non-renewal and the end of a term ─────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  update erp_meta.contract set current_term_start = current_date - 366, current_term_end = current_date - 1 where id = v_contract;
  v_n := erp.expire_contracts();
  return query select 'a term that ends without renewal expires the contract and moves the organisation to grace, told',
    v_n = 1 and (select c.status from erp_meta.contract c where c.id = v_contract) = 'expired'
    and (select s.status from erp_meta.subscription s where s.tenant_id = v_customer) = 'grace'
    and exists (select 1 from erp.event e where e.tenant_id = v_customer and e.event_type = 'commercial.term_ended'),
    'service continues; export stays available; restriction is an operator''s act';

  -- ── §17.4 sub-processors with notice ─────────────────────────────────────

  insert into erp_meta.sub_processor (code, name, purpose, location, added_at) values ('zzrn-host', 'Suite Host', 'hosting', 'EU', current_date);
  return query select 'a sub-processor added without notice is a finding',
    exists (select 1 from erp.customer_view_report() f where f.finding like 'a sub-processor was added without notice%' and f.reference = 'zzrn-host'), 'notice before addition';
  update erp_meta.sub_processor set notified_at = current_date - 30 where code = 'zzrn-host';
  return query select 'and notified ahead, it is listed to every organisation',
    not exists (select 1 from erp.customer_view_report() f where f.reference = 'zzrn-host'), 'listed';

  -- ── Clean up ──────────────────────────────────────────────────────────────

  delete from erp_meta.sub_processor where code = 'zzrn-host';
  delete from erp_meta.contract where id = v_contract;
  delete from erp_meta.subscription where tenant_id = v_customer;
  delete from erp_meta.usage_meter where tenant_id = v_customer;
  delete from erp_meta.platform_organisation where tenant_id = v_platform;
  perform erp.begin_tenant_purge(v_platform);
  delete from erp.tenant where id = v_platform;
  perform erp.end_tenant_purge();
  perform erp.begin_tenant_purge(v_customer);
  delete from erp.tenant where id = v_customer;
  perform erp.end_tenant_purge();
  delete from erp_meta.platform_staff where email like '%@zzrn.test';
  delete from auth.users where id in (ad, ow, ca);
  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant tn where tn.id in (v_platform, v_customer))
    and not exists (select 1 from erp_meta.contract_invoice i where i.tenant_id = v_customer)
    and not exists (select 1 from erp_meta.renewal r where r.contract_id = v_contract),
    'organisations, contract, invoices and renewal gone';
end;
$$;

-- The issued lines, read back for the identity check above. A helper so the
-- suite compares the row the platform wrote with the row the customer reads.
create or replace function erp_test.res_lines(p_invoice_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$ select i.lines from erp_meta.contract_invoice i where i.id = p_invoice_id $$;

create or replace function erp_test.assert_commercial_renewal_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _commercial_renewal_result on commit drop as
    select * from erp_test.commercial_renewal_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_total, v_passed, v_detail
    from _commercial_renewal_result;
  if v_passed < v_total then
    raise exception E'ERPWARE_COMMERCIAL_RENEWAL_SUITE_FAILED: %/%\n%', v_passed, v_total, v_detail
      using errcode = 'P0001';
  end if;
  return format('commercial renewal and customer view: %s/%s', v_passed, v_total);
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
select erp.assert_no_dead_configuration();
select erp.assert_diagnostics_registered();
select erp.assert_job_handlers_resolvable();
select erp.assert_contract_provisions_entitlement();
select erp.assert_customer_view_sound();
select erp.assert_product_decisions_enforced();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
select erp.assert_guidance_sound();
