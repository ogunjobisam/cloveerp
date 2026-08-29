-- =============================================================================
-- ERPWare — B7 (completion): planning and quality
-- Spec 4.6 (Planning), 4.8 (Quality and compliance)
--
--   4.6 invariant: "every planned order traces to its demand source; firming
--                   converts a plan to a document without losing the link"
--
--   A planned order nobody can attribute is a number a planner has to either
--   trust or ignore, and they will ignore it. Pegging is therefore not optional
--   metadata: erp.planned_order refuses to exist without at least one peg, and
--   firming writes the document link back rather than replacing the plan.
--
--   4.8 invariant: "given any batch, the complete downstream despatch set and
--                   upstream component set are retrievable as a query, at any
--                   time"
--
--   Already satisfied by the trace functions in migration 0024. What this
--   migration adds is the recall around them: scope, the impacted despatch
--   set as a captured fact, the action log, and the reconciliation of what came
--   back against what went out — because "we think we got most of it" is not
--   an answer to a regulator.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Planning
-- -----------------------------------------------------------------------------

create type erp.forecast_method as enum (
  'manual', 'moving_average', 'exponential_smoothing', 'holt_winters',
  'croston', 'external'
);

create table erp.forecast (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  code           text not null,
  name           text,
  entity_id      uuid,
  site_id        uuid,
  -- Demand channels are configuration; a forecast may be per channel or across
  -- all of them.
  channel_code   text,
  bucket         text not null default 'week'
                   check (bucket in ('day', 'week', 'month', 'quarter')),
  status         erp.record_status not null default 'active',
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code),
  foreign key (tenant_id, entity_id) references erp.entity (tenant_id, id) on delete cascade,
  foreign key (tenant_id, site_id)   references erp.site (tenant_id, id) on delete cascade
);

create table erp.forecast_version (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  forecast_id    uuid not null,
  version        integer not null check (version >= 1),
  method         erp.forecast_method not null default 'manual',
  parameters     jsonb not null default '{}'::jsonb,
  -- Spec 5.4: consensus forecasting with versioning and sign-off.
  status         erp.config_version_status not null default 'draft',
  signed_off_by  uuid,
  signed_off_at  timestamptz,
  horizon_from   date not null,
  horizon_to     date not null,
  note           text,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, forecast_id, version),
  foreign key (tenant_id, forecast_id) references erp.forecast (tenant_id, id) on delete cascade,
  constraint forecast_version_horizon check (horizon_to > horizon_from)
);

create table erp.forecast_line (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  forecast_version_id uuid not null,
  item_id        uuid not null,
  site_id        uuid,
  bucket_start   date not null,
  quantity       numeric(20,6) not null,
  uom_id         uuid,
  -- What the model said, before anyone adjusted it. Keeping both is what makes
  -- accuracy measurement of the MODEL possible rather than of the model plus
  -- whatever the planner did to it.
  statistical_quantity numeric(20,6),
  adjustment_reason text,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  primary key (id),
  foreign key (tenant_id, forecast_version_id)
    references erp.forecast_version (tenant_id, id) on delete cascade,
  foreign key (tenant_id, item_id) references erp.item (tenant_id, id) on delete restrict,
  foreign key (tenant_id, site_id) references erp.site (tenant_id, id) on delete cascade
);

-- One number per item, site and bucket. An expression index because a
-- site-agnostic forecast line uses NULL, and SQL would treat two of those as
-- distinct rather than as the same line.
create unique index forecast_line_identity
  on erp.forecast_line (
    tenant_id, forecast_version_id, item_id,
    coalesce(site_id, '00000000-0000-0000-0000-000000000000'::uuid), bucket_start);

create index on erp.forecast_line (tenant_id, item_id, bucket_start);

-- Spec 5.4: forecast accuracy measurement driving model reselection.
create table erp.forecast_accuracy (
  id             bigint generated always as identity primary key,
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  forecast_version_id uuid not null,
  item_id        uuid not null,
  site_id        uuid,
  bucket_start   date not null,
  forecast_quantity numeric(20,6) not null,
  actual_quantity   numeric(20,6) not null,
  absolute_error    numeric(20,6) not null,
  measured_at    timestamptz not null default now(),
  foreign key (tenant_id, forecast_version_id)
    references erp.forecast_version (tenant_id, id) on delete cascade
);

