-- =============================================================================
-- Part 17 §17.8 and §17.9: the contract record, and the contract that
-- provisions the entitlement
--
-- Specification v1.5 §17.9 calls this "the single most important mechanic in
-- this section":
--
--   "A signed contract provisions the entitlement in §17.1 directly. Plan,
--   capabilities, bands, support tier and term flow from the contract into
--   what the platform enforces. There is no path by which an organisation's
--   entitlement differs from its contract without a recorded amendment. Drift
--   between what was sold and what was provisioned is structurally impossible
--   rather than merely discouraged. Entitlement changes are dated from the
--   amendment's effective date. The contract is the source; the entitlement is
--   derived. Never the other way round."  (D35)
--
-- So the contract lives in the control plane (erp_meta, no foreign key to
-- erp.tenant, as every commercial record), it is created from an accepted
-- quote and nothing else, signing it is what writes erp_meta.subscription and
-- the entitlement rows, and the only writer of those rows after that is a
-- signed amendment. erp.entitlement_limit() and erp.require_capability_on_plan()
-- are re-emitted to read the contract's position first and the plan's second,
-- and erp.assert_contract_provisions_entitlement() fails the build if a
-- subscription ever disagrees with the contract that provisioned it.
--
-- §17.8: "Key dates are structured fields, not text buried in a PDF" — they
-- are columns and a derivation, and "every one of them raises a notification
-- on a configured lead time through Part 14": a sweep raises an event in the
-- customer's own organisation, which Part 15's routes carry to whoever the
-- organisation says should hear it.
-- =============================================================================

-- ── §17.8 the contract ───────────────────────────────────────────────────────

create table if not exists erp_meta.contract (
  id                    uuid primary key default gen_random_uuid(),
  -- The customer. No foreign key to erp.tenant: the record of what was agreed
  -- must outlive the organisation that agreed it.
  tenant_id             uuid not null,
  tenant_code           text not null,
  platform_tenant_id    uuid not null,
  quote_document_id     uuid not null,
  quote_number          text not null,
  quote_version         integer not null,
  customer_legal_name   text not null,
  platform_legal_name   text not null,
  plan_code             text not null references erp_meta.plan (code),
  support_severity_code text,
  term_kind             text not null,
  currency              char(3) not null,
  annual_value_minor    bigint not null default 0,
  billing_frequency     text not null default 'annual',
  commencement          date not null,
  initial_term_months   integer not null,
  current_term_start    date not null,
  current_term_end      date not null,
  renewal_kind          text not null default 'automatic',
  notice_days           integer not null default 90,
  governing_law         text not null,
  uplift_rule           jsonb not null default '{"kind": "none"}'::jsonb,
  termination_terms     jsonb not null default '{}'::jsonb,
  review_date           date,
  lead_days             integer not null default 30,
  status                text not null default 'draft',
  signed_at             timestamptz,
  terminated_at         timestamptz,
  termination_reason    text,
  created_at            timestamptz not null default now(),
  created_by            text not null,
  updated_at            timestamptz not null default now(),
  constraint contract_term_known check (term_kind in ('annual', 'multi_year', 'monthly')),
  constraint contract_frequency_known check (billing_frequency in ('annual', 'quarterly', 'monthly')),
  constraint contract_renewal_known check (renewal_kind in ('automatic', 'by_agreement', 'none')),
  constraint contract_status_known check (status in ('draft', 'active', 'terminating', 'terminated', 'expired')),
  constraint contract_term_positive check (initial_term_months > 0),
  constraint contract_term_ordered check (current_term_end > current_term_start),
  constraint contract_notice_sane check (notice_days >= 0 and lead_days >= 0),
  constraint contract_uplift_shape check (
    uplift_rule ->> 'kind' in ('none', 'fixed_pct', 'index', 'capped')
    and (uplift_rule ->> 'kind' <> 'fixed_pct' or (uplift_rule ->> 'pct') is not null)
    and (uplift_rule ->> 'kind' <> 'index' or (uplift_rule ->> 'index_code') is not null)
    and (uplift_rule ->> 'kind' <> 'capped' or ((uplift_rule ->> 'index_code') is not null and (uplift_rule ->> 'cap_pct') is not null))),
  constraint contract_terminated_has_reason check (terminated_at is null or coalesce(btrim(termination_reason), '') <> '')
);

create unique index if not exists contract_one_active_per_tenant
  on erp_meta.contract (tenant_id) where status in ('active', 'terminating');

comment on table erp_meta.contract is
  'Specification v1.5 §17.8: the agreement with an organisation — parties, '
  'commencement, initial term, renewal type, notice window, governing law — '
  'created from an accepted quote and nothing else. Key dates are columns and '
  'a derivation, never text in a PDF; the uplift clause is a rule, so a renewal '
  'price is calculated rather than negotiated from memory.';

create table if not exists erp_meta.contract_document (
  id                  uuid primary key default gen_random_uuid(),
  contract_id         uuid not null references erp_meta.contract (id) on delete cascade,
  kind                text not null,
  version             integer not null default 1,
  title               text not null,
  content             text not null,
  checksum            text not null,
  render_id           uuid,
  signed_at           timestamptz,
  signed_by_customer  text,
  signed_by_platform  text,
  signature_meaning   text,
  superseded_by       uuid,
  created_at          timestamptz not null default now(),
  constraint contract_document_kind_known check (kind in
    ('master_agreement', 'order_form', 'data_processing_agreement', 'service_level_terms', 'security_schedule', 'side_letter', 'amendment')),
  constraint contract_document_signed_by_both
    check (signed_at is null or (coalesce(btrim(signed_by_customer), '') <> '' and coalesce(btrim(signed_by_platform), '') <> '' and coalesce(btrim(signature_meaning), '') <> '')),
  constraint contract_document_once unique (contract_id, kind, version)
);

comment on table erp_meta.contract_document is
  'Specification v1.5 §17.8: the documents that constitute the agreement, '
  'versioned and signed — master agreement, order form, data processing '
  'agreement, service level terms, security schedule, side letters. A '
  'signature records both signers, its meaning (§9.3) and the checksum of what '
  'was signed; a new version supersedes rather than edits.';

create table if not exists erp_meta.contract_amendment (
  id                  uuid primary key default gen_random_uuid(),
  contract_id         uuid not null references erp_meta.contract (id) on delete cascade,
  seq                 integer not null,
  title               text not null,
  effective_from      date not null,
  changes             jsonb not null,
  rationale           text,
  signed_at           timestamptz,
  signed_by_customer  text,
  signed_by_platform  text,
  signature_meaning   text,
  provisioned_at      timestamptz,
  created_at          timestamptz not null default now(),
  created_by          text not null,
  constraint contract_amendment_once unique (contract_id, seq),
  constraint contract_amendment_signed_by_both
    check (signed_at is null or (coalesce(btrim(signed_by_customer), '') <> '' and coalesce(btrim(signed_by_platform), '') <> ''))
);

comment on table erp_meta.contract_amendment is
  'Specification v1.5 §17.8: "every change is an addendum with its own '
  'signature, never an edit to the original. The current position is derived '
  'from the original plus its amendments." A signed amendment is the only '
  'thing after signing that moves the entitlement, and it moves it from its '
  'effective date.';

create table if not exists erp_meta.contract_entitlement (
  id                uuid primary key default gen_random_uuid(),
  contract_id       uuid not null references erp_meta.contract (id) on delete cascade,
  amendment_id      uuid references erp_meta.contract_amendment (id) on delete cascade,
  entitlement_code  text not null references erp_meta.entitlement_kind (code),
  limit_value       numeric,
  effective_from    date not null,
  effective_to      date,
  constraint contract_entitlement_ordered check (effective_to is null or effective_to > effective_from)
);

create table if not exists erp_meta.contract_capability (
  id               uuid primary key default gen_random_uuid(),
  contract_id      uuid not null references erp_meta.contract (id) on delete cascade,
  amendment_id     uuid references erp_meta.contract_amendment (id) on delete cascade,
  capability_code  text not null references erp_ref.capability (code),
  effective_from   date not null,
  effective_to     date,
  constraint contract_capability_ordered check (effective_to is null or effective_to > effective_from)
);

comment on table erp_meta.contract_entitlement is
  'Specification v1.5 §17.9: the bands the contract sold, dated. Read ahead of '
  'the plan by erp.entitlement_limit(), so what is enforced is what was signed.';

create table if not exists erp_meta.contract_notice (
  id           uuid primary key default gen_random_uuid(),
  contract_id  uuid not null references erp_meta.contract (id) on delete cascade,
  kind         text not null,
  due_on       date not null,
  raised_at    timestamptz not null default now(),
  event_id     uuid,
  constraint contract_notice_kind_known check (kind in ('expiry', 'notice_deadline', 'uplift', 'review')),
  constraint contract_notice_once unique (contract_id, kind, due_on)
);

-- ── The events Part 15 routes ────────────────────────────────────────────────

insert into erp_ref.event_type
  (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current) values
('commercial.contract_signed', 1, 'tenant', 'administration', 'event.commercial.contract_signed',
 'The organisation''s contract was signed and its entitlement provisioned from it. §17.9.',
 '{"type":"object","required":["contract_id"],"properties":{"contract_id":{"type":"string"},"plan":{"type":"string"},"term_end":{"type":"string"}}}'::jsonb, true),
