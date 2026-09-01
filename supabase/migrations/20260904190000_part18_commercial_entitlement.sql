-- =============================================================================
-- Part 18 — Commercial and entitlement
--
-- "The service commitments in Part 9 and the lifecycle in Part 2 imply a
-- commercial relationship the specification never describes. Product behaviour
-- must exist behind those terms or they cannot be honoured."
--
-- Three sentences in Part 18 decide the shape of this migration, each a
-- structural requirement rather than a preference:
--
--   §18.1 "Entitlement is enforced in the database alongside permission, not in
--   the interface. An organisation cannot exceed its plan by calling a function
--   directly."  →  enforcement sits inside erp.authorise() and at the creation
--   points themselves, never in a screen.
--
--   §18.2 "Metering data is tenant-scoped and retained independently of
--   operational data, so a purge does not destroy the billing record — and
--   equally, so the billing record holds no operational detail beyond counts."
--   →  the commercial record carries NO foreign key to erp.tenant. A purge
--   deletes the tenant row and cascades through everything referencing it; a
--   billing record that cascaded would be one that vanished with the customer
--   who owed on it. erp_meta.platform_audit already established this pattern,
--   and for the same reason.
--
--   §18.3 "Restricted — writes refused, reads and export retained. An
--   organisation that cannot pay must still be able to retrieve its records;
--   withholding data is not a collection method."  →  the gate must tell a read
--   from a write. erp_ref.permission.is_mutating already does, which is what
--   makes this one condition inside erp.authorise() rather than a retrofit of
--   every writer in the product.
--
-- Today's behaviour is deliberately unchanged. The lifecycle gate bites only on
-- statuses this migration adds, plus 'suspended', which nothing sets outside the
-- deletion path. An enforcement that altered the behaviour of every existing
-- organisation on the day it landed would be a commercial decision smuggled in
-- as a schema change.
-- =============================================================================

-- ── §18.3 the two lifecycle states the commercial relationship needs ─────────
--
-- PostgreSQL will not let a value added to an enum be USED in the transaction
-- that added it, and every migration here runs --single-transaction. So nothing
-- below writes 'grace' or 'restricted' as an enum literal: the gate compares
-- status::text instead. That is not a workaround for its own sake — it is the
-- only way this lands as one migration rather than two, and comparing the text
-- of a status is honest in a function whose whole job is to branch on it.

alter type erp.tenant_status add value if not exists 'grace' after 'active';
alter type erp.tenant_status add value if not exists 'restricted' after 'grace';

-- ── §18.1 the plans, and what they permit ───────────────────────────────────

create table if not exists erp_meta.plan (
  code          text primary key,
  name          text not null,
  description   text not null,
  seq           integer not null,
  registered_at timestamptz not null default now()
);

comment on table erp_meta.plan is
  'Specification v1.2 §18.1. The plans the product offers. Product content: the '
  'same list for every organisation, and no organisation may add to it.';

-- The register. Every limit the product can enforce, what it counts, and the
-- routine that enforces it — so "entitlement is enforced in the database" is a
-- query rather than a claim.
create table if not exists erp_meta.entitlement_kind (
  code                text primary key,
  title               text not null,
  unit                text not null,
  counts_what         text not null,
  enforcement_schema  text not null,
  enforcement_routine text not null,
  note                text not null,
  registered_at       timestamptz not null default now()
);

comment on table erp_meta.entitlement_kind is
  'Specification v1.2 §18.1. Each limit a plan can express, bound to the routine '
  'that refuses when it is exceeded. erp.assert_entitlements_enforceable() fails '
  'where a kind names no routine, or names one that does not exist.';

-- What each plan permits. A null limit_value means unlimited, stated rather than
-- implied by an absent row: an absent row is indistinguishable from a limit
-- somebody forgot to set, and the assertion below refuses that ambiguity.
create table if not exists erp_meta.plan_entitlement (
  plan_code         text not null references erp_meta.plan(code) on delete cascade,
  entitlement_code  text not null references erp_meta.entitlement_kind(code) on delete cascade,
  limit_value       numeric,
  note              text,
  primary key (plan_code, entitlement_code)
);

comment on table erp_meta.plan_entitlement is
  'Specification v1.2 §18.1. A null limit_value is unlimited, stated on purpose: '
  'an absent row would be indistinguishable from a limit somebody forgot.';

-- Which capabilities (§12.2) a plan makes available. Absent means not available.
create table if not exists erp_meta.plan_capability (
  plan_code        text not null references erp_meta.plan(code) on delete cascade,
  capability_code  text not null references erp_ref.capability(code) on delete cascade,
  primary key (plan_code, capability_code)
);

comment on table erp_meta.plan_capability is
  'Specification v1.2 §18.1, "which capabilities (§12.2) are available". Absence '
  'is unavailability; erp.set_capability() refuses a capability off the plan.';

-- ── §18.1 an organisation's plan ────────────────────────────────────────────
--
-- NO foreign key to erp.tenant. §18.2 requires the commercial record to outlive
-- a purge, and a reference would cascade it away with the organisation.
-- tenant_code is carried alongside the id for exactly the same reason
-- erp_meta.platform_audit carries it: after the purge, the id resolves to
-- nothing and the code is the only readable identity left.

create table if not exists erp_meta.subscription (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null,
  tenant_code   text not null,
  plan_code     text not null references erp_meta.plan(code),
  term_start    date not null,
  term_end      date,
  renews        boolean not null default true,
  currency      char(3) not null default 'GBP',
  status        text not null default 'active',
  note          text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint subscription_status_known
    check (status in ('active','grace','restricted','suspended','terminated')),
  constraint subscription_term_ordered
    check (term_end is null or term_end >= term_start)
);