create index on erp.forecast_accuracy (tenant_id, item_id, bucket_start);

create type erp.reorder_method as enum (
  'none', 'reorder_point', 'order_up_to', 'min_max', 'mrp', 'kanban', 'manual'
);

create table erp.planning_policy (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  code           text not null,
  name           text,
  reorder_method erp.reorder_method not null default 'reorder_point',
  safety_stock_basis text,
  service_level_pct  numeric(6,3),
  lot_sizing     text,
  fixed_lot_size numeric(20,6),
  rounding_multiple numeric(20,6),
  -- Inside the demand time fence, the plan does not change; inside the
  -- planning fence, only firm orders count. Without fences a plan reshuffles
  -- itself every run and nobody can act on it.
  demand_time_fence_days   integer,
  planning_time_fence_days integer,
  sourcing_rules jsonb not null default '[]'::jsonb,
  status         erp.record_status not null default 'active',
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code)
);

create type erp.planned_order_kind as enum ('purchase', 'transfer', 'production');
create type erp.planned_order_status as enum (
  'suggested', 'reviewed', 'firmed', 'converted', 'cancelled'
);

create table erp.planned_order (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  entity_id      uuid not null,
  site_id        uuid not null,
  item_id        uuid not null,
  order_kind     erp.planned_order_kind not null,
  quantity       numeric(20,6) not null check (quantity > 0),
  uom_id         uuid not null,
  required_by    date not null,
  release_on     date,
  supply_site_id uuid,
  supplier_party_id uuid,
  status         erp.planned_order_status not null default 'suggested',
  planning_run_id uuid,
  policy_id      uuid,
  -- Set when firmed. Spec 4.6: firming converts a plan to a document without
  -- losing the link, so this points at the document rather than the plan being
  -- deleted and replaced.
  converted_document_id uuid,
  converted_at   timestamptz,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  primary key (id),
  unique (tenant_id, id),
  foreign key (tenant_id, entity_id) references erp.entity (tenant_id, id) on delete cascade,
  foreign key (tenant_id, site_id)   references erp.site (tenant_id, id) on delete cascade,
  foreign key (tenant_id, item_id)   references erp.item (tenant_id, id) on delete restrict,
  foreign key (tenant_id, uom_id)    references erp.uom (tenant_id, id) on delete restrict,
  foreign key (tenant_id, supply_site_id) references erp.site (tenant_id, id) on delete cascade,
  foreign key (tenant_id, supplier_party_id) references erp.party (tenant_id, id) on delete restrict,
  foreign key (tenant_id, converted_document_id)
    references erp.document (tenant_id, id) on delete restrict,
  foreign key (tenant_id, policy_id)
    references erp.planning_policy (tenant_id, id) on delete set null
);

create index on erp.planned_order (tenant_id, item_id, site_id, required_by)
  where status in ('suggested', 'reviewed', 'firmed');
create index on erp.planned_order (tenant_id, planning_run_id);

-- Pegging: what demand this supply exists to satisfy.
create table erp.planned_order_peg (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  planned_order_id uuid not null,
  demand_kind    text not null,
  demand_document_line_id uuid,
  demand_planned_order_id uuid,
  demand_forecast_line_id uuid,
  quantity       numeric(20,6) not null check (quantity > 0),
  required_by    date,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  primary key (id),
  foreign key (tenant_id, planned_order_id)
    references erp.planned_order (tenant_id, id) on delete cascade,
  foreign key (tenant_id, demand_document_line_id)
    references erp.document_line (tenant_id, id) on delete cascade,
  foreign key (tenant_id, demand_planned_order_id)
    references erp.planned_order (tenant_id, id) on delete cascade,
  -- A peg that names nothing is not a peg.
  constraint planned_order_peg_has_source check (
    demand_document_line_id is not null
    or demand_planned_order_id is not null
    or demand_forecast_line_id is not null)
);