('commercial.contract_amended', 1, 'tenant', 'administration', 'event.commercial.contract_amended',
 'A signed amendment changed the organisation''s entitlement from its effective date. §17.9.',
 '{"type":"object","required":["contract_id","amendment_id"],"properties":{"contract_id":{"type":"string"},"amendment_id":{"type":"string"},"effective_from":{"type":"string"}}}'::jsonb, true),
('commercial.notice_deadline_announced', 1, 'tenant', 'administration', 'event.commercial.notice_deadline_announced',
 'The last day to give notice on the contract is within the configured lead time. §17.8.',
 '{"type":"object","required":["contract_id","due_on"],"properties":{"contract_id":{"type":"string"},"due_on":{"type":"string"},"days_left":{"type":"number"}}}'::jsonb, true),
('commercial.renewal_announced', 1, 'tenant', 'administration', 'event.commercial.renewal_announced',
 'The contract''s term ends within the configured lead time. §17.8.',
 '{"type":"object","required":["contract_id","due_on"],"properties":{"contract_id":{"type":"string"},"due_on":{"type":"string"},"days_left":{"type":"number"}}}'::jsonb, true),
('commercial.uplift_announced', 1, 'tenant', 'administration', 'event.commercial.uplift_announced',
 'The contract''s uplift date is within the configured lead time; the rule that will apply is on the contract. §17.8.',
 '{"type":"object","required":["contract_id","due_on"],"properties":{"contract_id":{"type":"string"},"due_on":{"type":"string"},"days_left":{"type":"number"},"uplift_rule":{"type":"object"}}}'::jsonb, true),
('commercial.review_announced', 1, 'tenant', 'administration', 'event.commercial.review_announced',
 'The contract''s review date is within the configured lead time. §17.8.',
 '{"type":"object","required":["contract_id","due_on"],"properties":{"contract_id":{"type":"string"},"due_on":{"type":"string"},"days_left":{"type":"number"}}}'::jsonb, true)
on conflict (code, version) do update set
  description = excluded.description, payload_schema = excluded.payload_schema, is_current = excluded.is_current;

-- ── §17.8 the key dates, derived ─────────────────────────────────────────────

create or replace function erp.contract_key_dates(p_contract_id uuid)
returns table(kind text, due_on date, days_left integer)
language sql
stable
security definer
set search_path = ''
as $$
  with c as (select * from erp_meta.contract where id = p_contract_id),
  anniversaries as (
    -- The uplift falls on each anniversary of commencement inside the term.
    select (c.commencement + make_interval(months => 12 * g))::date as due_on
      from c cross join generate_series(1, 30) g
     where c.uplift_rule ->> 'kind' <> 'none'
       and (c.commencement + make_interval(months => 12 * g))::date <= c.current_term_end),
  dates as (
    select 'expiry', c.current_term_end from c
    union all
    select 'notice_deadline', (c.current_term_end - c.notice_days)::date from c where c.renewal_kind <> 'none'
    union all
    select 'review', c.review_date from c where c.review_date is not null
    union all
    select 'uplift', a.due_on from anniversaries a)
  select d.kind, d.due_on, (d.due_on - current_date)::integer
    from dates d(kind, due_on)
   order by d.due_on, d.kind
$$;

comment on function erp.contract_key_dates is
  'Specification v1.5 §17.8: commencement, expiry, notice deadline, uplift and '
  'review as a derivation over structured fields, never text in a PDF.';

-- ── §17.9 the derivation: contract first, plan second ────────────────────────

create or replace function erp.entitlement_limit(p_code text, p_tenant_id uuid default null)
returns numeric
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := coalesce(p_tenant_id, erp.require_tenant_id());
  v_found  boolean; v_limit numeric;
begin
  -- §17.9: the contract is the source. A band the contract sold, in force
  -- today, is the limit — including a null band, which is unlimited by
  -- contract. Only where the contract is silent does the plan speak.
  select true, ce.limit_value into v_found, v_limit
    from erp_meta.contract_entitlement ce
    join erp_meta.contract c on c.id = ce.contract_id
   where c.tenant_id = v_tenant and c.status in ('active', 'terminating')
     and ce.entitlement_code = p_code
     and ce.effective_from <= current_date
     and (ce.effective_to is null or ce.effective_to > current_date)
   order by ce.effective_from desc
   limit 1;
  if coalesce(v_found, false) then
    return v_limit;
  end if;
  return (select pe.limit_value from erp_meta.plan_entitlement pe
           where pe.plan_code = erp.tenant_plan_code(v_tenant) and pe.entitlement_code = p_code);
end;
$$;

comment on function erp.entitlement_limit is
  'The limit in force: the contract''s band where one is in force (§17.9, D35), '
  'otherwise the plan''s figure, and null for unlimited either way — and null '
  'equally where the organisation has no subscription at all.';