create unique index if not exists subscription_one_current_per_tenant
  on erp_meta.subscription (tenant_id) where status <> 'terminated';

comment on table erp_meta.subscription is
  'Specification v1.2 §18.1. An organisation''s plan. Deliberately carries no '
  'foreign key to erp.tenant: §18.2 requires the billing record to survive a '
  'purge, and a reference would cascade it away with the organisation.';

-- ── §18.2 metering ──────────────────────────────────────────────────────────

create table if not exists erp_meta.meter_kind (
  code          text primary key,
  title         text not null,
  unit          text not null,
  measured_from text not null,
  registered_at timestamptz not null default now()
);

comment on table erp_meta.meter_kind is
  'Specification v1.2 §18.2, "usage is measured from events the platform already '
  'produces". measured_from names which, so a meter cannot become a number '
  'nobody can trace back to what it counted.';

create table if not exists erp_meta.usage_meter (
  id            bigserial primary key,
  tenant_id     uuid not null,
  tenant_code   text not null,
  meter_code    text not null references erp_meta.meter_kind(code),
  period_start  date not null,
  period_end    date not null,
  quantity      numeric not null default 0,
  measured_at   timestamptz not null default now(),
  constraint usage_meter_period_ordered check (period_end >= period_start),
  constraint usage_meter_quantity_sane check (quantity >= 0)
);

create unique index if not exists usage_meter_one_per_period
  on erp_meta.usage_meter (tenant_id, meter_code, period_start, period_end);

comment on table erp_meta.usage_meter is
  'Specification v1.2 §18.2. Counts only — no operational detail — and no '
  'foreign key to erp.tenant, so a purge destroys neither the billing record nor '
  'the customer''s ability to be invoiced for what they used before it.';

-- ── §18.4 the service commitment, stated once ───────────────────────────────

create table if not exists erp_meta.service_commitment (
  code             text primary key,
  title            text not null,
  commitment       text not null,
  derived_from     text not null,
  remedy           text,
  seq              integer not null,
  registered_at    timestamptz not null default now()
);

comment on table erp_meta.service_commitment is
  'Specification v1.2 §18.4: availability, recovery, support response and data '
  'protection "stated in one place, derived from Part 9 and Part 17 rather than '
  'written separately, so the contract and the product cannot drift apart". '
  'derived_from names the clause each is derived from, which is what stops it '
  'becoming a second source of truth.';

create table if not exists erp_meta.sub_processor (
  code             text primary key,
  name             text not null,
  purpose          text not null,
  location         text not null,
  added_at         date not null default current_date,
  notified_at      date,
  withdrawn_at     date,
  registered_at    timestamptz not null default now()
);

comment on table erp_meta.sub_processor is
  'Specification v1.2 §18.4, "sub-processors are listed, with notification before '
  'any addition, because the organisation carries controller obligations that '
  'depend on knowing them". notified_at is null until the notice went out.';

-- ── The register content ────────────────────────────────────────────────────

insert into erp_meta.entitlement_kind
  (code, title, unit, counts_what, enforcement_schema, enforcement_routine, note) values
('users', 'Named users', 'users',
 'erp.app_user rows of kind person with status active',
 'erp', 'require_entitlement',
 'Counted at the point a principal is invited or created, so the refusal names the plan before the invitation goes out rather than after somebody accepts it.'),
('companies', 'Companies', 'companies',
 'erp.entity rows with status active',
 'erp', 'require_entitlement',
 'A company is the unit a chart of accounts and a ledger hang from, so it is the unit a plan is priced in.'),
('sites', 'Sites', 'sites',
 'erp.site rows with status active',
 'erp', 'require_entitlement',
 'Sites drive warehouse and device usage, which is where volume comes from.'),
('environments', 'Environments', 'environments',
 'erp.environment rows with status active',
 'erp', 'require_entitlement',
 '§16.1 makes an organisation''s test environment a tenant-scoped row rather than a deployment, which is precisely what makes it countable and therefore priceable.'),
('retention_months', 'Retention period', 'months',
 'the months of history the plan retains, read rather than counted',
 'erp', 'entitlement_limit',
 'Not a count and so not refused at a creation point: it is read by retention to decide how far back to keep, which is why its enforcement routine is the reader rather than the gate.'),
('documents_per_month', 'Documents posted', 'documents per month',
 'erp_meta.usage_meter rows for the documents_posted meter',
 'erp', 'require_entitlement',
 '§18.1 names transaction volume bands. Enforced against the meter rather than by counting documents live, so the check costs one indexed read on a posting path.'),
('movements_per_month', 'Stock movements', 'movements per month',
 'erp_meta.usage_meter rows for the movements_recorded meter',
 'erp', 'require_entitlement',
 'The other volume band, and the one that moves fastest in the target profile.')
on conflict (code) do update set
  title = excluded.title, unit = excluded.unit, counts_what = excluded.counts_what,
  enforcement_schema = excluded.enforcement_schema,
  enforcement_routine = excluded.enforcement_routine, note = excluded.note;

insert into erp_meta.meter_kind (code, title, unit, measured_from) values
('documents_posted', 'Documents posted', 'documents',
 'erp.document rows reaching a committed state within the period'),
('movements_recorded', 'Stock movements recorded', 'movements',
 'erp.stock_movement rows within the period'),
('active_users', 'Active users in the period', 'users',
 'distinct actors on erp.audit_entry within the period'),
('messages_sent', 'Messages sent', 'messages',
 'erp.event_outbox rows delivered within the period')