create index on erp.planned_order_peg (tenant_id, planned_order_id);
create index on erp.planned_order_peg (tenant_id, demand_document_line_id);

-- Spec 4.6 invariant: every planned order traces to its demand source. Checked
-- when the order leaves 'suggested', because a planning run legitimately builds
-- orders and pegs in two passes.
create or replace function erp.check_planned_order_pegged()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status = 'suggested' then
    return new;
  end if;

  if not exists (select 1 from erp.planned_order_peg p
                  where p.tenant_id = new.tenant_id and p.planned_order_id = new.id) then
    raise exception
      'ERPWARE_PLANNED_ORDER_UNPEGGED: % has no demand behind it and cannot be advanced', new.id
      using errcode = '23514',
            hint = 'A planned order nobody can attribute is one a planner will ignore.';
  end if;

  return new;
end;
$$;

create trigger t_planned_order_pegged
  before update of status on erp.planned_order
  for each row execute function erp.check_planned_order_pegged();

create type erp.planning_exception_kind as enum (
  'shortage', 'excess', 'past_due', 'expedite', 'defer', 'cancel',
  'no_supply_source', 'lead_time_breach', 'expiry_risk'
);

create table erp.planning_exception (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  entity_id      uuid,
  site_id        uuid,
  item_id        uuid,
  exception_kind erp.planning_exception_kind not null,
  severity       text not null default 'medium'
                   check (severity in ('low', 'medium', 'high', 'critical')),
  message        text not null,
  detail         jsonb not null default '{}'::jsonb,
  planned_order_id uuid,
  document_id    uuid,
  first_seen_at  timestamptz not null default now(),
  last_seen_at   timestamptz not null default now(),
  -- Aged and actionable: an exception nobody has looked at for a fortnight is
  -- itself the finding.
  acknowledged_at timestamptz,
  acknowledged_by uuid,
  resolved_at    timestamptz,
  resolution     text,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  primary key (id),
  foreign key (tenant_id, item_id) references erp.item (tenant_id, id) on delete cascade,
  foreign key (tenant_id, planned_order_id)
    references erp.planned_order (tenant_id, id) on delete cascade
);

create index on erp.planning_exception (tenant_id, exception_kind, severity)
  where resolved_at is null;
create index on erp.planning_exception (tenant_id, first_seen_at)
  where resolved_at is null;

-- Firming: the plan becomes a document and keeps its lineage.
create or replace function erp.firm_planned_order(
  p_planned_order_id uuid, p_document_type_code text)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  po       erp.planned_order%rowtype;
  v_doc    uuid;
begin
  select * into po from erp.planned_order
   where tenant_id = v_tenant and id = p_planned_order_id for update;

  if not found then
    raise exception 'ERPWARE_PLANNED_ORDER_NOT_FOUND: %', p_planned_order_id
      using errcode = '23503';
  end if;

  if po.status = 'converted' then
    raise exception 'ERPWARE_PLANNED_ORDER_ALREADY_FIRMED: % became %',
      p_planned_order_id, po.converted_document_id using errcode = '23514';
  end if;

  v_doc := erp.create_document(
    p_document_type_code, po.entity_id, po.site_id, po.supplier_party_id,
    current_date, null, null,
    jsonb_build_object('firmed_from_planned_order', po.id));

  insert into erp.document_line (
    tenant_id, document_id, line_no, item_id, quantity, uom_id, required_date)
  values (v_tenant, v_doc, 1, po.item_id, po.quantity, po.uom_id, po.required_by);

  -- The plan is not deleted. It records what it became, so a question about
  -- why this order exists still reaches the demand that caused it.
  update erp.planned_order
     set status = 'converted', converted_document_id = v_doc,
         converted_at = now(), updated_at = now()
   where id = p_planned_order_id;

  return v_doc;
end;
$$;

comment on function erp.firm_planned_order is
  'Spec 4.6: firming converts a plan to a document without losing the link. '
  'The planned order survives, pointing at what it became, so the pegging '
  'behind the resulting order is still answerable.';