create or replace function erp.require_capability_on_plan(p_code text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_plan   text := erp.tenant_plan_code();
begin
  if v_plan is null then
    return;      -- no subscription recorded: unmetered, as everywhere else here
  end if;

  -- On the plan, or sold as an add-on by the contract in force. §17.9: the
  -- contract is the source of what is available, the plan is what it started
  -- from.
  if exists (select 1 from erp_meta.plan_capability pc
              where pc.plan_code = v_plan and pc.capability_code = p_code)
     or exists (select 1 from erp_meta.contract_capability cc
                  join erp_meta.contract c on c.id = cc.contract_id
                 where c.tenant_id = v_tenant and c.status in ('active', 'terminating')
                   and cc.capability_code = p_code
                   and cc.effective_from <= current_date
                   and (cc.effective_to is null or cc.effective_to > current_date)) then
    return;
  end if;

  perform erp.append_event(
    'commercial.capability_refused', 'tenant', v_tenant,
    jsonb_build_object('capability', p_code, 'plan', v_plan));

  raise exception
    'ERPWARE_CAPABILITY_NOT_ON_PLAN: % is not available on the % plan or the contract', p_code, v_plan
    using errcode = '42501',
          hint = 'Raise the plan or add the feature to the contract by amendment. It is '
                 'refused rather than hidden, because a switch that silently '
                 'does nothing is worse than one that says why.';
end;
$$;

comment on function erp.require_capability_on_plan is
  'Specification v1.5 §17.9: refuses a feature neither the plan nor the '
  'contract in force provides. Silent where no subscription is recorded.';

create or replace function erp.provision_entitlement_from_contract(p_contract_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare c erp_meta.contract; v_sub uuid;
begin
  select * into c from erp_meta.contract where id = p_contract_id;
  if not found or c.status not in ('active', 'terminating') then
    raise exception 'ERPWARE_CONTRACT_NOT_IN_FORCE: % is %', p_contract_id, coalesce(c.status, 'unknown') using errcode = '23514';
  end if;
  -- §17.9: the subscription IS the contract's position, written by nothing
  -- else. One current subscription per organisation, so an earlier one is
  -- brought to the contract rather than joined by a second.
  update erp_meta.subscription s
     set plan_code = c.plan_code, term_start = c.current_term_start, term_end = c.current_term_end,
         renews = (c.renewal_kind = 'automatic'), currency = c.currency,
         note = 'contract ' || c.id::text, updated_at = now(),
         status = case when s.status in ('grace', 'restricted', 'suspended') then s.status else 'active' end
   where s.tenant_id = c.tenant_id and s.status <> 'terminated'
  returning s.id into v_sub;
  if v_sub is null then
    insert into erp_meta.subscription (tenant_id, tenant_code, plan_code, term_start, term_end, renews, currency, status, note)
    values (c.tenant_id, c.tenant_code, c.plan_code, c.current_term_start, c.current_term_end,
            c.renewal_kind = 'automatic', c.currency, 'active', 'contract ' || c.id::text)
    returning id into v_sub;
  end if;
  return v_sub;
end;
$$;

comment on function erp.provision_entitlement_from_contract is
  'Specification v1.5 §17.9, D35: writes erp_meta.subscription from the '
  'contract. Called by signing and by a signed amendment, and by nothing else; '
  'the assertion fails a subscription that disagrees with its contract.';

-- ── The writers ──────────────────────────────────────────────────────────────

create or replace function erp.create_contract_from_quote(
  p_quote_document_id uuid, p_customer_tenant_code text,
  p_customer_legal_name text, p_platform_legal_name text,
  p_commencement date, p_initial_term_months integer default 12,
  p_renewal_kind text default 'automatic', p_notice_days integer default 90,
  p_governing_law text default 'England and Wales', p_billing_frequency text default 'annual',
  p_uplift_rule jsonb default '{"kind": "none"}'::jsonb, p_termination_terms jsonb default '{}'::jsonb,
  p_review_date date default null, p_lead_days integer default 30)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff   erp_meta.platform_staff;
  v_platform uuid;
  v_tenant  erp.tenant%rowtype;
  q         erp.commercial_quote;
  d         erp.document%rowtype;
  v_state   text;
  m         jsonb; l jsonb;
  v_plan    text; v_severity text; v_annual bigint;
  v_id      uuid;
  v_render  erp.output_render%rowtype;
begin
  v_staff := erp_meta.require_platform('operator');
  select po.tenant_id into v_platform from erp_meta.platform_organisation po;
  if v_platform is null then
    raise exception 'ERPWARE_NO_PLATFORM_ORGANISATION: designate the platform''s organisation first' using errcode = '23503';
  end if;
  select * into v_tenant from erp.tenant t where t.code = p_customer_tenant_code;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_TENANT: % is not an organisation on this deployment', p_customer_tenant_code using errcode = '23503';
  end if;
  if v_tenant.id = v_platform then
    raise exception 'ERPWARE_PLATFORM_CANNOT_CONTRACT_WITH_ITSELF' using errcode = '23514';
  end if;
  if exists (select 1 from erp_meta.contract c where c.tenant_id = v_tenant.id and c.status in ('active', 'terminating')) then
    raise exception 'ERPWARE_CONTRACT_IN_FORCE: % already has a contract in force; change it by amendment', p_customer_tenant_code
      using errcode = '23514';
  end if;

  select cq.* into q from erp.commercial_quote cq where cq.tenant_id = v_platform and cq.document_id = p_quote_document_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_QUOTE: %', p_quote_document_id using errcode = '23503';
  end if;
  select * into d from erp.document x where x.id = p_quote_document_id;
  select s.code into v_state
    from erp.object_state os join erp.state s on s.id = os.current_state_id
   where os.tenant_id = v_platform and os.object_type = 'document' and os.object_id = p_quote_document_id;
  if v_state <> 'accepted' then
    raise exception 'ERPWARE_QUOTE_NOT_ACCEPTED: version % is %, and a contract is created from an accepted quote', q.version, v_state
      using errcode = '23514', hint = 'Issue the order form and accept the quote when it comes back signed.';
  end if;
  if q.order_form_render_id is null then
    raise exception 'ERPWARE_QUOTE_HAS_NO_ORDER_FORM' using errcode = '23514';
  end if;
  if p_renewal_kind not in ('automatic', 'by_agreement', 'none') or p_billing_frequency not in ('annual', 'quarterly', 'monthly') then
    raise exception 'ERPWARE_CONTRACT_TERMS_UNKNOWN: renewal % or billing %', p_renewal_kind, p_billing_frequency using errcode = '23514';
  end if;

  -- What the quote sold, read from the document lines in the platform
  -- organisation's own context so the margin reader scopes correctly.
  perform set_config('erp.job_tenant_id', v_platform::text, true);
  m := erp.quote_margin(p_quote_document_id);
  perform set_config('erp.job_tenant_id', '', true);

  select x ->> 'plan_code' into v_plan from jsonb_array_elements(m -> 'lines') x where x ->> 'kind' = 'plan_tier' limit 1;
  if v_plan is null then
    raise exception 'ERPWARE_QUOTE_HAS_NO_PLAN' using errcode = '23514';
  end if;
  select x ->> 'support_severity_code' into v_severity from jsonb_array_elements(m -> 'lines') x where x ->> 'kind' = 'support_tier' limit 1;
  v_annual := (m -> 'totals' ->> 'quoted_minor')::bigint * case q.term_kind when 'monthly' then 12 else 1 end;

  insert into erp_meta.contract
    (tenant_id, tenant_code, platform_tenant_id, quote_document_id, quote_number, quote_version,
     customer_legal_name, platform_legal_name, plan_code, support_severity_code, term_kind, currency,
     annual_value_minor, billing_frequency, commencement, initial_term_months,
     current_term_start, current_term_end, renewal_kind, notice_days, governing_law,
     uplift_rule, termination_terms, review_date, lead_days, created_by)
  values (v_tenant.id, v_tenant.code, v_platform, p_quote_document_id, d.document_number, q.version,
          p_customer_legal_name, p_platform_legal_name, v_plan, v_severity, q.term_kind, q.currency,
          v_annual, p_billing_frequency, p_commencement, p_initial_term_months,
          p_commencement, (p_commencement + make_interval(months => p_initial_term_months))::date,
          p_renewal_kind, p_notice_days, p_governing_law,
          coalesce(p_uplift_rule, '{"kind": "none"}'::jsonb), coalesce(p_termination_terms, '{}'::jsonb),
          p_review_date, p_lead_days, v_staff.email)
  returning id into v_id;

  -- The order form as issued, held against the contract with the checksum of
  -- what the customer saw.
  select * into v_render from erp.output_render o where o.tenant_id = v_platform and o.id = q.order_form_render_id;
  insert into erp_meta.contract_document (contract_id, kind, version, title, content, checksum, render_id)
  values (v_id, 'order_form', 1, 'Order form ' || d.document_number || ' v' || q.version, v_render.content, v_render.checksum, v_render.id);

  -- What was sold, as dated rows. Bands and features; the plan is on the
  -- contract itself.
  for l in select * from jsonb_array_elements(m -> 'lines') loop
    if l ->> 'entitlement_code' is not null then
      insert into erp_meta.contract_entitlement (contract_id, entitlement_code, limit_value, effective_from)
      values (v_id, l ->> 'entitlement_code', (l ->> 'band_to')::numeric, p_commencement);
    elsif l ->> 'kind' = 'capability_addon' then
      insert into erp_meta.contract_capability (contract_id, capability_code, effective_from)
      values (v_id, l ->> 'capability_code', p_commencement);
    end if;
  end loop;

  perform erp_meta.platform_log(
    v_staff, 'platform.contract_created', v_tenant.id, v_id::text,
    format('from quote %s v%s', d.document_number, q.version),
    jsonb_build_object('plan', v_plan, 'annual_value_minor', v_annual, 'commencement', p_commencement));
  return v_id;
end;
$$;

comment on function erp.create_contract_from_quote is
  'Specification v1.5 §17.8 and §17.9: a contract is created from an accepted '
  'quote and nothing else, carrying the plan, bands, features, support tier and '
  'term the quote sold, and the order form as issued with its checksum. '
  'Operator or owner; recorded in the platform log.';

create or replace function erp.attach_contract_document(p_contract_id uuid, p_kind text, p_title text, p_content text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare v_staff erp_meta.platform_staff; v_version integer; v_id uuid; v_prev uuid;
begin
  v_staff := erp_meta.require_platform('operator');
  if not exists (select 1 from erp_meta.contract c where c.id = p_contract_id) then
    raise exception 'ERPWARE_UNKNOWN_CONTRACT: %', p_contract_id using errcode = '23503';
  end if;
  if coalesce(btrim(p_content), '') = '' then
    raise exception 'ERPWARE_DOCUMENT_IS_EMPTY: a contract document carries its text' using errcode = '23514';
  end if;
  select max(d.version), (array_agg(d.id order by d.version desc))[1] into v_version, v_prev
    from erp_meta.contract_document d where d.contract_id = p_contract_id and d.kind = p_kind;
  insert into erp_meta.contract_document (contract_id, kind, version, title, content, checksum)
  values (p_contract_id, p_kind, coalesce(v_version, 0) + 1, p_title, p_content, md5(p_content))
  returning id into v_id;
  if v_prev is not null then
    update erp_meta.contract_document set superseded_by = v_id where id = v_prev;
  end if;
  perform erp_meta.platform_log(v_staff, 'platform.contract_document_attached', null, p_contract_id::text,
                                format('%s v%s', p_kind, coalesce(v_version, 0) + 1), '{}'::jsonb);
  return v_id;
end;
$$;

create or replace function erp.sign_contract(p_contract_id uuid, p_customer_signer text, p_platform_signer text, p_signature_meaning text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare v_staff erp_meta.platform_staff; c erp_meta.contract; v_sub uuid;
begin
  v_staff := erp_meta.require_platform('operator');
  select * into c from erp_meta.contract where id = p_contract_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_CONTRACT: %', p_contract_id using errcode = '23503';
  end if;
  if c.status <> 'draft' then
    raise exception 'ERPWARE_CONTRACT_ALREADY_SIGNED: % is %', p_contract_id, c.status using errcode = '23514';
  end if;
  if coalesce(btrim(p_customer_signer), '') = '' or coalesce(btrim(p_platform_signer), '') = '' or coalesce(btrim(p_signature_meaning), '') = '' then
    raise exception 'ERPWARE_SIGNATURE_INCOMPLETE: a signature names both signers and what signing means (§9.3)' using errcode = '23514';
  end if;
  if not exists (select 1 from erp_meta.contract_document d where d.contract_id = p_contract_id and d.kind = 'order_form') then
    raise exception 'ERPWARE_CONTRACT_HAS_NO_ORDER_FORM' using errcode = '23514';
  end if;

  -- §9.3: meaning captured, both parties, manifestation on the record — the
  -- checksum of each document signed is on the row it was signed on.
  update erp_meta.contract_document
     set signed_at = now(), signed_by_customer = btrim(p_customer_signer),
         signed_by_platform = btrim(p_platform_signer), signature_meaning = btrim(p_signature_meaning)
   where contract_id = p_contract_id and superseded_by is null and signed_at is null;

  update erp_meta.contract set status = 'active', signed_at = now(), updated_at = now() where id = p_contract_id;

  -- §17.9: signing provisions. The subscription is written from the contract
  -- here and by amendment, and by nothing else.
  v_sub := erp.provision_entitlement_from_contract(p_contract_id);

  perform set_config('erp.job_tenant_id', c.tenant_id::text, true);
  perform erp.append_event('commercial.contract_signed', 'tenant', c.tenant_id,
    jsonb_build_object('contract_id', c.id, 'plan', c.plan_code, 'term_end', c.current_term_end));
  perform set_config('erp.job_tenant_id', '', true);

  perform erp_meta.platform_log(v_staff, 'platform.contract_signed', c.tenant_id, c.id::text,
                                format('signed by %s and %s: %s', p_customer_signer, p_platform_signer, p_signature_meaning),
                                jsonb_build_object('subscription_id', v_sub, 'plan', c.plan_code));
  return v_sub;
end;
$$;

comment on function erp.sign_contract is
  'Specification v1.5 §17.9: "a signed contract provisions the entitlement '
  'directly". Records both signatures with their meaning on every unsigned '
  'document, activates the contract, writes the subscription from it and '
  'raises the event in the customer''s organisation.';

create or replace function erp.amend_contract(p_contract_id uuid, p_title text, p_effective_from date, p_changes jsonb, p_rationale text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare v_staff erp_meta.platform_staff; c erp_meta.contract; v_seq integer; v_id uuid; x jsonb;
begin
  v_staff := erp_meta.require_platform('operator');
  select * into c from erp_meta.contract where id = p_contract_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_CONTRACT: %', p_contract_id using errcode = '23503';
  end if;
  if c.status not in ('active', 'terminating') then
    raise exception 'ERPWARE_CONTRACT_NOT_IN_FORCE: % is %; only a contract in force is amended', p_contract_id, c.status using errcode = '23514';
  end if;
  if p_changes is null or p_changes = '{}'::jsonb then
    raise exception 'ERPWARE_AMENDMENT_CHANGES_NOTHING' using errcode = '23514';
  end if;
  -- Everything an amendment may say is validated before it is recorded: an
  -- amendment naming a plan or a band the product does not have would be
  -- signed and then fail to provision, which is the drift D35 forbids.
  if p_changes ? 'plan_code' and not exists (select 1 from erp_meta.plan p where p.code = p_changes ->> 'plan_code') then
    raise exception 'ERPWARE_UNKNOWN_PLAN: %', p_changes ->> 'plan_code' using errcode = '23503';
  end if;
  for x in select * from jsonb_array_elements(coalesce(p_changes -> 'entitlements', '[]'::jsonb)) loop
    if not exists (select 1 from erp_meta.entitlement_kind k where k.code = x ->> 'code') then
      raise exception 'ERPWARE_UNKNOWN_ENTITLEMENT: %', x ->> 'code' using errcode = '23503';
    end if;
  end loop;
  for x in select * from jsonb_array_elements(coalesce(p_changes -> 'capabilities', '[]'::jsonb)) loop
    if not exists (select 1 from erp_ref.capability k where k.code = x ->> 'code') then
      raise exception 'ERPWARE_UNKNOWN_CAPABILITY: %', x ->> 'code' using errcode = '23503';
    end if;
    if coalesce(x ->> 'action', 'add') not in ('add', 'remove') then
      raise exception 'ERPWARE_AMENDMENT_ACTION_UNKNOWN: %', x ->> 'action' using errcode = '23514';
    end if;
  end loop;
  if p_changes ? 'term_end' and (p_changes ->> 'term_end')::date <= c.current_term_start then
    raise exception 'ERPWARE_AMENDMENT_TERM_ENDS_BEFORE_IT_STARTS' using errcode = '23514';
  end if;

  select coalesce(max(a.seq), 0) + 1 into v_seq from erp_meta.contract_amendment a where a.contract_id = p_contract_id;
  insert into erp_meta.contract_amendment (contract_id, seq, title, effective_from, changes, rationale, created_by)
  values (p_contract_id, v_seq, p_title, p_effective_from, p_changes, p_rationale, v_staff.email)
  returning id into v_id;
  perform erp_meta.platform_log(v_staff, 'platform.contract_amendment_drafted', c.tenant_id, c.id::text,
                                format('amendment %s: %s', v_seq, p_title), p_changes);
  return v_id;
end;
$$;

create or replace function erp.sign_amendment(p_amendment_id uuid, p_customer_signer text, p_platform_signer text, p_signature_meaning text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare v_staff erp_meta.platform_staff; a erp_meta.contract_amendment; c erp_meta.contract; x jsonb; v_sub uuid;
begin
  v_staff := erp_meta.require_platform('operator');
  select * into a from erp_meta.contract_amendment where id = p_amendment_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_AMENDMENT: %', p_amendment_id using errcode = '23503';
  end if;
  if a.signed_at is not null then
    raise exception 'ERPWARE_AMENDMENT_ALREADY_SIGNED' using errcode = '23514';
  end if;
  if coalesce(btrim(p_customer_signer), '') = '' or coalesce(btrim(p_platform_signer), '') = '' or coalesce(btrim(p_signature_meaning), '') = '' then
    raise exception 'ERPWARE_SIGNATURE_INCOMPLETE: a signature names both signers and what signing means (§9.3)' using errcode = '23514';
  end if;
  select * into c from erp_meta.contract where id = a.contract_id;

  update erp_meta.contract_amendment
     set signed_at = now(), signed_by_customer = btrim(p_customer_signer),
         signed_by_platform = btrim(p_platform_signer), signature_meaning = btrim(p_signature_meaning)
   where id = p_amendment_id;
  -- An addendum, held with the documents.
  insert into erp_meta.contract_document (contract_id, kind, version, title, content, checksum, signed_at, signed_by_customer, signed_by_platform, signature_meaning)
  values (a.contract_id, 'amendment', a.seq, a.title, a.changes::text, md5(a.changes::text), now(), btrim(p_customer_signer), btrim(p_platform_signer), btrim(p_signature_meaning));

  -- §17.9: "entitlement changes are dated from the amendment's effective
  -- date". Each band closes the one before it and opens from that date.
  for x in select * from jsonb_array_elements(coalesce(a.changes -> 'entitlements', '[]'::jsonb)) loop
    update erp_meta.contract_entitlement ce set effective_to = a.effective_from
     where ce.contract_id = a.contract_id and ce.entitlement_code = x ->> 'code'
       and ce.effective_to is null and ce.effective_from < a.effective_from;
    delete from erp_meta.contract_entitlement ce
     where ce.contract_id = a.contract_id and ce.entitlement_code = x ->> 'code' and ce.effective_from = a.effective_from;
    insert into erp_meta.contract_entitlement (contract_id, amendment_id, entitlement_code, limit_value, effective_from)
    values (a.contract_id, a.id, x ->> 'code', (x ->> 'limit_value')::numeric, a.effective_from);
  end loop;
  for x in select * from jsonb_array_elements(coalesce(a.changes -> 'capabilities', '[]'::jsonb)) loop
    if coalesce(x ->> 'action', 'add') = 'remove' then
      update erp_meta.contract_capability cc set effective_to = a.effective_from
       where cc.contract_id = a.contract_id and cc.capability_code = x ->> 'code' and cc.effective_to is null;
    else
      insert into erp_meta.contract_capability (contract_id, amendment_id, capability_code, effective_from)
      values (a.contract_id, a.id, x ->> 'code', a.effective_from);
    end if;
  end loop;
  update erp_meta.contract
     set plan_code = coalesce(a.changes ->> 'plan_code', plan_code),
         current_term_end = coalesce((a.changes ->> 'term_end')::date, current_term_end),
         annual_value_minor = coalesce((a.changes ->> 'annual_value_minor')::bigint, annual_value_minor),
         renewal_kind = coalesce(a.changes ->> 'renewal_kind', renewal_kind),
         notice_days = coalesce((a.changes ->> 'notice_days')::integer, notice_days),
         uplift_rule = coalesce(a.changes -> 'uplift_rule', uplift_rule),
         support_severity_code = coalesce(a.changes ->> 'support_severity_code', support_severity_code),
         updated_at = now()
   where id = a.contract_id;

  v_sub := erp.provision_entitlement_from_contract(a.contract_id);
  update erp_meta.contract_amendment set provisioned_at = now() where id = p_amendment_id;

  perform set_config('erp.job_tenant_id', c.tenant_id::text, true);
  perform erp.append_event('commercial.contract_amended', 'tenant', c.tenant_id,
    jsonb_build_object('contract_id', c.id, 'amendment_id', a.id, 'effective_from', a.effective_from));
  perform set_config('erp.job_tenant_id', '', true);

  perform erp_meta.platform_log(v_staff, 'platform.contract_amended', c.tenant_id, c.id::text,
                                format('amendment %s signed: %s', a.seq, a.title), a.changes);
  return v_sub;
end;
$$;

comment on function erp.sign_amendment is
  'Specification v1.5 §17.9: a signed amendment is the one path by which an '
  'entitlement changes after signing. Dated from its effective date, held as '
  'an addendum with both signatures, and provisioned in the same transaction.';

-- ── §17.8 the notifications, on a lead time, through Part 14 ────────────────

create or replace function erp.raise_contract_key_dates()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare c record; k record; v_event uuid; v_raised integer := 0;
begin
  if not erp.session_is_trusted() then
    raise exception
      'ERPWARE_UNTRUSTED_SWEEP: this runs across every organisation, so it needs '
      'a session whose role bypasses row-level security; % does not', current_user
      using errcode = '42501';
  end if;
  for c in select * from erp_meta.contract where status in ('active', 'terminating') order by tenant_code loop
    perform set_config('erp.job_tenant_id', c.tenant_id::text, true);
    for k in select * from erp.contract_key_dates(c.id) d
              where d.due_on >= current_date - 1 and d.days_left <= c.lead_days
                and not exists (select 1 from erp_meta.contract_notice n where n.contract_id = c.id and n.kind = d.kind and n.due_on = d.due_on)
    loop
      v_event := erp.append_event(
        'commercial.' || case k.kind when 'expiry' then 'renewal' else k.kind end || '_announced', 'tenant', c.tenant_id,
        jsonb_strip_nulls(jsonb_build_object('contract_id', c.id, 'due_on', k.due_on, 'days_left', k.days_left,
                                             'uplift_rule', case when k.kind = 'uplift' then c.uplift_rule end)));
      insert into erp_meta.contract_notice (contract_id, kind, due_on, event_id) values (c.id, k.kind, k.due_on, v_event);
      v_raised := v_raised + 1;
    end loop;
  end loop;
  perform set_config('erp.job_tenant_id', '', true);
  return v_raised;
end;
$$;

comment on function erp.raise_contract_key_dates is
  'Specification v1.5 §17.8: "every one of them raises a notification on a '
  'configured lead time through Part 14". Raises the event once per key date '
  'in the customer''s own organisation, where Part 15''s routes carry it to '
  'whoever that organisation says should hear it.';

insert into erp_ref.job_handler
  (code, name_key, description, module_code, parameter_schema, default_timeout_seconds, forbids_overlap, is_current, sql_function)
values
  ('commercial.raise_contract_key_dates', 'job_handler.raise_contract_key_dates.name',
   'Raises the notice-deadline, renewal, uplift and review notifications for every contract in force, each once, on the contract''s lead time. §17.8.',
   null, '{"type": "object", "additionalProperties": false}'::jsonb, 300, true, true, 'raise_contract_key_dates')
on conflict (code) do update set
  description = excluded.description, sql_function = excluded.sql_function, is_current = excluded.is_current;

-- ── Reading a contract ───────────────────────────────────────────────────────

create or replace function erp.contract_position(p_contract_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', c.id, 'tenant_code', c.tenant_code, 'status', c.status,
    'customer_legal_name', c.customer_legal_name, 'platform_legal_name', c.platform_legal_name,
    'quote_number', c.quote_number, 'quote_version', c.quote_version,
    'plan_code', c.plan_code, 'plan_name', (select p.name from erp_meta.plan p where p.code = c.plan_code),
    'support_severity_code', c.support_severity_code,
    'term_kind', c.term_kind, 'currency', c.currency, 'annual_value_minor', c.annual_value_minor,
    'billing_frequency', c.billing_frequency,
    'commencement', c.commencement, 'initial_term_months', c.initial_term_months,
    'current_term_start', c.current_term_start, 'current_term_end', c.current_term_end,
    'renewal_kind', c.renewal_kind, 'notice_days', c.notice_days, 'governing_law', c.governing_law,
    'uplift_rule', c.uplift_rule, 'termination_terms', c.termination_terms, 'review_date', c.review_date,
    'lead_days', c.lead_days, 'signed_at', c.signed_at, 'terminated_at', c.terminated_at, 'termination_reason', c.termination_reason,
    'key_dates', coalesce((select jsonb_agg(jsonb_build_object('kind', d.kind, 'due_on', d.due_on, 'days_left', d.days_left) order by d.due_on)
                             from erp.contract_key_dates(c.id) d), '[]'::jsonb),
    'entitlements', coalesce((select jsonb_agg(jsonb_build_object(
                                'entitlement_code', ce.entitlement_code, 'title', k.title, 'unit', k.unit,
                                'limit_value', ce.limit_value, 'effective_from', ce.effective_from, 'effective_to', ce.effective_to,
                                'amendment_id', ce.amendment_id,
                                'in_force', ce.effective_from <= current_date and (ce.effective_to is null or ce.effective_to > current_date))
                              order by ce.entitlement_code, ce.effective_from)
                        from erp_meta.contract_entitlement ce left join erp_meta.entitlement_kind k on k.code = ce.entitlement_code
                       where ce.contract_id = c.id), '[]'::jsonb),
    'capabilities', coalesce((select jsonb_agg(jsonb_build_object(
                                'capability_code', cc.capability_code, 'effective_from', cc.effective_from, 'effective_to', cc.effective_to,
                                'amendment_id', cc.amendment_id,
                                'in_force', cc.effective_from <= current_date and (cc.effective_to is null or cc.effective_to > current_date))
                              order by cc.capability_code, cc.effective_from)
                        from erp_meta.contract_capability cc where cc.contract_id = c.id), '[]'::jsonb),
    'documents', coalesce((select jsonb_agg(jsonb_build_object(
                             'id', d.id, 'kind', d.kind, 'version', d.version, 'title', d.title, 'checksum', d.checksum,
                             'signed_at', d.signed_at, 'signed_by_customer', d.signed_by_customer, 'signed_by_platform', d.signed_by_platform,
                             'signature_meaning', d.signature_meaning, 'superseded_by', d.superseded_by, 'created_at', d.created_at,
                             'byte_size', octet_length(d.content))
                           order by d.kind, d.version)
                     from erp_meta.contract_document d where d.contract_id = c.id), '[]'::jsonb),
    'amendments', coalesce((select jsonb_agg(jsonb_build_object(
                              'id', a.id, 'seq', a.seq, 'title', a.title, 'effective_from', a.effective_from, 'changes', a.changes,
                              'rationale', a.rationale, 'signed_at', a.signed_at, 'signed_by_customer', a.signed_by_customer,
                              'signed_by_platform', a.signed_by_platform, 'provisioned_at', a.provisioned_at, 'created_at', a.created_at)
                            order by a.seq)
                      from erp_meta.contract_amendment a where a.contract_id = c.id), '[]'::jsonb),
    'subscription', (select jsonb_build_object('id', s.id, 'plan_code', s.plan_code, 'term_start', s.term_start, 'term_end', s.term_end,
                                               'renews', s.renews, 'status', s.status)
                       from erp_meta.subscription s where s.tenant_id = c.tenant_id and s.status <> 'terminated' limit 1),
    'notices', coalesce((select jsonb_agg(jsonb_build_object('kind', n.kind, 'due_on', n.due_on, 'raised_at', n.raised_at) order by n.due_on)
                           from erp_meta.contract_notice n where n.contract_id = c.id), '[]'::jsonb))
    from erp_meta.contract c where c.id = p_contract_id
$$;

-- ── The findings and the assertion (D35) ─────────────────────────────────────

create or replace function erp.contract_provisioning_report()
returns table(finding text, reference text, detail text)
language sql
stable
security definer
set search_path = ''
as $$
  -- D35: a contract in force whose organisation has no subscription, or a
  -- subscription that disagrees with its contract. Either is drift.
  select 'a contract in force has provisioned no subscription', c.tenant_code, c.id::text
    from erp_meta.contract c
   where c.status in ('active', 'terminating')
     and not exists (select 1 from erp_meta.subscription s where s.tenant_id = c.tenant_id and s.status <> 'terminated')
  union all
  select 'the subscription disagrees with the contract that provisioned it', c.tenant_code,
         format('subscription %s %s→%s, contract %s %s→%s', s.plan_code, s.term_start, s.term_end, c.plan_code, c.current_term_start, c.current_term_end)
    from erp_meta.contract c
    join erp_meta.subscription s on s.tenant_id = c.tenant_id and s.status <> 'terminated'
   where c.status in ('active', 'terminating')
     and (s.plan_code <> c.plan_code or s.term_start <> c.current_term_start or s.term_end is distinct from c.current_term_end
          or s.renews <> (c.renewal_kind = 'automatic'))
  union all
  -- An amendment signed but not provisioned is a change agreed and not made.
  select 'a signed amendment has not been provisioned', c.tenant_code, format('amendment %s', a.seq)
    from erp_meta.contract_amendment a join erp_meta.contract c on c.id = a.contract_id
   where a.signed_at is not null and a.provisioned_at is null
  union all
  -- A contract in force with no signed document is a provisioning nobody agreed to.
  select 'a contract in force has no signed document', c.tenant_code, c.id::text
    from erp_meta.contract c
   where c.status in ('active', 'terminating')
     and not exists (select 1 from erp_meta.contract_document d where d.contract_id = c.id and d.signed_at is not null)
  order by 1, 2
$$;

create or replace function erp.assert_contract_provisions_entitlement()
returns text
language plpgsql
set search_path = ''
as $$
declare v_count integer; v_detail text; v_active integer;
begin
  select count(*), string_agg(format('  %s — %s: %s', finding, reference, detail), E'\n')
    into v_count, v_detail from erp.contract_provisioning_report();
  if v_count > 0 then
    raise exception 'ERPWARE_CONTRACT_DRIFT: % finding(s)', v_count
      using errcode = 'P0001', detail = v_detail,
            hint = 'D35: the contract provisions the entitlement, never the reverse. Re-provision from the contract; do not edit the subscription.';
  end if;
  select count(*) into v_active from erp_meta.contract where status in ('active', 'terminating');
  return format('contracts: %s in force, each provisioning its subscription', v_active);
end;
$$;

-- ── The doors ────────────────────────────────────────────────────────────────

create or replace function public.erp_platform_create_contract(
  p_quote_document_id uuid, p_customer_tenant_code text, p_customer_legal_name text, p_platform_legal_name text,
  p_commencement date, p_initial_term_months integer default 12, p_renewal_kind text default 'automatic',
  p_notice_days integer default 90, p_governing_law text default 'England and Wales', p_billing_frequency text default 'annual',
  p_uplift_rule jsonb default '{"kind": "none"}'::jsonb, p_termination_terms jsonb default '{}'::jsonb,
  p_review_date date default null, p_lead_days integer default 30)
returns uuid language sql set search_path = '' as $$
  select erp.create_contract_from_quote(p_quote_document_id, p_customer_tenant_code, p_customer_legal_name, p_platform_legal_name,
                                        p_commencement, p_initial_term_months, p_renewal_kind, p_notice_days, p_governing_law,
                                        p_billing_frequency, p_uplift_rule, p_termination_terms, p_review_date, p_lead_days);
$$;

create or replace function public.erp_platform_attach_contract_document(p_contract_id uuid, p_kind text, p_title text, p_content text)
returns uuid language sql set search_path = '' as $$ select erp.attach_contract_document(p_contract_id, p_kind, p_title, p_content); $$;

create or replace function public.erp_platform_sign_contract(p_contract_id uuid, p_customer_signer text, p_platform_signer text, p_signature_meaning text)
returns uuid language sql set search_path = '' as $$ select erp.sign_contract(p_contract_id, p_customer_signer, p_platform_signer, p_signature_meaning); $$;

create or replace function public.erp_platform_amend_contract(p_contract_id uuid, p_title text, p_effective_from date, p_changes jsonb, p_rationale text default null)
returns uuid language sql set search_path = '' as $$ select erp.amend_contract(p_contract_id, p_title, p_effective_from, p_changes, p_rationale); $$;

create or replace function public.erp_platform_sign_amendment(p_amendment_id uuid, p_customer_signer text, p_platform_signer text, p_signature_meaning text)
returns uuid language sql set search_path = '' as $$ select erp.sign_amendment(p_amendment_id, p_customer_signer, p_platform_signer, p_signature_meaning); $$;

create or replace function public.erp_platform_contracts()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v erp_meta.platform_staff;
begin
  v := erp_meta.require_platform('support');
  return jsonb_build_object(
    'contracts', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c.id, 'tenant_code', c.tenant_code, 'customer_legal_name', c.customer_legal_name,
               'status', c.status, 'plan_code', c.plan_code, 'currency', c.currency,
               'annual_value_minor', c.annual_value_minor, 'term_kind', c.term_kind,
               'commencement', c.commencement, 'current_term_end', c.current_term_end,
               'renewal_kind', c.renewal_kind, 'notice_days', c.notice_days,
               'notice_deadline', (select d.due_on from erp.contract_key_dates(c.id) d where d.kind = 'notice_deadline'),
               'quote_number', c.quote_number, 'quote_version', c.quote_version, 'signed_at', c.signed_at,
               'amendments', (select count(*) from erp_meta.contract_amendment a where a.contract_id = c.id),
               'unsigned_amendments', (select count(*) from erp_meta.contract_amendment a where a.contract_id = c.id and a.signed_at is null))
             order by c.status, c.tenant_code)
        from erp_meta.contract c), '[]'::jsonb),
    'accepted_quotes', coalesce((
      select jsonb_agg(jsonb_build_object('document_id', cq.document_id, 'document_number', d.document_number,
                                          'version', cq.version, 'customer_tenant_code', cq.customer_tenant_code,
                                          'party_name', p.name, 'currency', cq.currency, 'term_kind', cq.term_kind)
                       order by d.document_number desc)
        from erp.commercial_quote cq
        join erp.document d on d.tenant_id = cq.tenant_id and d.id = cq.document_id
        left join erp.party p on p.tenant_id = d.tenant_id and p.id = d.party_id
        join erp.object_state os on os.tenant_id = cq.tenant_id and os.object_type = 'document' and os.object_id = cq.document_id
        join erp.state s on s.id = os.current_state_id
       where cq.tenant_id = (select po.tenant_id from erp_meta.platform_organisation po)
         and s.code = 'accepted'
         and not exists (select 1 from erp_meta.contract c where c.quote_document_id = cq.document_id)), '[]'::jsonb),
    'organisations', coalesce((select jsonb_agg(jsonb_build_object('code', t.code, 'name', t.name) order by t.code)
                                 from erp.tenant t where t.status::text in ('active', 'grace', 'restricted')
                                  and t.id <> coalesce((select po.tenant_id from erp_meta.platform_organisation po), '00000000-0000-0000-0000-000000000000'::uuid)), '[]'::jsonb),
    'findings', coalesce((select jsonb_agg(jsonb_build_object('finding', f.finding, 'reference', f.reference, 'detail', f.detail))
                            from erp.contract_provisioning_report() f), '[]'::jsonb));
end;
$$;

create or replace function public.erp_platform_contract(p_contract_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v erp_meta.platform_staff;
begin
  v := erp_meta.require_platform('support');
  return erp.contract_position(p_contract_id);
end;
$$;

create or replace function public.erp_platform_contract_document(p_document_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v erp_meta.platform_staff;
begin
  v := erp_meta.require_platform('support');
  return (select jsonb_build_object('id', d.id, 'kind', d.kind, 'version', d.version, 'title', d.title,
                                    'content', d.content, 'checksum', d.checksum, 'signed_at', d.signed_at)
            from erp_meta.contract_document d where d.id = p_document_id);
end;
$$;

revoke all on function
  public.erp_platform_create_contract(uuid, text, text, text, date, integer, text, integer, text, text, jsonb, jsonb, date, integer),
  public.erp_platform_attach_contract_document(uuid, text, text, text),
  public.erp_platform_sign_contract(uuid, text, text, text),
  public.erp_platform_amend_contract(uuid, text, date, jsonb, text),
  public.erp_platform_sign_amendment(uuid, text, text, text),
  public.erp_platform_contracts(),
  public.erp_platform_contract(uuid),
  public.erp_platform_contract_document(uuid)
  from public, anon;

grant execute on function
  public.erp_platform_create_contract(uuid, text, text, text, date, integer, text, integer, text, text, jsonb, jsonb, date, integer),
  public.erp_platform_attach_contract_document(uuid, text, text, text),
  public.erp_platform_sign_contract(uuid, text, text, text),
  public.erp_platform_amend_contract(uuid, text, date, jsonb, text),
  public.erp_platform_sign_amendment(uuid, text, text, text),
  public.erp_platform_contracts(),
  public.erp_platform_contract(uuid),
  public.erp_platform_contract_document(uuid)
  to authenticated, service_role;

-- ── Registration ─────────────────────────────────────────────────────────────

insert into erp_meta.table_policy (schema_name, table_name, table_class, note) values
  ('erp_meta','contract','platform_internal','Part 17 §17.8. The agreement with an organisation; outlives a purge by design.'),
  ('erp_meta','contract_document','platform_internal','Part 17 §17.8. The documents that constitute it, versioned and signed with their checksums.'),
  ('erp_meta','contract_amendment','platform_internal','Part 17 §17.8. Every change as an addendum with its own signature.'),
  ('erp_meta','contract_entitlement','platform_internal','Part 17 §17.9. The bands the contract sold, dated; read ahead of the plan.'),
  ('erp_meta','contract_capability','platform_internal','Part 17 §17.9. The features the contract sold, dated; read alongside the plan.'),
  ('erp_meta','contract_notice','platform_internal','Part 17 §17.8. Which key-date notifications have been raised, so each is raised once.')
on conflict (schema_name, table_name) do nothing;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_platform_create_contract', 'erp.create_contract_from_quote',
   'Creates a contract from an accepted quote. Gated by erp_meta.require_platform at operator; recorded in the platform log.'),
  ('erp_platform_attach_contract_document', 'erp.attach_contract_document',
   'Holds a document against a contract as a new version with its checksum. Operator.'),
  ('erp_platform_sign_contract', 'erp.sign_contract',
   'Records both signatures with their meaning and provisions the subscription from the contract. Operator.'),
  ('erp_platform_amend_contract', 'erp.amend_contract',
   'Drafts an amendment, validated against the plans, entitlements and features the product has. Operator.'),
  ('erp_platform_sign_amendment', 'erp.sign_amendment',
   'Signs an amendment and provisions its changes from its effective date. Operator.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp', 'contract_key_dates', 'Reads erp_meta.contract to derive its dates. Platform-internal table; used by the sweep and the console.'),
  ('erp', 'provision_entitlement_from_contract', 'Writes erp_meta.subscription from erp_meta.contract. Called only by signing and by a signed amendment, both gated at operator.'),
  ('erp', 'create_contract_from_quote', 'Reads the platform organisation''s accepted quote across the tenant boundary and writes erp_meta.contract. Gated by erp_meta.require_platform(''operator'') on the first line.'),
  ('erp', 'attach_contract_document', 'Writes erp_meta.contract_document. Operator.'),
  ('erp', 'sign_contract', 'Writes signatures, activates the contract, provisions the subscription and raises the event in the customer''s organisation. Operator.'),
  ('erp', 'amend_contract', 'Writes erp_meta.contract_amendment after validating what it names. Operator.'),
  ('erp', 'sign_amendment', 'Signs and provisions an amendment. Operator.'),
  ('erp', 'raise_contract_key_dates', 'Sweeps every contract in force and raises events in each customer''s organisation; refuses any session whose role does not already bypass row-level security.'),
  ('erp', 'contract_position', 'Reads one contract and its position. Called only through platform doors gated at support, and through the customer''s own door in the next migration, scoped to its own organisation.'),
  ('erp', 'contract_provisioning_report', 'Reads erp_meta.contract and erp_meta.subscription to find drift between them. Names organisations by code only.'),
  ('public', 'erp_platform_contracts', 'Platform console read of every contract. Gated by erp_meta.require_platform(''support'') on its first line.'),
  ('public', 'erp_platform_contract', 'Platform console read of one contract. Gated by erp_meta.require_platform(''support'').'),
  ('public', 'erp_platform_contract_document', 'Platform console read of one contract document''s text. Gated by erp_meta.require_platform(''support'').')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('contract_provisioning', 'Contract provisions entitlement', 'assertion', 'platform',
   'erp', 'assert_contract_provisions_entitlement', '', 'contract_provisioning_report', '',
   'D35: every contract in force has provisioned its subscription and the subscription agrees with it; every signed amendment is provisioned; a contract in force has a signed document.',
   true, 72)
on conflict (code) do update set
  title = excluded.title, blurb = excluded.blurb, function_name = excluded.function_name,
  detail_function = excluded.detail_function, seq = excluded.seq;

insert into erp_ref.product_decision (code, seq, title, decision, rationale, cost, spec_reference) values
  ('D35', 35, 'The contract provisions the entitlement, never the reverse',
   'A signed contract or amendment is the source of what an organisation is entitled to; the enforced entitlement is derived from it.',
   'Drift between what was sold and what was provisioned is the ordinary state of most software businesses, and it is only avoidable by making the two the same record.',
   'An entitlement cannot be adjusted by hand; every change is an amendment with a signature.', 'v1.5 §17.9, Part 22 D35')
on conflict (code) do update set
  seq = excluded.seq, title = excluded.title, decision = excluded.decision,
  rationale = excluded.rationale, cost = excluded.cost, spec_reference = excluded.spec_reference;

insert into erp_ref.product_decision_check (decision_code, schema_name, routine_name, note) values
  ('D35', 'erp', 'assert_contract_provisions_entitlement',
   'D35 says the contract is the source and the entitlement is derived. The assertion fails a subscription that disagrees with the contract in force, a contract in force with no subscription, and a signed amendment not provisioned.')
on conflict (decision_code, schema_name, routine_name) do update set note = excluded.note;

insert into erp_meta.policy_decision (code, title, spec_reference, decision, rationale, status, evidence) values
  ('signature_is_meaning_signers_and_checksum',
   'A commercial signature records its meaning, both signers and the checksum of what was signed',
   'v1.5 §9.3, §17.7, §17.8',
   'Signing a contract or an amendment records the customer signer, the platform signer, the stated meaning of the signature, and stands against a document row that carries the checksum of exactly what was signed. The signature is entered by platform staff on the customer''s behalf from the returned order form, which is why both names are captured rather than one.',
   '§9.3 asks for meaning captured explicitly, two components, non-repudiation and manifestation on the signed record. Meaning and manifestation are here; the two components and non-repudiation belong to the identity layer the platform staff signed in through, which is recorded on the platform log entry. A customer-side signing surface, where the customer signs from within their own organisation, is the natural next step and is recorded open rather than implied.',
   'accepted',
   'erp.sign_contract(); erp.sign_amendment(); erp_meta.contract_document.checksum; the platform log entry for every signature.')
on conflict (code) do update set
  title = excluded.title, decision = excluded.decision, rationale = excluded.rationale,
  status = excluded.status, evidence = excluded.evidence;

insert into erp_ref.resource (key, locale, value, description) values
('event.commercial.contract_signed', 'en', 'Contract signed', 'The organisation''s contract was signed and its entitlement provisioned from it.'),
('event.commercial.contract_amended', 'en', 'Contract amended', 'A signed amendment changed the organisation''s entitlement from its effective date.'),
('event.commercial.notice_deadline_announced', 'en', 'Notice deadline approaching', 'The last day to give notice on the contract is within the lead time.'),
('event.commercial.renewal_announced', 'en', 'Renewal approaching', 'The contract''s term ends within the lead time.'),
('event.commercial.uplift_announced', 'en', 'Uplift approaching', 'The contract''s uplift date is within the lead time.'),
('event.commercial.review_announced', 'en', 'Review approaching', 'The contract''s review date is within the lead time.'),
('job_handler.raise_contract_key_dates.name', 'en', 'Raise contract key dates', 'The scheduled sweep that raises each contract''s key-date notifications once, on its lead time.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

-- ── The suite ─────────────────────────────────────────────────────────────────

create or replace function erp_test.commercial_contract_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  rp record; rc record;
  ad uuid := gen_random_uuid(); ow uuid := gen_random_uuid(); ca uuid := gen_random_uuid();
  v_platform uuid; v_pcode text := 'zzctp-' || substr(md5(random()::text), 1, 6);
  v_customer uuid; v_ccode text := 'zzctc-' || substr(md5(random()::text), 1, 6);
  v_q uuid; v_contract uuid; v_amend uuid; v_sub uuid; res jsonb; v_ok boolean; v_msg text; v_n integer;
begin
  select * into rp from erp.provision_tenant(v_pcode, 'Clove Platform Contracts', 'admin@zzct.test', 'Platform Admin');
  v_platform := rp.tenant_id;
  select * into rc from erp.provision_tenant(v_ccode, 'Acme Foods Ltd', 'admin@zzctc.test', 'Customer Admin');
  v_customer := rc.tenant_id;
  insert into auth.users (id, email) values (ad, 'admin@zzct.test'), (ow, 'owner@zzct.test'), (ca, 'admin@zzctc.test');
  insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
  values ('owner@zzct.test', ow, 'Platform Owner', 'owner');
  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  perform erp.claim_invitation(rp.admin_token);
  perform set_config('request.jwt.claims', json_build_object('sub', ca)::text, true);
  perform erp.claim_invitation(rc.admin_token);
  perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
  perform erp.designate_platform_organisation(v_pcode);

  -- The book and a quote, accepted.
  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  perform erp_test.reopen_bootstrap_window(v_platform);
  perform erp.configure_commercial(10, 'administrator');
  perform erp.open_price_book('PB-2026', 'List 2026', array['GBP'], current_date - 1, null);
  perform erp_test.close_bootstrap_window(v_platform);
  perform erp.upsert_price_item('PLAN-STD', 'Standard plan', 'plan_tier', 'standard');
  perform erp.upsert_price_item('USERS-250', 'Up to 250 users', 'user_band', null, null, 'users', 101, 250);
  perform erp.upsert_price_item('CAP-SERIAL', 'Serialisation', 'capability_addon', null, 'serialisation');
  perform erp.upsert_price_item('SUP-SEV1', 'Severity 1 support', 'support_tier', null, null, null, null, null, null, 'sev1');
  perform erp.set_rate('PB-2026', 'PLAN-STD', 'GBP', 1200000);
  perform erp.set_rate('PB-2026', 'USERS-250', 'GBP', 500000);
  perform erp.set_rate('PB-2026', 'CAP-SERIAL', 'GBP', 150000);
  perform erp.set_rate('PB-2026', 'SUP-SEV1', 'GBP', 200000);
  perform erp.set_cost_model('PLAN-STD', 'GBP', 300000, 100000, 50000);
  perform erp.set_cost_model('USERS-250', 'GBP', 100000, 50000, 0);
  perform erp.set_cost_model('CAP-SERIAL', 'GBP', 20000, 10000, 0);
  perform erp.set_cost_model('SUP-SEV1', 'GBP', 0, 150000, 0);
  v_q := erp.open_commercial_quote('ACME', 'Acme Foods Ltd', 'PB-2026', 'annual', 12, 'GBP', 30, v_ccode);
  perform erp.add_quote_line(v_q, 'PLAN-STD');
  perform erp.add_quote_line(v_q, 'USERS-250');
  perform erp.add_quote_line(v_q, 'CAP-SERIAL');
  perform erp.add_quote_line(v_q, 'SUP-SEV1');
  perform erp.submit_quote(v_q);

  -- ── §17.8 a contract is created from an accepted quote ───────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
  begin
    perform erp.create_contract_from_quote(v_q, v_ccode, 'Acme Foods Ltd', 'Clove Ltd', current_date);
    v_ok := false; v_msg := 'a contract was created from a quote that was not accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_QUOTE_NOT_ACCEPTED%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a contract is created from an accepted quote and nothing else', v_ok, v_msg;

  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  perform erp.issue_quote(v_q);
  perform erp.quote_transition(v_q, 'accept', 'order form returned signed');
  perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
  v_contract := erp.create_contract_from_quote(
    v_q, v_ccode, 'Acme Foods Ltd', 'Clove Ltd', current_date, 12, 'automatic', 90, 'England and Wales', 'annual',
    '{"kind": "fixed_pct", "pct": 5}'::jsonb,
    '{"rights": "either party on material breach unremedied after 30 days", "exit_assistance_days": 90, "data_return": "full export in open formats before deletion"}'::jsonb,
    null, 30);
  res := erp.contract_position(v_contract);
  return query select 'the contract carries what the quote sold, as structured fields',
    res ->> 'plan_code' = 'standard' and res ->> 'support_severity_code' = 'sev1'
    and (res ->> 'annual_value_minor')::bigint = 2050000
    and jsonb_array_length(res -> 'entitlements') = 1 and jsonb_array_length(res -> 'capabilities') = 1
    and (res -> 'documents' -> 0 ->> 'kind') = 'order_form' and (res -> 'documents' -> 0 ->> 'checksum') is not null
    and res ->> 'status' = 'draft'
    and (select count(*) from erp_meta.subscription s where s.tenant_id = v_customer) = 0,
    'plan, band, feature, support tier, order form with checksum; nothing provisioned yet';

  return query select 'key dates are a derivation over structured fields',
    exists (select 1 from jsonb_array_elements(res -> 'key_dates') k where k ->> 'kind' = 'expiry'
             and (k ->> 'due_on')::date = (current_date + interval '12 months')::date)
    and exists (select 1 from jsonb_array_elements(res -> 'key_dates') k where k ->> 'kind' = 'notice_deadline'
             and (k ->> 'due_on')::date = (current_date + interval '12 months')::date - 90)
    and exists (select 1 from jsonb_array_elements(res -> 'key_dates') k where k ->> 'kind' = 'uplift'),
    'expiry, notice deadline, uplift';

  begin
    perform erp.sign_contract(v_contract, 'A. Customer', '', 'I agree');
    v_ok := false; v_msg := 'a signature with one signer was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_SIGNATURE_INCOMPLETE%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a signature names both signers and its meaning', v_ok, v_msg;

  -- ── §17.9 signing provisions ─────────────────────────────────────────────

  v_sub := erp.sign_contract(v_contract, 'A. Customer, Finance Director', 'P. Owner, Clove Ltd',
                             'Agreement to the order form and the terms it names');
  return query select 'a signed contract provisions the subscription directly',
    v_sub is not null
    and exists (select 1 from erp_meta.subscription s where s.id = v_sub and s.tenant_id = v_customer
                 and s.plan_code = 'standard' and s.term_start = current_date
                 and s.term_end = (current_date + interval '12 months')::date and s.renews)
    and (select c.status from erp_meta.contract c where c.id = v_contract) = 'active'
    and (select d.signed_at is not null and d.signed_by_customer like 'A. Customer%' from erp_meta.contract_document d
          where d.contract_id = v_contract and d.kind = 'order_form'),
    'subscription written from the contract; order form signed by both with its meaning';

  return query select 'and the customer''s organisation is told',
    exists (select 1 from erp.event e where e.tenant_id = v_customer and e.event_type = 'commercial.contract_signed'),
    'commercial.contract_signed in the customer''s own event stream';

  -- The customer, in its own organisation.
  perform set_config('request.jwt.claims', json_build_object('sub', ca)::text, true);
  return query select 'the entitlement enforced is the contract''s band, not the plan''s figure',
    erp.entitlement_limit('users') = 250
    and (select pe.limit_value from erp_meta.plan_entitlement pe where pe.plan_code = 'standard' and pe.entitlement_code = 'users') = 100
    and erp.entitlement_limit('sites') = 10,
    'users 250 by contract; sites 10 by plan';

  begin
    perform erp.require_capability_on_plan('serialisation');
    v_ok := true; v_msg := 'serialisation sold as an add-on is available';
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a feature the contract sold is available though the plan lacks it', v_ok, v_msg;
  begin
    perform erp.require_capability_on_plan('production');
    v_ok := false; v_msg := 'a feature neither plan nor contract sold was allowed';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_CAPABILITY_NOT_ON_PLAN%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'and one neither sold nor on the plan is refused', v_ok, v_msg;

  -- ── D35: drift is caught ─────────────────────────────────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
  return query select 'the assertion passes while subscription and contract agree',
    erp.assert_contract_provisions_entitlement() like 'contracts: 1 in force%', erp.assert_contract_provisions_entitlement();
  update erp_meta.subscription set plan_code = 'enterprise' where id = v_sub;
  begin
    perform erp.assert_contract_provisions_entitlement();
    v_ok := false; v_msg := 'a subscription edited away from its contract passed';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_CONTRACT_DRIFT%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a subscription edited away from its contract fails the build', v_ok, v_msg;
  perform erp.provision_entitlement_from_contract(v_contract);
  return query select 'and re-provisioning from the contract restores it',
    (select s.plan_code from erp_meta.subscription s where s.id = v_sub) = 'standard', 'standard again';

  -- ── §17.8 amendments ─────────────────────────────────────────────────────

  begin
    perform erp.amend_contract(v_contract, 'Imaginary band', current_date, '{"entitlements": [{"code": "imaginary", "limit_value": 1}]}'::jsonb);
    v_ok := false; v_msg := 'an amendment naming an unknown entitlement was drafted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_UNKNOWN_ENTITLEMENT%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'an amendment is validated before it can be signed', v_ok, v_msg;

  v_amend := erp.amend_contract(v_contract, 'More users, a feature withdrawn', current_date + 1,
    '{"entitlements": [{"code": "users", "limit_value": 500}], "capabilities": [{"code": "serialisation", "action": "remove"}], "annual_value_minor": 2400000}'::jsonb,
    'growth at the second site');
  perform set_config('request.jwt.claims', json_build_object('sub', ca)::text, true);
  return query select 'a drafted amendment changes nothing until it is signed',
    erp.entitlement_limit('users') = 250, 'still 250';

  perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
  perform erp.sign_amendment(v_amend, 'A. Customer, Finance Director', 'P. Owner, Clove Ltd', 'Agreement to amendment 1');
  res := erp.contract_position(v_contract);
  return query select 'a signed amendment provisions from its effective date, and is held as an addendum',
    (select a.provisioned_at is not null from erp_meta.contract_amendment a where a.id = v_amend)
    and exists (select 1 from erp_meta.contract_entitlement ce where ce.contract_id = v_contract and ce.entitlement_code = 'users'
                 and ce.limit_value = 500 and ce.effective_from = current_date + 1 and ce.amendment_id = v_amend)
    and exists (select 1 from erp_meta.contract_entitlement ce where ce.contract_id = v_contract and ce.entitlement_code = 'users'
                 and ce.limit_value = 250 and ce.effective_to = current_date + 1)
    and (res ->> 'annual_value_minor')::bigint = 2400000
    and exists (select 1 from erp_meta.contract_document d where d.contract_id = v_contract and d.kind = 'amendment' and d.signed_at is not null)
    and exists (select 1 from erp.event e where e.tenant_id = v_customer and e.event_type = 'commercial.contract_amended'),
    'users 250 until tomorrow, 500 from tomorrow; serialisation withdrawn from tomorrow';

  perform set_config('request.jwt.claims', json_build_object('sub', ca)::text, true);
  return query select 'until the effective date the previous position holds',
    erp.entitlement_limit('users') = 250, 'today: 250';
  perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);

  -- ── §17.8 key dates raise notifications on the lead time ─────────────────

  update erp_meta.contract set notice_days = 355 where id = v_contract;   -- deadline in ten days
  select erp.raise_contract_key_dates() into v_n;
  return query select 'a key date inside the lead time raises a notification in the customer''s organisation, once',
    v_n >= 1
    and exists (select 1 from erp.event e where e.tenant_id = v_customer and e.event_type = 'commercial.notice_deadline_announced')
    and exists (select 1 from erp_meta.contract_notice n where n.contract_id = v_contract and n.kind = 'notice_deadline'),
    format('%s notification(s) raised', v_n);
  select erp.raise_contract_key_dates() into v_n;
  return query select 'and the second sweep raises nothing new', v_n = 0, 'raised once';

  -- ── Clean up ──────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  delete from erp_meta.contract where id = v_contract;
  delete from erp_meta.subscription where tenant_id = v_customer;
  delete from erp_meta.platform_organisation where tenant_id = v_platform;
  perform erp.begin_tenant_purge(v_platform);
  delete from erp.tenant where id = v_platform;
  perform erp.end_tenant_purge();
  perform erp.begin_tenant_purge(v_customer);
  delete from erp.tenant where id = v_customer;
  perform erp.end_tenant_purge();
  delete from erp_meta.platform_staff where email like '%@zzct.test';
  delete from auth.users where id in (ad, ow, ca);
  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant tn where tn.id in (v_platform, v_customer))
    and not exists (select 1 from erp_meta.contract c where c.tenant_id = v_customer)
    and not exists (select 1 from erp_meta.subscription s where s.tenant_id = v_customer),
    'organisations, contract and subscription gone';
end;
$$;

create or replace function erp_test.assert_commercial_contract_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _commercial_contract_result on commit drop as
    select * from erp_test.commercial_contract_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_total, v_passed, v_detail
    from _commercial_contract_result;
  if v_passed < v_total then
    raise exception E'ERPWARE_COMMERCIAL_CONTRACT_SUITE_FAILED: %/%\n%', v_passed, v_total, v_detail
      using errcode = 'P0001';
  end if;
  return format('commercial contracts: %s/%s', v_passed, v_total);
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
select erp.assert_entitlements_enforceable();
select erp.assert_contract_provisions_entitlement();
select erp.assert_product_decisions_enforced();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
select erp.assert_guidance_sound();