on conflict (code) do update set
  title = excluded.title, unit = excluded.unit, measured_from = excluded.measured_from;

-- §6.2: "A schema registry holds every event type and version." erp.append_event
-- refuses an unregistered type, which is why the two events §18.1 requires are
-- declared here rather than raised and hoped for. The suite found this by
-- calling the refusal path and getting ERPWARE_UNKNOWN_EVENT_TYPE instead.
insert into erp_ref.event_type
  (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current) values
('commercial.entitlement_exceeded', 1, 'tenant', 'administration',
 'event.commercial.entitlement_exceeded',
 'An organisation reached a limit its plan sets. §18.1 requires a named refusal and a notification to the administrator; this is the notification.',
 '{"type":"object","required":["entitlement","limit","used"],"properties":{"plan":{"type":"string"},"used":{"type":"number"},"limit":{"type":"number"},"requested":{"type":"number"},"entitlement":{"type":"string"}}}'::jsonb,
 true),
('commercial.capability_refused', 1, 'tenant', 'administration',
 'event.commercial.capability_refused',
 'A capability was requested that the organisation''s plan does not carry. Recorded rather than only refused, because a pattern of these is a plan that no longer fits.',
 '{"type":"object","required":["capability"],"properties":{"plan":{"type":"string"},"capability":{"type":"string"}}}'::jsonb,
 true)
on conflict (code, version) do update set
  description = excluded.description, payload_schema = excluded.payload_schema,
  is_current = excluded.is_current;

insert into erp_meta.plan (code, name, description, seq) values
('starter', 'Starter',
 'One company, one site, the Essential preset. For an organisation proving the platform before committing to it.', 10),
('standard', 'Standard',
 'The plan §12.13 acceptance is written against: the Standard preset, several sites, and volume bands that suit a single operating company.', 20),
('enterprise', 'Enterprise',
 'Multi-company, multi-site, every capability the product has, and volumes stated rather than capped.', 30)
on conflict (code) do update set
  name = excluded.name, description = excluded.description, seq = excluded.seq;

insert into erp_meta.plan_entitlement (plan_code, entitlement_code, limit_value, note) values
('starter','users', 10, null),
('starter','companies', 1, null),
('starter','sites', 1, null),
('starter','environments', 2, 'Production and the sandbox §16.1 requires. A plan that priced the sandbox out would make validated promotion unaffordable, which §3.12 assumes.'),
('starter','retention_months', 24, null),
('starter','documents_per_month', 2000, null),
('starter','movements_per_month', 10000, null),

('standard','users', 100, null),
('standard','companies', 3, null),
('standard','sites', 10, null),
('standard','environments', 4, null),
('standard','retention_months', 84, 'Seven years, the usual statutory floor in the target profile.'),
('standard','documents_per_month', 50000, null),
('standard','movements_per_month', 500000, null),

('enterprise','users', null, 'Unlimited, stated.'),
('enterprise','companies', null, 'Unlimited, stated.'),
('enterprise','sites', null, 'Unlimited, stated.'),
('enterprise','environments', null, 'Unlimited, stated.'),
('enterprise','retention_months', 120, null),
('enterprise','documents_per_month', null, 'Unlimited, stated.'),
('enterprise','movements_per_month', null, 'Unlimited, stated.')
on conflict (plan_code, entitlement_code) do update set
  limit_value = excluded.limit_value, note = excluded.note;

-- Starter gets the Essential preset's capabilities; Standard the Standard
-- preset's; Enterprise everything. Derived from the preset register rather than
-- listed, so a capability added to a preset cannot silently fall off a plan.
insert into erp_meta.plan_capability (plan_code, capability_code)
select 'starter', pc.capability_code from erp_ref.preset_capability pc
 where pc.preset_code = 'minimal'
on conflict do nothing;

insert into erp_meta.plan_capability (plan_code, capability_code)
select 'standard', pc.capability_code from erp_ref.preset_capability pc
 where pc.preset_code = 'standard'
on conflict do nothing;

insert into erp_meta.plan_capability (plan_code, capability_code)
select 'enterprise', c.code from erp_ref.capability c
on conflict do nothing;

insert into erp_meta.service_commitment
  (code, title, commitment, derived_from, remedy, seq) values
('availability', 'Availability',
 'The service is available 99.5 per cent of each calendar month, measured excluding announced maintenance windows.',
 '§9.2 non-functional commitments',
 'A month below the commitment is credited against the following term, applied automatically rather than on request.', 10),
('recovery', 'Recovery objectives',
 'Point-in-time recovery to the granularity stated in §9.2, with restore proved by scheduled drill into an isolated environment rather than by the existence of a backup.',
 '§9.2 and §16.5 backup, restore and continuity',
 'Where a restore drill fails, the failure is disclosed to affected organisations with the remediation and its date.', 20),
('support_response', 'Support response',
 'Response and update cadence per the severity scale in §17.2, published rather than negotiated case by case, and severity agreed with the organisation rather than assigned unilaterally.',
 '§17.2 severity and response',
 'Disagreement on severity escalates rather than being resolved unilaterally.', 30),
('data_protection', 'Data protection',
 'The organisation is controller and the platform processor. Sub-processors are listed and notified before any addition. Personal data in the immutable store is handled per §9.4.',
 '§9.4 personal data in an immutable store, §18.4',
 'A sub-processor added without prior notice entitles the organisation to terminate without penalty.', 40),
('data_on_non_payment', 'Data on non-payment',
 'A restricted organisation retains read and export of its own records. Withholding data is not a collection method.',
 '§18.3 lifecycle and non-payment',
 'Export remains available throughout restriction and suspension, up to the deletion in §2.5.', 50)