-- Why does this order exist? Follows the document back to the plan and the
-- plan back to its demand.
create or replace function erp.explain_supply(p_document_id uuid)
returns table (planned_order_id uuid, order_kind erp.planned_order_kind,
               quantity numeric, required_by date, demand_kind text,
               demand_quantity numeric, demand_document_number text)
language sql
stable
security invoker
set search_path = ''
as $$
  select po.id, po.order_kind, po.quantity, po.required_by,
         pg.demand_kind, pg.quantity, dd.document_number
    from erp.planned_order po
    left join erp.planned_order_peg pg
      on pg.tenant_id = po.tenant_id and pg.planned_order_id = po.id
    left join erp.document_line dl
      on dl.tenant_id = pg.tenant_id and dl.id = pg.demand_document_line_id
    left join erp.document dd
      on dd.tenant_id = dl.tenant_id and dd.id = dl.document_id
   where po.tenant_id = erp.require_tenant_id()
     and po.converted_document_id = p_document_id
$$;

-- -----------------------------------------------------------------------------
-- Quality and compliance
-- -----------------------------------------------------------------------------

create type erp.inspection_status as enum (
  'planned', 'sampling', 'testing', 'complete', 'cancelled'
);
create type erp.disposition as enum (
  'pending', 'accept', 'accept_with_concession', 'rework', 'reject', 'quarantine', 'destroy'
);

create table erp.inspection_plan (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  code           text not null,
  name           text,
  item_id        uuid,
  item_class     text,
  -- When this plan applies: on receipt, in process, before release.
  trigger_point  text not null default 'receipt',
  sampling_rule  jsonb not null default '{}'::jsonb,
  characteristics jsonb not null default '[]'::jsonb,
  status         erp.record_status not null default 'active',
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code),
  foreign key (tenant_id, item_id) references erp.item (tenant_id, id) on delete cascade
);

create table erp.inspection (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  entity_id      uuid,
  site_id        uuid,
  inspection_plan_id uuid,
  item_id        uuid not null,
  batch_id       uuid,
  document_id    uuid,
  quantity_inspected numeric(20,6),
  sample_size    integer,
  status         erp.inspection_status not null default 'planned',
  disposition    erp.disposition not null default 'pending',
  disposition_by uuid,
  disposition_at timestamptz,
  disposition_note text,
  started_at     timestamptz,
  completed_at   timestamptz,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  primary key (id),
  unique (tenant_id, id),
  foreign key (tenant_id, inspection_plan_id)
    references erp.inspection_plan (tenant_id, id) on delete restrict,
  foreign key (tenant_id, item_id)  references erp.item (tenant_id, id) on delete restrict,
  foreign key (tenant_id, batch_id) references erp.batch (tenant_id, id) on delete restrict,
  foreign key (tenant_id, document_id) references erp.document (tenant_id, id) on delete cascade
);

create index on erp.inspection (tenant_id, batch_id);
create index on erp.inspection (tenant_id, status) where status <> 'complete';

create table erp.inspection_result (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  inspection_id  uuid not null,
  characteristic text not null,
  -- Both, because "3.4" and "pass" are different kinds of answer and forcing
  -- one into the other loses the specification limits.
  numeric_value  numeric(20,6),
  text_value     text,
  uom_id         uuid,
  lower_limit    numeric(20,6),
  upper_limit    numeric(20,6),
  is_within_spec boolean,
  recorded_by    uuid,
  recorded_at    timestamptz not null default now(),
  instrument     text,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  primary key (id),
  foreign key (tenant_id, inspection_id)
    references erp.inspection (tenant_id, id) on delete cascade
);

create index on erp.inspection_result (tenant_id, inspection_id);

create type erp.quality_event_kind as enum (
  'deviation', 'non_conformance', 'complaint', 'excursion', 'near_miss', 'audit_finding'
);

create table erp.quality_event (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  entity_id      uuid,
  site_id        uuid,
  reference      text not null,
  event_kind     erp.quality_event_kind not null,
  severity       text not null default 'medium'
                   check (severity in ('low', 'medium', 'high', 'critical')),
  title          text not null,
  description    text,
  item_id        uuid,
  batch_id       uuid,
  document_id    uuid,
  party_id       uuid,
  occurred_at    timestamptz,
  detected_at    timestamptz not null default now(),
  reported_by    uuid,
  -- Investigation and corrective action tracking (spec 4.8).
  investigation  text,
  root_cause     text,
  corrective_action text,
  preventive_action text,
  due_at         timestamptz,
  closed_at      timestamptz,
  closed_by      uuid,
  status         text not null default 'open'
                   check (status in ('open', 'investigating', 'action', 'verification', 'closed')),
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  primary key (id),
  unique (tenant_id, reference),
  foreign key (tenant_id, item_id)  references erp.item (tenant_id, id) on delete restrict,
  foreign key (tenant_id, batch_id) references erp.batch (tenant_id, id) on delete restrict,
  foreign key (tenant_id, party_id) references erp.party (tenant_id, id) on delete restrict
);

create index on erp.quality_event (tenant_id, status, severity) where status <> 'closed';
create index on erp.quality_event (tenant_id, batch_id) where batch_id is not null;

-- Spec 4.8: authorised release of a batch by a qualified role, with signature
-- and basis. This is the record an inspector asks to see.
create table erp.release_record (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  batch_id       uuid not null,
  released_by    uuid not null,
  released_at    timestamptz not null default now(),
  -- Which qualification the releaser held at the moment of release. Held here
  -- rather than looked up later, because their role may change and the
  -- question is what was true when they signed.
  qualified_role_code text not null,
  -- What the release was based on: which inspections, which results.
  basis          jsonb not null default '{}'::jsonb,
  inspection_id  uuid,
  signature      text,
  is_withdrawn   boolean not null default false,
  withdrawn_at   timestamptz,
  withdrawn_by   uuid,
  withdrawal_reason text,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  primary key (id),
  foreign key (tenant_id, batch_id) references erp.batch (tenant_id, id) on delete restrict,
  foreign key (tenant_id, released_by) references erp.app_user (tenant_id, id) on delete restrict,
  foreign key (tenant_id, inspection_id)
    references erp.inspection (tenant_id, id) on delete restrict
);

create index on erp.release_record (tenant_id, batch_id);

-- -----------------------------------------------------------------------------
-- Recall
-- -----------------------------------------------------------------------------

create type erp.recall_status as enum (
  'draft', 'assessing', 'notified', 'in_progress', 'reconciling', 'closed', 'cancelled'
);

create table erp.recall (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  entity_id      uuid,
  reference      text not null,
  title          text not null,
  reason         text not null,
  classification text,
  status         erp.recall_status not null default 'draft',
  -- Scope by batch, or by criteria where the batch set is not yet known.
  scope_batch_ids uuid[] not null default '{}'::uuid[],
  scope_criteria jsonb not null default '{}'::jsonb,
  -- Spec 5.8: continuous recall-readiness measured against configurable
  -- regulatory clocks. This is the clock for this recall.
  regulatory_deadline_at timestamptz,
  initiated_at   timestamptz not null default now(),
  initiated_by   uuid,
  notified_at    timestamptz,
  closed_at      timestamptz,
  closed_by      uuid,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, reference),
  foreign key (tenant_id, entity_id) references erp.entity (tenant_id, id) on delete cascade
);

-- The impacted despatch set, captured as a fact at the moment of assessment.
-- Recomputing it later would give a different answer as new movements arrive,
-- and the regulator asked what was known when.
create table erp.recall_impact (
  id             bigint generated always as identity primary key,
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  recall_id      uuid not null,
  captured_at    timestamptz not null default clock_timestamp(),
  batch_id       uuid,
  item_id        uuid,
  movement_id    bigint,
  document_id    uuid,
  party_id       uuid,
  quantity_despatched numeric(20,6),
  uom_id         uuid,
  despatched_at  timestamptz,
  foreign key (tenant_id, recall_id) references erp.recall (tenant_id, id) on delete cascade
);

create index on erp.recall_impact (tenant_id, recall_id);
create index on erp.recall_impact (tenant_id, recall_id, party_id);