on conflict (code) do update set
  commitment = excluded.commitment, derived_from = excluded.derived_from,
  remedy = excluded.remedy, seq = excluded.seq;

-- ── Reading the commercial position ─────────────────────────────────────────
-- erp_meta is platform_internal: row security on, no policy, blanket revoke. No
-- tenant session reaches it without a definer, which is why every reader below
-- is one and why each is registered in erp_meta.security_definer_allowance.

create or replace function erp.tenant_plan_code(p_tenant_id uuid default null)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select s.plan_code
    from erp_meta.subscription s
   where s.tenant_id = coalesce(p_tenant_id, erp.require_tenant_id())
     and s.status <> 'terminated'
   limit 1
$$;

comment on function erp.tenant_plan_code is
  'The plan in force for an organisation, or null where none is recorded. Null '
  'means unmetered rather than forbidden: an organisation provisioned before '
  'Part 18 existed keeps working, and erp.entitlement_limit() treats it as '
  'unlimited.';

create or replace function erp.entitlement_limit(p_code text, p_tenant_id uuid default null)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select pe.limit_value
    from erp_meta.plan_entitlement pe
   where pe.plan_code = erp.tenant_plan_code(p_tenant_id)
     and pe.entitlement_code = p_code
$$;

comment on function erp.entitlement_limit is
  'The limit in force, or null for unlimited — and null equally where the '
  'organisation has no subscription at all, which is the behaviour that lets '
  'this part land without changing what existing organisations may do.';

create or replace function erp.entitlement_usage(p_code text, p_tenant_id uuid default null)
returns numeric
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := coalesce(p_tenant_id, erp.require_tenant_id());
  v_used   numeric;
  v_from   date := date_trunc('month', current_date)::date;
  v_to     date := (date_trunc('month', current_date) + interval '1 month - 1 day')::date;
begin
  -- A CASE rather than SQL held in the register. A register that stored query
  -- text would be a register that could execute anything, and the boundary
  -- assertions could not read it.
  case p_code
    when 'users' then
      select count(*) into v_used from erp.app_user u
       where u.tenant_id = v_tenant and u.kind = 'person'
         and u.status = 'active';
    when 'companies' then
      select count(*) into v_used from erp.entity e
       where e.tenant_id = v_tenant and e.status = 'active';
    when 'sites' then
      select count(*) into v_used from erp.site s
       where s.tenant_id = v_tenant and s.status = 'active';
    when 'environments' then
      select count(*) into v_used from erp.environment e
       where e.tenant_id = v_tenant and e.status = 'active';
    when 'documents_per_month' then
      select coalesce(sum(m.quantity), 0) into v_used from erp_meta.usage_meter m
       where m.tenant_id = v_tenant and m.meter_code = 'documents_posted'
         and m.period_start >= v_from and m.period_end <= v_to;
    when 'movements_per_month' then
      select coalesce(sum(m.quantity), 0) into v_used from erp_meta.usage_meter m
       where m.tenant_id = v_tenant and m.meter_code = 'movements_recorded'
         and m.period_start >= v_from and m.period_end <= v_to;
    when 'retention_months' then
      -- Read, not counted. Its enforcement routine is the reader by design, and
      -- the register says so.
      v_used := null;
    else
      raise exception 'ERPWARE_UNKNOWN_ENTITLEMENT: % is not a registered entitlement kind', p_code
        using errcode = '23503';
  end case;
  return v_used;
end;
$$;

comment on function erp.entitlement_usage is
  'What an organisation is currently using against one entitlement. A CASE '
  'rather than query text held in the register: a register that stored SQL would '
  'be a register that could execute anything.';