create table erp.recall_action (
  id             bigint generated always as identity primary key,
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  recall_id      uuid not null,
  occurred_at    timestamptz not null default clock_timestamp(),
  action_kind    text not null,
  party_id       uuid,
  recall_impact_id bigint,
  quantity_recovered numeric(20,6),
  note           text,
  actor_id       uuid,
  evidence_ref   text,
  foreign key (tenant_id, recall_id) references erp.recall (tenant_id, id) on delete cascade
);

create index on erp.recall_action (tenant_id, recall_id, occurred_at);

-- Spec 4.8: reconciliation of recovered and unaccounted quantity. The number
-- that matters in a recall is not what was recovered but what is still out
-- there, so it is computed rather than reported.
create or replace function erp.recall_reconciliation(p_recall_id uuid)
returns table (
  batch_id            uuid,
  item_id             uuid,
  quantity_despatched numeric,
  quantity_recovered  numeric,
  quantity_unaccounted numeric,
  customers_affected  bigint)
language sql
stable
security invoker
set search_path = ''
as $$
  select i.batch_id, i.item_id,
         sum(i.quantity_despatched) as despatched,
         coalesce(sum(a.recovered), 0) as recovered,
         sum(i.quantity_despatched) - coalesce(sum(a.recovered), 0) as unaccounted,
         count(distinct i.party_id) as customers
    from erp.recall_impact i
    left join lateral (
      select sum(ra.quantity_recovered) as recovered
        from erp.recall_action ra
       where ra.tenant_id = i.tenant_id
         and ra.recall_id = i.recall_id
         and ra.recall_impact_id = i.id
    ) a on true
   where i.tenant_id = erp.require_tenant_id()
     and i.recall_id = p_recall_id
   group by i.batch_id, i.item_id
$$;

comment on function erp.recall_reconciliation(uuid) is
  'Spec 4.8: reconciliation of recovered and unaccounted quantity. Unaccounted '
  'is the number a regulator asks for, so it is derived rather than reported.';

-- Capture the impacted set. Uses the traceability functions, so a recall of a
-- raw material reaches the finished goods made from it.
create or replace function erp.capture_recall_impact(p_recall_id uuid)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  r        erp.recall%rowtype;
  b        uuid;
  v_count  integer := 0;
begin
  select * into r from erp.recall where tenant_id = v_tenant and id = p_recall_id;

  if not found then
    raise exception 'ERPWARE_RECALL_NOT_FOUND: %', p_recall_id using errcode = '23503';
  end if;

  foreach b in array r.scope_batch_ids loop
    insert into erp.recall_impact (
      tenant_id, recall_id, batch_id, item_id, movement_id, document_id,
      party_id, quantity_despatched, despatched_at)
    select v_tenant, p_recall_id, t.batch_id, t.item_id, t.movement_id,
           t.document_id,
           (select d.party_id from erp.document d where d.id = t.document_id),
           t.quantity, t.occurred_at
      from erp.trace_batch_despatches(b) t;

    get diagnostics v_count = row_count;
  end loop;

  update erp.recall set status = 'assessing', updated_at = now()
   where id = p_recall_id and status = 'draft';

  return (select count(*)::integer from erp.recall_impact
           where tenant_id = v_tenant and recall_id = p_recall_id);
end;
$$;

select erp_meta.register_table('erp', 'forecast_accuracy', 'tenant_scoped_append_only',
  'Measured facts about how the forecast performed. Not amendable after the fact.');
select erp_meta.register_table('erp', 'recall_impact', 'tenant_scoped_append_only',
  'Spec 4.8: the impacted despatch set as known at assessment time. Recomputing it later gives a different answer.');
select erp_meta.register_table('erp', 'recall_action', 'tenant_scoped_append_only',
  'The action log of a recall. Evidence for a regulator.');

insert into erp_meta.audit_exemption (schema_name, table_name, rationale) values
  ('erp', 'forecast_accuracy', 'Append-only measurements with their own timestamps.'),
  ('erp', 'recall_impact', 'Append-only capture of what was known when.'),
  ('erp', 'recall_action', 'Append-only action log carrying its own actor and evidence reference.')
on conflict (schema_name, table_name) do update set rationale = excluded.rationale;

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_isolation();