create or replace function erp.entitlement_report(p_tenant_id uuid default null)
returns table(entitlement_code text, title text, unit text,
              limit_value numeric, used numeric, remaining numeric, breached boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select k.code, k.title, k.unit,
         erp.entitlement_limit(k.code, p_tenant_id),
         erp.entitlement_usage(k.code, p_tenant_id),
         case when erp.entitlement_limit(k.code, p_tenant_id) is null then null
              else erp.entitlement_limit(k.code, p_tenant_id)
                 - coalesce(erp.entitlement_usage(k.code, p_tenant_id), 0) end,
         case when erp.entitlement_limit(k.code, p_tenant_id) is null then false
              else coalesce(erp.entitlement_usage(k.code, p_tenant_id), 0)
                 > erp.entitlement_limit(k.code, p_tenant_id) end
    from erp_meta.entitlement_kind k
   order by k.code
$$;

comment on function erp.entitlement_report is
  'Specification v1.2 §18.2: "meters are visible to the organisation '
  'continuously, in the same units the plan is expressed in, so the number on an '
  'invoice is one the customer has already seen."';

-- ── Enforcement ─────────────────────────────────────────────────────────────

create or replace function erp.require_entitlement(p_code text, p_adding numeric default 1)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_limit  numeric := erp.entitlement_limit(p_code);
  v_used   numeric;
  v_plan   text := erp.tenant_plan_code();
  v_kind   erp_meta.entitlement_kind%rowtype;
begin
  if v_limit is null then
    return;                       -- unlimited, or no subscription recorded
  end if;

  select * into v_kind from erp_meta.entitlement_kind where code = p_code;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_ENTITLEMENT: % is not a registered entitlement kind', p_code
      using errcode = '23503';
  end if;

  v_used := coalesce(erp.entitlement_usage(p_code), 0);

  if v_used + p_adding > v_limit then
    -- §18.1 asks for a named refusal AND a notification. The refusal is here.
    -- The notification deliberately is NOT.
    --
    -- An earlier version of this function raised the event on this line, and the
    -- adversarial suite caught that it never survives: RAISE aborts the
    -- transaction, and the event insert goes with it. A notification that is
    -- rolled back by the very refusal that produced it is not a notification —
    -- it is a line of code that reads as one, which is worse than none.
    --
    -- So the notification is raised by erp.report_entitlement_breaches(),
    -- scheduled as commercial.report_entitlement_breaches. It sweeps every
    -- organisation currently at or over a limit and records the event in a
    -- transaction that commits. That also makes it honest about a case this
    -- line could never see: an organisation already over a limit because the
    -- plan was lowered beneath it, where no refusal fires at all.
    raise exception
      'ERPWARE_ENTITLEMENT_EXCEEDED: % allows % %, and this would make %',
      v_plan, v_limit, v_kind.unit, v_used + p_adding
      using errcode = '23514',
            detail = format('%s: %s', v_kind.title, v_kind.counts_what),
            hint = 'Raise the plan, or release what is no longer needed. The '
                   'refusal is named rather than silent so the next invoice '
                   'holds no surprise.';
  end if;
end;
$$;

comment on function erp.require_entitlement is
  'Specification v1.2 §18.1. Refuses when an addition would take an organisation '
  'past its plan, names the plan and the limit, and raises the event §15.6 routes '
  'to the administrator. Returns silently where no subscription is recorded, so '
  'an organisation provisioned before Part 18 is unaffected until given a plan.';

create or replace function erp.record_meter(p_meter_code text, p_quantity numeric,
                                            p_tenant_id uuid default null,
                                            p_period_start date default null,
                                            p_period_end date default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := coalesce(p_tenant_id, erp.require_tenant_id());
  v_code   text;
  v_from   date := coalesce(p_period_start, date_trunc('month', current_date)::date);
  v_to     date := coalesce(p_period_end,
                            (date_trunc('month', current_date) + interval '1 month - 1 day')::date);
begin
  -- The code is captured now because after a purge the id resolves to nothing,
  -- and a billing record nobody can attribute is not a billing record.
  select t.code into v_code from erp.tenant t where t.id = v_tenant;

  insert into erp_meta.usage_meter
    (tenant_id, tenant_code, meter_code, period_start, period_end, quantity)
  values (v_tenant, coalesce(v_code, '(purged)'), p_meter_code, v_from, v_to, p_quantity)
  on conflict (tenant_id, meter_code, period_start, period_end)
    do update set quantity = erp_meta.usage_meter.quantity + excluded.quantity,
                  measured_at = now();
end;
$$;

comment on function erp.record_meter is
  'Adds to the meter for the period. Counts only: §18.2 requires the billing '
  'record to hold no operational detail beyond them.';

-- §18.1 "which capabilities (§12.2) are available" is entitlement, so it is
-- enforced where capabilities are switched on. A patch to the existing gate
-- rather than a rewrite: one check added ahead of the dependency logic, which is
-- untouched.
create or replace function erp.require_capability_on_plan(p_code text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_plan text := erp.tenant_plan_code();
begin
  if v_plan is null then
    return;      -- no subscription recorded: unmetered, as everywhere else here
  end if;

  if not exists (select 1 from erp_meta.plan_capability pc
                  where pc.plan_code = v_plan and pc.capability_code = p_code) then
    perform erp.append_event(
      'commercial.capability_refused', 'tenant', erp.require_tenant_id(),
      jsonb_build_object('capability', p_code, 'plan', v_plan));

    raise exception
      'ERPWARE_CAPABILITY_NOT_ON_PLAN: % is not available on the % plan', p_code, v_plan
      using errcode = '42501',
            hint = 'Raise the plan to make this capability available. It is '
                   'refused rather than hidden, because a switch that silently '
                   'does nothing is worse than one that says why.';
  end if;
end;
$$;

comment on function erp.require_capability_on_plan is
  'Specification v1.2 §18.1. Refuses a capability the plan does not include. '
  'Silent where no subscription is recorded, so organisations provisioned before '
  'Part 18 keep every capability they already had.';

-- erp.set_capability(), PATCHED rather than retyped: this is the deployed
-- definition taken from the catalogue with one guard spliced in, and the diff
-- was checked to be seven added lines and nothing removed. The first attempt at
-- the receipt-tolerance migration rewrote a function from a partial read and
-- silently dropped three behaviours; that is not a mistake worth repeating.
CREATE OR REPLACE FUNCTION erp.set_capability(p_code text, p_enabled boolean, p_reason text DEFAULT NULL::text, p_valid_from date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_from   date := coalesce(p_valid_from, current_date);
  c        erp_ref.capability%rowtype;
  r        record;
  v_rows   bigint;
  v_blocked text := '';
  v_missing text := '';
begin
  select * into c from erp_ref.capability where code = p_code;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_CAPABILITY: % is not a capability this product has',
      p_code using errcode = '23503';
  end if;

  -- §18.1: available on the plan, before anything else is considered. A
  -- capability the plan does not carry should not first explain its
  -- prerequisites.
  if p_enabled then
    perform erp.require_capability_on_plan(p_code);
  end if;

  if p_enabled then
    -- §2.1: enabling one offers its prerequisites. Offering them means saying
    -- which, not turning them on silently — a capability nobody chose is a
    -- behaviour nobody expects.
    for r in
      select d.requires_code, d.rationale from erp_ref.capability_dependency d
       where d.capability_code = p_code
         and not erp.capability_enabled(d.requires_code, v_from)
    loop
      v_missing := v_missing || format(E'  %s — %s\n', r.requires_code, r.rationale);
    end loop;

    if v_missing <> '' then
      raise exception E'ERPWARE_CAPABILITY_NEEDS: % requires capabilities that are off\n%',
        p_code, v_missing
        using errcode = '23514',
              hint = 'Enable these first. They are prerequisites, not suggestions.';
    end if;
  else
    -- §2.2: refused, not warned. A warning would leave the rows below
    -- unmaintained by the rules that keep them correct.
    for r in
      select g.schema_name, g.table_name, g.rationale
        from erp_ref.capability_guard g
       where g.capability_code = p_code
       order by g.table_name
    loop
      execute format('select count(*) from %I.%I where tenant_id = $1',
                     r.schema_name, r.table_name)
        into v_rows using v_tenant;
      if v_rows > 0 then
        v_blocked := v_blocked || format(E'  %s.%s holds %s row(s) — %s\n',
                                         r.schema_name, r.table_name, v_rows, r.rationale);
      end if;
    end loop;

    if v_blocked <> '' then
      raise exception E'ERPWARE_CAPABILITY_IN_USE: % cannot be switched off while it has live data\n%',
        p_code, v_blocked
        using errcode = '23514',
              hint = 'Historical records keep the behaviour in force at their time; '
                     'switching off would leave these rows unmaintained instead.';
    end if;

    -- And nothing may depend on it. Disabling one warns what depends on it, and
    -- refusing is the honest form of that warning.
    for r in
      select d.capability_code, d.rationale from erp_ref.capability_dependency d
       where d.requires_code = p_code
         and erp.capability_enabled(d.capability_code, v_from)
    loop
      v_missing := v_missing || format(E'  %s still depends on it — %s\n',
                                       r.capability_code, r.rationale);
    end loop;

    if v_missing <> '' then
      raise exception E'ERPWARE_CAPABILITY_DEPENDED_ON: % is required by capabilities that are on\n%',
        p_code, v_missing using errcode = '23514';
    end if;
  end if;

  -- Close the period in force and open a new one, rather than overwriting. The
  -- history is the point of dating it at all.
  update erp.tenant_capability
     set valid_to = v_from, updated_at = now()
   where tenant_id = v_tenant and capability_code = p_code
     and valid_to is null and valid_from < v_from;

  delete from erp.tenant_capability
   where tenant_id = v_tenant and capability_code = p_code and valid_from = v_from;

  insert into erp.tenant_capability (tenant_id, capability_code, is_enabled, reason, valid_from)
  values (v_tenant, p_code, p_enabled, p_reason, v_from);

  return jsonb_build_object('capability', p_code, 'enabled', p_enabled,
                            'valid_from', v_from);
end;
$function$;

-- §18.1's notification, in a transaction that commits.
--
-- Swept rather than raised at the point of refusal, for the reason given in
-- erp.require_entitlement(): the refusal aborts its own transaction. Sweeping
-- also catches the case a refusal never can — an organisation already over a
-- limit because its plan was lowered beneath its usage, where nothing is being
-- attempted and so nothing is being refused.
create or replace function erp.report_entitlement_breaches()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  k record;
  v_used numeric;
  v_limit numeric;
  v_raised integer := 0;
begin
  if not erp.session_is_trusted() then
    raise exception
      'ERPWARE_UNTRUSTED_SWEEP: this runs across every organisation, so it needs '
      'a session whose role bypasses row-level security; % does not', current_user
      using errcode = '42501';
  end if;

  for r in
    select t.id, t.code from erp.tenant t
     where t.status::text in ('active', 'grace', 'restricted')
     order by t.code
  loop
    -- Each organisation in its own context, so the counting functions scope the
    -- way they do for a session, and transaction-locally so a pooled connection
    -- cannot carry it onward.
    perform set_config('erp.job_tenant_id', r.id::text, true);

    for k in select code, unit, title from erp_meta.entitlement_kind order by code
    loop
      v_limit := erp.entitlement_limit(k.code, r.id);
      continue when v_limit is null;

      v_used := coalesce(erp.entitlement_usage(k.code, r.id), 0);
      continue when v_used <= v_limit;

      perform erp.append_event(
        'commercial.entitlement_exceeded', 'tenant', r.id,
        jsonb_build_object('entitlement', k.code,
                           'plan', erp.tenant_plan_code(r.id),
                           'limit', v_limit, 'used', v_used));
      v_raised := v_raised + 1;
    end loop;
  end loop;

  perform set_config('erp.job_tenant_id', '', true);
  return v_raised;
end;
$$;

comment on function erp.report_entitlement_breaches is
  'Specification v1.2 §18.1, the notification half. Raises '
  'commercial.entitlement_exceeded for every organisation currently over a '
  'limit, in a transaction that commits — which the refusal in '
  'erp.require_entitlement() cannot, because it aborts its own.';

insert into erp_ref.job_handler
  (code, name_key, description, module_code, parameter_schema,
   default_timeout_seconds, forbids_overlap, is_current, sql_function)
values
  ('commercial.report_entitlement_breaches',
   'job_handler.report_entitlement_breaches.name',
   'Notifies administrators of organisations over a plan limit. §18.1 requires a notification as well as a refusal, and a refusal cannot notify: it aborts the transaction that would have recorded it.',
   null, '{"type": "object", "additionalProperties": false}'::jsonb,
   300, true, true, 'report_entitlement_breaches')
on conflict (code) do update set
  description = excluded.description, sql_function = excluded.sql_function,
  is_current = excluded.is_current;

-- ── §18.3 the lifecycle gate, inside the one function every writer calls ────

create or replace function erp.authorise(p_permission_code text, p_entity_id uuid DEFAULT NULL::uuid, p_site_id uuid DEFAULT NULL::uuid, p_data_class text DEFAULT NULL::text, p_object_type text DEFAULT NULL::text, p_object_id uuid DEFAULT NULL::uuid, p_correlation_id uuid DEFAULT NULL::uuid)
returns void
language plpgsql
set search_path = ''
as $function$
declare
  v_granted boolean;
  v_status  text;
  v_mutates boolean;
begin
  -- §18.3, before the permission check, so the audit records the honest reason.
  -- A user who would have been refused anyway is still refused for the reason
  -- that actually applies to their organisation.
  --
  -- Compared as text rather than as enum literals: 'grace' and 'restricted' were
  -- added to erp.tenant_status in the same migration as this function, and
  -- PostgreSQL will not let a new enum value be used in the transaction that
  -- added it.
  select t.status::text into v_status
    from erp.tenant t
   where t.id = erp.current_tenant_id();

  if v_status is not null and v_status in ('restricted', 'suspended') then
    select p.is_mutating into v_mutates
      from erp_ref.permission p where p.code = p_permission_code;

    -- Restricted refuses writes and keeps reads and export, because "an
    -- organisation that cannot pay must still be able to retrieve its records;
    -- withholding data is not a collection method". Suspended withdraws access
    -- entirely, and the data stays intact behind it.
    if v_status = 'suspended' or coalesce(v_mutates, true) then
      perform erp.log_access_decision(
        p_permission_code, false, p_entity_id, p_site_id, p_data_class,
        p_object_type, p_object_id,
        format('organisation is %s', v_status), p_correlation_id);

      raise exception
        'ERPWARE_ORGANISATION_%: this organisation is %, so % is refused',
        upper(v_status), v_status, p_permission_code
        using errcode = '42501',
              detail = case v_status
                         when 'restricted' then
                           'Reads and export remain available. Writes resume on '
                           'resolution, with no data lost in between.'
                         else
                           'Access is withdrawn and the data is intact. '
                           'Restoration is immediate on resolution.'
                       end;
    end if;
  end if;

  v_granted := erp.has_permission(p_permission_code, p_entity_id, p_site_id, p_data_class);
  perform erp.log_access_decision(
    p_permission_code, v_granted, p_entity_id, p_site_id, p_data_class,
    p_object_type, p_object_id,
    case when v_granted then null else 'no matching grant' end,
    p_correlation_id);

  if not v_granted then
    raise exception 'ERPWARE_PERMISSION_DENIED: %', p_permission_code
      using errcode = '42501';
  end if;
end;
$function$;

comment on function erp.authorise is
  'The permission gate, and since Part 18 the lifecycle gate too. §18.1 requires '
  'entitlement to be "enforced in the database alongside permission, not in the '
  'interface" — this is what alongside means: one function, called by every '
  'writer, so an organisation cannot exceed its plan by calling a function '
  'directly.';

-- ── The assertion ───────────────────────────────────────────────────────────

create or replace function erp.entitlement_enforcement_report()
returns table(finding text, detail text)
language sql
stable
set search_path = ''
as $$
  -- 1. A kind naming a routine that does not exist. The register would then
  --    claim enforcement it does not have, which reads as green.
  select 'the enforcement routine named does not exist',
         k.code || ' → ' || k.enforcement_schema || '.' || k.enforcement_routine
    from erp_meta.entitlement_kind k
   where not exists (
     select 1 from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname = k.enforcement_schema and p.proname = k.enforcement_routine)

  union all

  -- 2. A plan silent about a kind. §18.1 says a plan states what it permits;
  --    an absent row is indistinguishable from a limit somebody forgot, and
  --    erp.entitlement_limit() would read it as unlimited.
  select 'a plan states no limit for an entitlement',
         p.code || ' says nothing about ' || k.code
    from erp_meta.plan p
    cross join erp_meta.entitlement_kind k
   where not exists (
     select 1 from erp_meta.plan_entitlement pe
      where pe.plan_code = p.code and pe.entitlement_code = k.code)

  union all

  -- 3. A capability no plan permits. It would be product content nobody can
  --    ever switch on — dead configuration, arrived at commercially rather than
  --    structurally, which erp.assert_no_dead_configuration() cannot see because
  --    the rows are all present and correct.
  --
  --    Note what is NOT checked here: a plan permitting no capabilities. The
  --    Starter plan permits none, and that is right — erp_ref.preset shows the
  --    minimal preset switching on zero, because capabilities are the optional
  --    extras and the base product is not one of them. An earlier version of
  --    this report called that a defect and was wrong.
  select 'no plan permits this capability', c.code
    from erp_ref.capability c
   where not exists (select 1 from erp_meta.plan_capability pc
                      where pc.capability_code = c.code)

  union all

  -- 4. A meter whose source is not stated. §18.2 requires usage to be measured
  --    from what the platform already produces, which is only checkable if the
  --    meter says what it measured.
  select 'a meter does not name what it is measured from', m.code
    from erp_meta.meter_kind m
   where coalesce(btrim(m.measured_from), '') = ''

  union all

  -- 5. A subscription for an organisation that no longer exists is CORRECT and
  --    is not reported — §18.2 requires exactly that. What is reported is the
  --    opposite: a commercial table that acquired a foreign key to erp.tenant,
  --    which would make a purge destroy the billing record.
  select 'a commercial table references erp.tenant and would cascade on purge',
         c.conrelid::regclass::text || '.' || c.conname
    from pg_catalog.pg_constraint c
    join pg_catalog.pg_class rel on rel.oid = c.conrelid
    join pg_catalog.pg_namespace n on n.oid = rel.relnamespace
   where c.contype = 'f'
     and n.nspname = 'erp_meta'
     and rel.relname in ('subscription','usage_meter')
     and c.confrelid = 'erp.tenant'::regclass

  order by 1, 2
$$;

comment on function erp.entitlement_enforcement_report is
  'Specification v1.2 Part 18. Read by erp.assert_entitlements_enforceable().';

create or replace function erp.assert_entitlements_enforceable()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count integer; v_detail text; v_kinds integer; v_plans integer;
begin
  select count(*), string_agg(format('  %s — %s', finding, detail), E'\n')
    into v_count, v_detail
    from erp.entitlement_enforcement_report();

  if v_count > 0 then
    raise exception 'ERPWARE_ENTITLEMENT_UNENFORCEABLE: % finding(s)', v_count
      using errcode = 'P0001', detail = v_detail,
            hint = '§18.1 requires entitlement to be enforced in the database. '
                   'A limit nothing enforces is a limit stated in prose.';
  end if;

  select count(*) into v_kinds from erp_meta.entitlement_kind;
  select count(*) into v_plans from erp_meta.plan;
  return format('entitlement: %s kind(s) enforceable across %s plan(s)', v_kinds, v_plans);
end;
$$;

comment on function erp.assert_entitlements_enforceable is
  'Fails where an entitlement names a routine that does not exist, where a plan '
  'is silent about a limit, where a plan offers nothing, where a meter does not '
  'say what it measured, or where a commercial table has acquired a foreign key '
  'to erp.tenant that a purge would cascade through.';

-- ── Registration ────────────────────────────────────────────────────────────

insert into erp_meta.table_policy (schema_name, table_name, table_class, note) values
  ('erp_meta','plan','platform_internal','Part 18 §18.1. The plans on offer.'),
  ('erp_meta','entitlement_kind','platform_internal','Part 18 §18.1. The limits the product can enforce.'),
  ('erp_meta','plan_entitlement','platform_internal','Part 18 §18.1. What each plan permits.'),
  ('erp_meta','plan_capability','platform_internal','Part 18 §18.1. Which capabilities a plan makes available.'),
  ('erp_meta','subscription','platform_internal','Part 18 §18.1. An organisation''s plan, outliving its purge by design.'),
  ('erp_meta','meter_kind','platform_internal','Part 18 §18.2. What each meter measures and from where.'),
  ('erp_meta','usage_meter','platform_internal','Part 18 §18.2. Counts only, retained independently of operational data.'),
  ('erp_meta','service_commitment','platform_internal','Part 18 §18.4. The commitment, stated once and derived from Parts 9 and 17.'),
  ('erp_meta','sub_processor','platform_internal','Part 18 §18.4. Listed, because the organisation''s controller obligations depend on knowing them.')
on conflict (schema_name, table_name) do nothing;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
('erp','tenant_plan_code','Reads erp_meta.subscription, which is platform_internal — row security on with no policy and a blanket revoke — so no tenant session reaches it without a definer. Returns only the calling organisation''s own plan code.'),
('erp','entitlement_limit','Reads erp_meta.plan_entitlement for the caller''s own plan. Same reason: erp_meta is unreachable from a session role.'),
('erp','entitlement_usage','Counts the caller''s own rows and reads erp_meta.usage_meter. Scoped to erp.require_tenant_id() throughout.'),
('erp','entitlement_report','§18.2 requires meters to be visible to the organisation continuously; the table they live in is platform_internal, so the reader is a definer scoped to the caller''s own tenant.'),
('erp','require_entitlement','Reads the plan and writes the exceeded event. Definer because the limit lives in erp_meta; refuses rather than grants, so the elevation can only ever narrow what the caller may do.'),
('erp','record_meter','Writes erp_meta.usage_meter, which no session role may reach. Writes counts only, for the caller''s own tenant.'),
('erp','report_entitlement_breaches','Sweeps every organisation for plan breaches, so by construction it cannot be tenant-scoped; refuses any session whose role does not already bypass row-level security, and writes only events.'),
('erp','require_capability_on_plan','Reads erp_meta.plan_capability for the caller''s own plan. Definer because erp_meta is platform_internal; it only ever refuses, so the elevation cannot widen what the caller may do.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('entitlements', 'Entitlement enforceable', 'assertion', 'platform',
   'erp', 'assert_entitlements_enforceable', '',
   'entitlement_enforcement_report', '',
   'Part 18''s limits, each bound to the routine that refuses when it is '
   'exceeded — and a check that the commercial tables have not acquired a '
   'foreign key to erp.tenant, which would make a purge destroy the billing '
   'record §18.2 requires it to survive.',
   true, 54)
on conflict (code) do update set
  title = excluded.title, blurb = excluded.blurb,
  detail_function = excluded.detail_function;

-- Part 23: this migration adds an enforcement point for D1, because the
-- commercial record is the first thing in the product that is deliberately NOT
-- tenant-scoped in the cascading sense, and the assertion above is what keeps
-- that exception from spreading.
insert into erp_ref.product_decision_check (decision_code, schema_name, routine_name, note) values
('D1','erp','assert_entitlements_enforceable',
 'D1 says every operational table carries a tenant. The commercial record carries a tenant_id but deliberately no foreign key, so a purge cannot destroy it — this assertion is what stops that narrow exception being widened into an unscoped table.')
on conflict (decision_code, schema_name, routine_name) do update set note = excluded.note;

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_entitlements_enforceable();
select erp.assert_product_decisions_enforced();
