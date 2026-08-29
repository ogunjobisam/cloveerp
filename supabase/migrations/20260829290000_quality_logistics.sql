-- =============================================================================
-- ERPWare — Part 5.8 (quality, compliance, traceability) and 5.9 (logistics)
--
-- Quality is the same story again, and the most pointed instance of it. B7
-- built inspection plans with sampling rules, inspections with dispositions,
-- inspection results with limits, quality events with root cause and corrective
-- action fields, release records with a qualified role and a signature, recalls
-- with regulatory deadlines and impact capture and a reconciliation that
-- derives the unaccounted quantity a regulator asks for.
--
-- Nothing writes any of it. There has never been an inspection, a release, a
-- deviation or a recall in this product.
--
-- That matters more here than elsewhere, because the whole point of batch
-- traceability — which B7 does implement, and which the production module now
-- populates — is that a recall can be executed. A traceability graph nobody can
-- act on is a data structure.
--
-- Logistics (5.9) has nothing at all: no shipment, no carrier, no freight
-- allocation, no proof of delivery, no delivery performance. That half is built
-- from nothing here.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Inspection and sampling
--
-- The sampling rule is configuration, and it has to be, because the answer to
-- "how many do we check" is a regulatory and commercial question that differs
-- per item, per customer and per jurisdiction. Three schemes, which is what
-- covers real practice:
--
--   {"scheme":"all"}                       every unit
--   {"scheme":"fixed","size":5}            a fixed sample
--   {"scheme":"sqrt","plus":1}             the square-root-plus-one rule,
--                                          which is what most food and
--                                          pharmaceutical inbound QC actually
--                                          uses
-- -----------------------------------------------------------------------------

create or replace function erp.sample_size(p_rule jsonb, p_lot numeric)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select least(p_lot, greatest(1, case coalesce(p_rule ->> 'scheme', 'sqrt')
    when 'all'   then p_lot
    when 'fixed' then coalesce((p_rule ->> 'size')::numeric, 1)
    else ceil(sqrt(p_lot)) + coalesce((p_rule ->> 'plus')::numeric, 1)
  end))
$$;

comment on function erp.sample_size(jsonb, numeric) is
  'Spec 5.8: sampling. Configuration rather than code, because how many units '
  'are checked is a regulatory and commercial question that differs per item, '
  'per customer and per jurisdiction.';

create or replace function erp.raise_inspection(
  p_item_id  uuid,
  p_site_id  uuid,
  p_quantity numeric,
  p_batch_id uuid default null,
  p_document_id uuid default null,
  p_trigger  text default 'receipt'
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  pl       erp.inspection_plan%rowtype;
  v_class  text;
  v_id     uuid;
  v_entity uuid;
begin
  select i.item_class into v_class from erp.item i
   where i.tenant_id = v_tenant and i.id = p_item_id;

  select * into pl from erp.inspection_plan p
   where p.tenant_id = v_tenant and p.status = 'active'
     and p.trigger_point = p_trigger
     and (p.item_id = p_item_id or (p.item_id is null and p.item_class = v_class)
          or (p.item_id is null and p.item_class is null))
   order by (p.item_id is not null) desc, (p.item_class is not null) desc, p.code
   limit 1;

  if not found then
    -- No plan is not an error: most items are not inspected. Returning null
    -- rather than raising lets a caller ask "does this need checking" without
    -- handling an exception for the ordinary case.
    return null;
  end if;

  select s.entity_id into v_entity from erp.site s where s.id = p_site_id;

  insert into erp.inspection (
    tenant_id, entity_id, site_id, inspection_plan_id, item_id, batch_id,
    document_id, quantity_inspected, sample_size, status, started_at)
  values (v_tenant, v_entity, p_site_id, pl.id, p_item_id, p_batch_id,
          p_document_id, p_quantity,
          erp.sample_size(pl.sampling_rule, p_quantity), 'planned', now())
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function erp.record_inspection_result(
  p_inspection_id uuid,
  p_characteristic text,
  p_numeric_value numeric default null,
  p_text_value text default null,
  p_instrument text default null
) returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  insp     erp.inspection%rowtype;
  pl       erp.inspection_plan%rowtype;
  ch       jsonb;
  v_lower  numeric;
  v_upper  numeric;
  v_in     boolean;
begin
  select * into insp from erp.inspection
   where tenant_id = v_tenant and id = p_inspection_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_INSPECTION: %', p_inspection_id using errcode = '23503';
  end if;

  perform erp.authorise('quality.inspect', insp.entity_id, insp.site_id, null,
                        'inspection', p_inspection_id);

  select * into pl from erp.inspection_plan where id = insp.inspection_plan_id;

  select c into ch from jsonb_array_elements(pl.characteristics) c
   where c ->> 'code' = p_characteristic;

  if ch is null then
    raise exception
      'ERPWARE_UNKNOWN_CHARACTERISTIC: % is not on plan %', p_characteristic, pl.code
      using errcode = '23503',
      hint = 'Recording a result the plan does not ask for makes the plan and '
             'the record disagree about what was checked.';
  end if;

  v_lower := (ch ->> 'lower')::numeric;
  v_upper := (ch ->> 'upper')::numeric;

  -- Within spec is computed, never supplied. An inspector who can type the
  -- verdict is an inspector whose limits are decoration.
  v_in := case
    when p_numeric_value is null then
      -- A text characteristic passes when it matches the expected value; where
      -- the plan states none, recording it is the check.
      coalesce(ch ->> 'expected', p_text_value) = p_text_value
    else coalesce(p_numeric_value >= v_lower, true)
         and coalesce(p_numeric_value <= v_upper, true)
  end;

  insert into erp.inspection_result (
    tenant_id, inspection_id, characteristic, numeric_value, text_value,
    lower_limit, upper_limit, is_within_spec, recorded_by, recorded_at, instrument)
  values (v_tenant, p_inspection_id, p_characteristic, p_numeric_value,
          p_text_value, v_lower, v_upper, v_in, erp.current_principal_id(),
          now(), p_instrument);

  return v_in;
end;
$$;

create or replace function erp.disposition_inspection(
  p_inspection_id uuid,
  p_disposition erp.disposition,
  p_note text default null
) returns erp.disposition
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  insp     erp.inspection%rowtype;
  pl       erp.inspection_plan%rowtype;
  v_missing text;
  v_failed  integer;
begin
  select * into insp from erp.inspection
   where tenant_id = v_tenant and id = p_inspection_id for update;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_INSPECTION: %', p_inspection_id using errcode = '23503';
  end if;

  perform erp.authorise('quality.disposition', insp.entity_id, insp.site_id, null,
                        'inspection', p_inspection_id);

  select * into pl from erp.inspection_plan where id = insp.inspection_plan_id;

  -- Every characteristic the plan asks for must have a result. Dispositioning
  -- on a partial record is how a batch is released on the two tests that were
  -- convenient.
  select string_agg(c ->> 'code', ', ') into v_missing
    from jsonb_array_elements(pl.characteristics) c
   where not exists (select 1 from erp.inspection_result ir
                      where ir.inspection_id = p_inspection_id
                        and ir.characteristic = c ->> 'code');

  if v_missing is not null then
    raise exception
      'ERPWARE_INSPECTION_INCOMPLETE: no result for %', v_missing
      using errcode = '23514',
      hint = 'A disposition on a partial record releases a batch on the tests '
             'that were convenient.';
  end if;

  select count(*) into v_failed from erp.inspection_result ir
   where ir.inspection_id = p_inspection_id and not ir.is_within_spec;

  -- Accepting a failed inspection is a decision somebody may legitimately
  -- make, and it is a different decision — so it needs a reason, and the
  -- reason is on the record for ever.
  if v_failed > 0 and p_disposition = 'accept' and coalesce(p_note, '') = '' then
    raise exception
      'ERPWARE_CONCESSION_NEEDS_REASON: % result(s) are out of specification '
      'and accepting anyway is a concession', v_failed
      using errcode = '23514';
  end if;

  update erp.inspection
     set status = 'complete', disposition = p_disposition,
         disposition_by = erp.current_principal_id(), disposition_at = now(),
         disposition_note = p_note, completed_at = now(), updated_at = now()
   where id = p_inspection_id;

  return p_disposition;
end;
$$;

-- -----------------------------------------------------------------------------
-- Quarantine, and authorised release
--
-- Spec 5.8: "quarantine control with authorised release". Authorised is the
-- word doing the work: erp.release_record carries qualified_role_code and a
-- signature, which only mean something if the release refuses to happen without
-- them. Until now nothing wrote that table, so quarantine was a status a batch
-- sat in and left whenever somebody moved it.
-- -----------------------------------------------------------------------------

create or replace function erp.release_batch(
  p_batch_id uuid,
  p_site_id  uuid,
  p_basis    text,
  p_signature text,
  p_inspection_id uuid default null
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.batch%rowtype;
  v_qty    numeric;
  v_from   uuid;
  v_to     uuid;
  v_uom    uuid;
  v_entity uuid;
  v_id     uuid;
  v_disp   erp.disposition;
begin
  select * into b from erp.batch where tenant_id = v_tenant and id = p_batch_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_BATCH: %', p_batch_id using errcode = '23503';
  end if;

  if coalesce(p_signature, '') = '' or coalesce(p_basis, '') = '' then
    raise exception
      'ERPWARE_RELEASE_NEEDS_BASIS_AND_SIGNATURE: a qualified release is a '
      'signed statement, not a status change'
      using errcode = '23514';
  end if;

  -- The qualified role. A distinct permission from inspecting, because the
  -- person who ran the test and the person who takes responsibility for the
  -- batch are not required to be the same and in regulated industries must not
  -- be assumed to be.
  perform erp.authorise('quality.release_batch', null, p_site_id, null,
                        'batch', p_batch_id);

  if p_inspection_id is not null then
    select disposition into v_disp from erp.inspection
     where tenant_id = v_tenant and id = p_inspection_id;

    if v_disp is null or v_disp in ('reject', 'destroy', 'pending') then
      raise exception
        'ERPWARE_RELEASE_AGAINST_FAILED_INSPECTION: the inspection was %',
        coalesce(v_disp::text, 'not dispositioned')
        using errcode = '42501';
    end if;
  end if;

  select coalesce(sum(sb.quantity), 0),
         (array_agg(sb.location_id order by sb.quantity desc))[1]
    into v_qty, v_from
    from erp.stock_balance sb
   where sb.tenant_id = v_tenant and sb.batch_id = p_batch_id
     and sb.site_id = p_site_id and sb.stock_status = 'quarantine'
     and sb.quantity > 0;

  if coalesce(v_qty, 0) = 0 then
    raise exception 'ERPWARE_NOTHING_IN_QUARANTINE: % has nothing held here',
      b.batch_number using errcode = '23514';
  end if;

  select i.stock_uom_id into v_uom from erp.item i where i.id = b.item_id;
  select s.entity_id into v_entity from erp.site s where s.id = p_site_id;

  -- Released stock stays where it is; what changes is what it may be used for.
  -- A status change is a movement in this ledger, which is what keeps the
  -- balances derivable.
  insert into erp.stock_movement (
    tenant_id, entity_id, site_id, movement_type, item_id, batch_id,
    from_location_id, from_status, to_location_id, to_status,
    quantity, uom_id, reason_code)
  values (v_tenant, v_entity, p_site_id, 'status_change', b.item_id, p_batch_id,
          v_from, 'quarantine', v_from, 'available', v_qty, v_uom,
          'qualified_release');

  update erp.batch set status = 'released', updated_at = now()
   where id = p_batch_id;

  insert into erp.release_record (
    tenant_id, batch_id, released_by, released_at, qualified_role_code,
    basis, inspection_id, signature)
  values (v_tenant, p_batch_id, erp.current_principal_id(), now(),
          'quality.release_batch', jsonb_build_object('statement', p_basis),
          p_inspection_id, p_signature)
  returning id into v_id;

  return v_id;
end;
$$;

comment on function erp.release_batch(uuid, uuid, text, text, uuid) is
  'Spec 5.8: quarantine control with authorised release. The signature and the '
  'basis are required, because erp.release_record has carried both since B7 and '
  'they only mean anything if the release refuses without them.';

-- -----------------------------------------------------------------------------
-- Deviations, non-conformances and corrective action
--
-- One table, because they are one thing at different severities, and B7 was
-- right to model them that way. What was missing is the discipline: an event
-- without a due date is one nobody chases, and a corrective action with no
-- preventive action is a repair rather than a fix.
-- -----------------------------------------------------------------------------

create or replace function erp.raise_quality_event(
  p_kind erp.quality_event_kind,
  p_title text,
  p_severity text,
  p_site_id uuid default null,
  p_item_id uuid default null,
  p_batch_id uuid default null,
  p_document_id uuid default null,
  p_party_id uuid default null,
  p_due_in interval default '14 days'
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_entity uuid;
  v_id     uuid;
begin
  perform erp.authorise('quality.disposition', null, p_site_id, null,
                        'quality_event', null);

  select s.entity_id into v_entity from erp.site s where s.id = p_site_id;

  insert into erp.quality_event (
    tenant_id, entity_id, site_id, reference, event_kind, severity, title,
    item_id, batch_id, document_id, party_id, occurred_at, detected_at,
    reported_by, due_at, status)
  values (v_tenant, v_entity, p_site_id,
          'QE-' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS'),
          p_kind, p_severity, p_title, p_item_id, p_batch_id, p_document_id,
          p_party_id, now(), now(), erp.current_principal_id(),
          -- A due date always. An event with none is one nobody chases, and
          -- the ones nobody chases are the ones that appear in an audit.
          now() + p_due_in, 'open')
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function erp.close_quality_event(
  p_event_id uuid,
  p_root_cause text,
  p_corrective_action text,
  p_preventive_action text
) returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  e        erp.quality_event%rowtype;
begin
  select * into e from erp.quality_event
   where tenant_id = v_tenant and id = p_event_id for update;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_QUALITY_EVENT: %', p_event_id using errcode = '23503';
  end if;

  perform erp.authorise('quality.disposition', e.entity_id, e.site_id, null,
                        'quality_event', p_event_id);

  if coalesce(p_root_cause, '') = '' then
    raise exception
      'ERPWARE_NO_ROOT_CAUSE: closing without one records that it stopped '
      'happening, not why' using errcode = '23514';
  end if;

  -- Corrective fixes this one; preventive stops the next. B7 gave the table
  -- both columns and they are different questions: a repair is not a fix.
  if coalesce(p_corrective_action, '') = ''
     or coalesce(p_preventive_action, '') = '' then
    raise exception
      'ERPWARE_NO_PREVENTIVE_ACTION: corrective action repairs this occurrence '
      'and preventive action stops the next; closing needs both'
      using errcode = '23514';
  end if;

  update erp.quality_event
     set root_cause = p_root_cause,
         corrective_action = p_corrective_action,
         preventive_action = p_preventive_action,
         status = 'closed', closed_at = now(),
         closed_by = erp.current_principal_id(), updated_at = now()
   where id = p_event_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- Condition excursions, and what they touched
--
-- Spec 5.8: "condition excursion handling with batch impact assessment". A
-- temperature excursion in a chiller is not interesting; what was in the
-- chiller at the time is. The assessment is the whole feature.
-- -----------------------------------------------------------------------------

create or replace function erp.assess_excursion_impact(
  p_site_id  uuid,
  p_location_id uuid,
  p_from     timestamptz,
  p_to       timestamptz
) returns table (batch_id uuid, batch_number text, item_code text,
                 quantity_present numeric, quantity_since_despatched numeric,
                 still_on_hand numeric)
language sql
stable
security invoker
set search_path = ''
as $$
  -- What was in the location during the window, reconstructed from the ledger
  -- rather than from a current balance: the point of an excursion assessment
  -- is that some of it has already left.
  with present as (
    select m.batch_id, m.item_id,
           sum(case when m.to_location_id = p_location_id then m.quantity
                    when m.from_location_id = p_location_id then -m.quantity
                    else 0 end) as qty
      from erp.stock_movement m
     where m.tenant_id = erp.current_tenant_id()
       and m.site_id = p_site_id
       and (m.to_location_id = p_location_id or m.from_location_id = p_location_id)
       and m.occurred_at <= p_to
       and not m.is_reversal
     group by m.batch_id, m.item_id
    having sum(case when m.to_location_id = p_location_id then m.quantity
                    when m.from_location_id = p_location_id then -m.quantity
                    else 0 end) > 0
       or exists (select 1 from erp.stock_movement m2
                   where m2.tenant_id = erp.current_tenant_id()
                     and m2.batch_id is not distinct from m.batch_id
                     and m2.from_location_id = p_location_id
                     and m2.occurred_at between p_from and p_to)
  )
  select p.batch_id, b.batch_number, i.code, p.qty,
         coalesce((select sum(m3.quantity) from erp.stock_movement m3
                    join erp_ref.movement_type mt on mt.code = m3.movement_type
                   where m3.tenant_id = erp.current_tenant_id()
                     and m3.batch_id is not distinct from p.batch_id
                     and mt.direction = 'out' and m3.occurred_at >= p_from), 0),
         coalesce((select sum(sb.quantity) from erp.stock_balance sb
                    where sb.tenant_id = erp.current_tenant_id()
                      and sb.batch_id is not distinct from p.batch_id), 0)
    from present p
    left join erp.batch b on b.id = p.batch_id
    left join erp.item i on i.id = p.item_id
   order by 5 desc
$$;

comment on function erp.assess_excursion_impact(uuid, uuid, timestamptz, timestamptz) is
  'Spec 5.8: batch impact assessment. Reconstructed from the ledger rather than '
  'read from current balances, because the point of an assessment is that some '
  'of what was affected has already left.';

-- -----------------------------------------------------------------------------
-- Recall
--
-- B7 built the impact capture and the reconciliation. What was missing is the
-- part a regulator actually asks about: how long it takes, measured, before
-- anybody needs it.
--
-- Spec 5.8: "continuous recall-readiness measurement against configurable
-- regulatory clocks". Continuous is the requirement. A recall drill once a year
-- measures the drill; measuring every recall against the clock that applies to
-- it measures the capability.
-- -----------------------------------------------------------------------------

create table if not exists erp.regulatory_clock (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  code         text not null,
  name         text not null,
  jurisdiction text,
  -- How long from deciding to recall to having the impacted set identified,
  -- and how long to having notified the affected customers.
  identify_within interval not null,
  notify_within   interval not null,
  legislation_pack_code text,
  status       erp.record_status not null default 'active',
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code)
);

comment on table erp.regulatory_clock is
  'Spec 5.8: the configurable regulatory clock. Four hours to identify is a '
  'different product from four days, and which applies is a jurisdiction''s '
  'answer rather than ours.';

create or replace function erp.raise_recall(
  p_title text,
  p_reason text,
  p_classification text,
  p_batch_ids uuid[],
  p_clock_code text default null
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_entity uuid;
  cl       erp.regulatory_clock%rowtype;
  v_id     uuid;
begin
  perform erp.authorise('quality.recall', null, null, null, 'recall', null);

  if coalesce(array_length(p_batch_ids, 1), 0) = 0 then
    raise exception 'ERPWARE_RECALL_WITHOUT_SCOPE: a recall of nothing'
      using errcode = '23514';
  end if;

  select e.id into v_entity from erp.entity e
   where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;

  select * into cl from erp.regulatory_clock
   where tenant_id = v_tenant and status = 'active'
     and (p_clock_code is null or code = p_clock_code)
   order by (code = coalesce(p_clock_code, '')) desc, code limit 1;

  insert into erp.recall (
    tenant_id, entity_id, reference, title, reason, classification, status,
    scope_batch_ids, regulatory_deadline_at, initiated_at, initiated_by)
  values (v_tenant, v_entity,
          'RC-' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISS'),
          -- 'assessing', not 'open': the recall is raised and the impacted
          -- set is not yet known, which is exactly the state the clock is
          -- measuring the length of.
          p_title, p_reason, p_classification, 'assessing', p_batch_ids,
          -- The deadline is derived from the clock, not typed. A deadline
          -- somebody enters is one that moves.
          now() + coalesce(cl.notify_within, interval '72 hours'),
          now(), erp.current_principal_id())
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function erp.log_recall_action(
  p_recall_id uuid,
  p_action_kind text,
  p_party_id uuid default null,
  p_impact_id bigint default null,
  p_quantity_recovered numeric default null,
  p_note text default null,
  p_evidence_ref text default null
) returns bigint
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id     bigint;
begin
  perform erp.authorise('quality.recall', null, null, null, 'recall', p_recall_id);

  insert into erp.recall_action (
    tenant_id, recall_id, occurred_at, action_kind, party_id, recall_impact_id,
    quantity_recovered, note, actor_id, evidence_ref)
  values (v_tenant, p_recall_id, clock_timestamp(), p_action_kind, p_party_id,
          p_impact_id, p_quantity_recovered, p_note,
          erp.current_principal_id(), p_evidence_ref)
  returning id into v_id;

  -- Notification is what the clock is measured against, so the moment the
  -- first customer is told is recorded on the recall itself rather than left
  -- to be inferred from the action log later.
  if p_action_kind = 'notified' then
    update erp.recall set notified_at = coalesce(notified_at, now()), updated_at = now()
     where tenant_id = v_tenant and id = p_recall_id;
  end if;

  return v_id;
end;
$$;

create or replace function erp.recall_readiness(p_recall_id uuid default null)
returns table (reference text, classification text,
               initiated_at timestamptz, identified_at timestamptz,
               notified_at timestamptz,
               time_to_identify interval, time_to_notify interval,
               identify_target interval, notify_target interval,
               within_identify boolean, within_notify boolean,
               impacted_customers bigint, unaccounted_quantity numeric)
language sql
stable
security invoker
set search_path = ''
as $$
  select rc.reference, rc.classification, rc.initiated_at,
         (select min(ri.captured_at) from erp.recall_impact ri
           where ri.recall_id = rc.id),
         rc.notified_at,
         (select min(ri.captured_at) from erp.recall_impact ri
           where ri.recall_id = rc.id) - rc.initiated_at,
         rc.notified_at - rc.initiated_at,
         cl.identify_within, cl.notify_within,
         -- Null where it has not happened yet, which is deliberately not the
         -- same as false: a recall still running is not a recall that missed.
         case when (select min(ri.captured_at) from erp.recall_impact ri
                     where ri.recall_id = rc.id) is null then null
              else (select min(ri.captured_at) from erp.recall_impact ri
                     where ri.recall_id = rc.id) - rc.initiated_at
                   <= coalesce(cl.identify_within, interval '4 hours') end,
         case when rc.notified_at is null then null
              else rc.notified_at - rc.initiated_at
                   <= coalesce(cl.notify_within, interval '72 hours') end,
         (select count(distinct ri.party_id) from erp.recall_impact ri
           where ri.recall_id = rc.id),
         coalesce((select sum(rr.quantity_unaccounted)
                     from erp.recall_reconciliation(rc.id) rr), 0)
    from erp.recall rc
    left join erp.regulatory_clock cl
      on cl.tenant_id = rc.tenant_id and cl.status = 'active'
   where rc.tenant_id = erp.current_tenant_id()
     and (p_recall_id is null or rc.id = p_recall_id)
   order by rc.initiated_at desc
$$;

comment on function erp.recall_readiness(uuid) is
  'Spec 5.8: continuous recall-readiness measurement. Every recall measured '
  'against the clock that applies to it — a drill once a year measures the '
  'drill, and this measures the capability.';

create or replace function erp.recall_evidence(p_recall_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  -- Spec 5.8: "evidence export". One document, assembled: what was recalled,
  -- who had it, what was done, what came back, and what did not.
  select jsonb_build_object(
    'recall', to_jsonb(rc) - 'tenant_id',
    'readiness', (select to_jsonb(rd) from erp.recall_readiness(rc.id) rd),
    'impacted', coalesce((
      select jsonb_agg(jsonb_build_object(
               'batch', b.batch_number, 'item', i.code,
               'customer', p.name, 'quantity', ri.quantity_despatched,
               'despatched_at', ri.despatched_at,
               'document', d.document_number) order by ri.despatched_at)
        from erp.recall_impact ri
        left join erp.batch b on b.id = ri.batch_id
        left join erp.item i on i.id = ri.item_id
        left join erp.party p on p.id = ri.party_id
        left join erp.document d on d.id = ri.document_id
       where ri.recall_id = rc.id), '[]'::jsonb),
    'actions', coalesce((
      select jsonb_agg(jsonb_build_object(
               'at', ra.occurred_at, 'kind', ra.action_kind,
               'customer', ap.name, 'recovered', ra.quantity_recovered,
               'by', u.display_name, 'evidence', ra.evidence_ref,
               'note', ra.note) order by ra.occurred_at)
        from erp.recall_action ra
        left join erp.party ap on ap.id = ra.party_id
        left join erp.app_user u on u.id = ra.actor_id
       where ra.recall_id = rc.id), '[]'::jsonb),
    'reconciliation', coalesce((
      select jsonb_agg(to_jsonb(rr)) from erp.recall_reconciliation(rc.id) rr),
      '[]'::jsonb))
    from erp.recall rc
   where rc.tenant_id = erp.current_tenant_id() and rc.id = p_recall_id
$$;

-- =============================================================================
-- Part 5.9 — Logistics
--
-- Nothing of this existed. A delivery in this product left a site and arrived
-- nowhere: there was no shipment, no carrier, no freight cost, no proof of
-- delivery and no way to ask whether anything arrived when it was promised.
-- =============================================================================

create type erp.shipment_status as enum
  ('planning', 'planned', 'tendered', 'booked', 'despatched', 'delivered',
   'exception', 'cancelled');

create table if not exists erp.carrier (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  code         text not null,
  name         text not null,
  party_id     uuid,
  -- What this carrier does and what it costs, as data: a service that takes
  -- two days for a fixed fee plus a rate per kilogram is the whole of most
  -- carrier tariffs, and expressing it as configuration is what lets selection
  -- be a query rather than a phone call.
  services     jsonb not null default '[]'::jsonb,
  status       erp.record_status not null default 'active',
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code),
  foreign key (tenant_id, party_id) references erp.party (tenant_id, id) on delete restrict
);

create table if not exists erp.shipment (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  entity_id    uuid not null,
  site_id      uuid not null,
  reference    text not null,
  carrier_id   uuid,
  service_code text,
  status       erp.shipment_status not null default 'planning',
  planned_despatch date,
  planned_arrival  date,
  actual_despatch  timestamptz,
  actual_arrival   timestamptz,
  destination_party_id uuid,
  destination_country char(2),
  total_weight_g   numeric(20,6) not null default 0,
  freight_cost_minor bigint,
  currency     char(3),
  tracking_reference text,
  proof_of_delivery  jsonb,
  customs_reference  text,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, reference),
  foreign key (tenant_id, entity_id) references erp.entity (tenant_id, id) on delete restrict,
  foreign key (tenant_id, site_id) references erp.site (tenant_id, id) on delete restrict,
  foreign key (tenant_id, carrier_id) references erp.carrier (tenant_id, id) on delete restrict,
  foreign key (tenant_id, destination_party_id)
    references erp.party (tenant_id, id) on delete restrict
);

create table if not exists erp.shipment_line (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  shipment_id  uuid not null,
  document_id  uuid not null,
  weight_g     numeric(20,6) not null default 0,
  freight_share_minor bigint,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, shipment_id, document_id),
  foreign key (tenant_id, shipment_id) references erp.shipment (tenant_id, id) on delete cascade,
  foreign key (tenant_id, document_id) references erp.document (tenant_id, id) on delete restrict
);

-- Consolidation: several deliveries on one shipment, which is the entire point
-- of shipment planning. A one-delivery-one-shipment model is a rename.
create or replace function erp.plan_shipment(
  p_site_id uuid,
  p_delivery_ids uuid[],
  p_planned_despatch date default null
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_entity uuid;
  v_ship   uuid;
  d        uuid;
  v_party  uuid;
  v_weight numeric;
  v_n      integer := 0;
begin
  perform erp.authorise('logistics.plan', null, p_site_id, null, 'shipment', null);

  if coalesce(array_length(p_delivery_ids, 1), 0) = 0 then
    raise exception 'ERPWARE_EMPTY_SHIPMENT: a shipment of nothing' using errcode = '23514';
  end if;

  select s.entity_id into v_entity from erp.site s where s.id = p_site_id;

  insert into erp.shipment (
    tenant_id, entity_id, site_id, reference, status, planned_despatch)
  values (v_tenant, v_entity, p_site_id,
          'SH-' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS'),
          'planning', coalesce(p_planned_despatch, current_date))
  returning id into v_ship;

  foreach d in array p_delivery_ids loop
    select dc.party_id into v_party from erp.document dc
     where dc.tenant_id = v_tenant and dc.id = d;

    -- Consolidating deliveries to different customers onto one shipment is a
    -- different operation (a groupage load with a break-bulk) and modelling it
    -- as this one is how a delivery goes to the wrong address.
    if v_n > 0 and v_party is distinct from
       (select sp.destination_party_id from erp.shipment sp where sp.id = v_ship) then
      raise exception
        'ERPWARE_MIXED_DESTINATIONS: this shipment is for one customer; a '
        'groupage load is a different thing and needs to say so'
        using errcode = '23514';
    end if;

    select coalesce(sum(dl.quantity * coalesce(i.gross_weight_g, 0)), 0)
      into v_weight
      from erp.document_line dl
      left join erp.item i on i.id = dl.item_id
     where dl.tenant_id = v_tenant and dl.document_id = d and not dl.is_cancelled;

    insert into erp.shipment_line (tenant_id, shipment_id, document_id, weight_g)
    values (v_tenant, v_ship, d, v_weight);

    update erp.shipment
       set destination_party_id = v_party,
           total_weight_g = total_weight_g + v_weight,
           updated_at = now()
     where id = v_ship;

    v_n := v_n + 1;
  end loop;

  update erp.shipment set status = 'planned', updated_at = now() where id = v_ship;

  return v_ship;
end;
$$;

-- Spec 5.9: "carrier selection by cost and service rules". Both, because the
-- cheapest carrier that arrives after the promise date costs more than the
-- expensive one that does not.
create or replace function erp.select_carrier(
  p_shipment_id uuid,
  p_required_by date default null
) returns table (carrier_code text, carrier_name text, service_code text,
                 transit_days integer, cost_minor bigint, meets_date boolean,
                 recommended boolean)
language sql
stable
security invoker
set search_path = ''
as $$
  with s as (
    select * from erp.shipment
     where tenant_id = erp.current_tenant_id() and id = p_shipment_id
  ),
  offers as (
    select c.code, c.name, sv.value ->> 'code' as svc,
           (sv.value ->> 'transit_days')::integer as days,
           (coalesce((sv.value ->> 'base_minor')::bigint, 0)
            + round(coalesce((sv.value ->> 'per_kg_minor')::bigint, 0)
                    * s.total_weight_g / 1000.0))::bigint as cost
      from erp.carrier c
      cross join lateral jsonb_array_elements(c.services) sv
      cross join s
     where c.tenant_id = erp.current_tenant_id() and c.status = 'active'
  )
  select o.code, o.name, o.svc, o.days, o.cost,
         (s.planned_despatch + o.days) <= coalesce(p_required_by, s.planned_arrival,
                                                   s.planned_despatch + o.days),
         o.cost = (select min(o2.cost) from offers o2, s s2
                    where (s2.planned_despatch + o2.days)
                          <= coalesce(p_required_by, s2.planned_arrival,
                                      s2.planned_despatch + o2.days))
    from offers o, s
   -- Cheapest first among those that arrive in time, then the rest. Ordering
   -- purely by cost recommends a carrier that misses the date.
   order by ((s.planned_despatch + o.days)
             <= coalesce(p_required_by, s.planned_arrival,
                         s.planned_despatch + o.days)) desc,
            o.cost
$$;

create or replace function erp.book_shipment(
  p_shipment_id uuid,
  p_carrier_code text,
  p_service_code text,
  p_cost_minor bigint default null
) returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  sh       erp.shipment%rowtype;
  v_carrier uuid;
  v_cost   bigint;
  v_days   integer;
  r        record;
  v_total  numeric;
begin
  select * into sh from erp.shipment
   where tenant_id = v_tenant and id = p_shipment_id for update;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_SHIPMENT: %', p_shipment_id using errcode = '23503';
  end if;

  perform erp.authorise('logistics.plan', sh.entity_id, sh.site_id, null,
                        'shipment', p_shipment_id);

  select c.id into v_carrier from erp.carrier c
   where c.tenant_id = v_tenant and c.code = p_carrier_code and c.status = 'active';

  if v_carrier is null then
    raise exception 'ERPWARE_UNKNOWN_CARRIER: %', p_carrier_code using errcode = '23503';
  end if;

  select o.cost_minor, o.transit_days into v_cost, v_days
    from erp.select_carrier(p_shipment_id) o
   where o.carrier_code = p_carrier_code and o.service_code = p_service_code;

  if v_cost is null and p_cost_minor is null then
    raise exception
      'ERPWARE_NO_TARIFF: % does not quote % and no cost was given',
      p_carrier_code, p_service_code
      using errcode = '23503';
  end if;

  update erp.shipment
     set carrier_id = v_carrier, service_code = p_service_code,
         freight_cost_minor = coalesce(p_cost_minor, v_cost),
         planned_arrival = planned_despatch + coalesce(v_days, 0),
         currency = coalesce(currency,
                             (select e.base_currency from erp.entity e
                               where e.id = sh.entity_id)),
         status = 'booked', updated_at = now()
   where id = p_shipment_id;

  -- Spec 5.9: "freight cost capture and allocation". By weight, which is what
  -- the carrier charged for; spreading it evenly across deliveries of very
  -- different sizes would put the cost on the wrong customer.
  select sum(sl.weight_g) into v_total from erp.shipment_line sl
   where sl.tenant_id = v_tenant and sl.shipment_id = p_shipment_id;

  for r in select * from erp.shipment_line sl
            where sl.tenant_id = v_tenant and sl.shipment_id = p_shipment_id
  loop
    update erp.shipment_line
       set freight_share_minor = case
             when coalesce(v_total, 0) = 0
               -- Nothing has a weight, so weight cannot apportion it. Splitting
               -- equally is stated rather than silently assumed.
               then round(coalesce(p_cost_minor, v_cost)
                          / (select count(*) from erp.shipment_line sl2
                              where sl2.shipment_id = p_shipment_id))::bigint
             else round(coalesce(p_cost_minor, v_cost) * r.weight_g / v_total)::bigint
           end,
           updated_at = now()
     where id = r.id;
  end loop;
end;
$$;

create or replace function erp.record_proof_of_delivery(
  p_shipment_id uuid,
  p_arrived_at timestamptz,
  p_signed_by text,
  p_reference text default null
) returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
begin
  perform erp.authorise('logistics.despatch', null, null, null,
                        'shipment', p_shipment_id);

  update erp.shipment
     set actual_arrival = p_arrived_at,
         status = 'delivered',
         proof_of_delivery = jsonb_build_object(
           'signed_by', p_signed_by, 'at', p_arrived_at,
           'reference', p_reference,
           'recorded_by', erp.current_principal_id()),
         updated_at = now()
   where tenant_id = v_tenant and id = p_shipment_id;

  if not found then
    raise exception 'ERPWARE_UNKNOWN_SHIPMENT: %', p_shipment_id using errcode = '23503';
  end if;
end;
$$;

create or replace function erp.delivery_performance(p_days integer default 90)
returns table (carrier_code text, carrier_name text, shipments bigint,
               on_time bigint, on_time_pct numeric, avg_days_late numeric,
               freight_minor bigint)
language sql
stable
security invoker
set search_path = ''
as $$
  -- Measured against what was promised, not against what the carrier quoted
  -- after the fact. Only delivered shipments count: an undelivered one is not
  -- late until it is, and counting it as late reports a number that improves
  -- when a lorry finally turns up.
  select c.code, c.name, count(*),
         count(*) filter (where sh.actual_arrival::date <= sh.planned_arrival),
         round(100.0 * count(*) filter (where sh.actual_arrival::date <= sh.planned_arrival)
               / nullif(count(*), 0), 2),
         round(avg(greatest(sh.actual_arrival::date - sh.planned_arrival, 0)), 2),
         coalesce(sum(sh.freight_cost_minor), 0)::bigint
    from erp.shipment sh
    join erp.carrier c on c.id = sh.carrier_id
   where sh.tenant_id = erp.current_tenant_id()
     and sh.status = 'delivered'
     and sh.actual_arrival >= now() - (p_days || ' days')::interval
   group by c.code, c.name
   order by 5
$$;

comment on function erp.delivery_performance(integer) is
  'Spec 5.9: delivery performance analysis. Against what was promised, and only '
  'over delivered shipments — counting undelivered ones as late gives a number '
  'that improves when a lorry finally turns up.';

-- -----------------------------------------------------------------------------
-- Audit trail export
--
-- Spec 5.8: "audit trail export by object, period or batch". The third is the
-- one that is hard and the one that matters: everything that happened to a
-- batch, across every table that touched it, in order.
-- -----------------------------------------------------------------------------

create or replace function erp.batch_audit_export(p_batch_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_object(
    'batch', to_jsonb(b) - 'tenant_id',
    'item', (select i.code from erp.item i where i.id = b.item_id),
    'amendments', coalesce((
      select jsonb_agg(jsonb_build_object(
               'at', am.occurred_at, 'field', am.field,
               'from', am.old_value, 'to', am.new_value, 'reason', am.reason)
             order by am.occurred_at)
        from erp.batch_amendment am where am.batch_id = b.id), '[]'::jsonb),
    'movements', coalesce((
      select jsonb_agg(jsonb_build_object(
               'at', m.occurred_at, 'type', m.movement_type,
               'quantity', m.quantity, 'from_status', m.from_status,
               'to_status', m.to_status, 'reason', m.reason_code,
               'by', u.display_name) order by m.occurred_at, m.id)
        from erp.stock_movement m
        left join erp.app_user u on u.id = m.actor_id
       where m.batch_id = b.id), '[]'::jsonb),
    'inspections', coalesce((
      select jsonb_agg(jsonb_build_object(
               'at', ins.completed_at, 'disposition', ins.disposition,
               'sample_size', ins.sample_size,
               'results', (select jsonb_agg(jsonb_build_object(
                             'characteristic', ir.characteristic,
                             'value', coalesce(ir.numeric_value::text, ir.text_value),
                             'within_spec', ir.is_within_spec))
                             from erp.inspection_result ir
                            where ir.inspection_id = ins.id))
             order by ins.completed_at)
        from erp.inspection ins where ins.batch_id = b.id), '[]'::jsonb),
    'releases', coalesce((
      select jsonb_agg(jsonb_build_object(
               'at', rr.released_at, 'by', ru.display_name,
               'role', rr.qualified_role_code, 'basis', rr.basis,
               'withdrawn', rr.is_withdrawn) order by rr.released_at)
        from erp.release_record rr
        left join erp.app_user ru on ru.id = rr.released_by
       where rr.batch_id = b.id), '[]'::jsonb),
    'quality_events', coalesce((
      select jsonb_agg(jsonb_build_object(
               'reference', qe.reference, 'kind', qe.event_kind,
               'severity', qe.severity, 'title', qe.title,
               'root_cause', qe.root_cause, 'status', qe.status)
             order by qe.occurred_at)
        from erp.quality_event qe where qe.batch_id = b.id), '[]'::jsonb),
    'genealogy_parents', coalesce((
      select jsonb_agg(pb.batch_number)
        from erp.batch_genealogy g
        join erp.batch pb on pb.id = g.parent_batch_id
       where g.child_batch_id = b.id), '[]'::jsonb),
    'genealogy_children', coalesce((
      select jsonb_agg(cb.batch_number)
        from erp.batch_genealogy g
        join erp.batch cb on cb.id = g.child_batch_id
       where g.parent_batch_id = b.id), '[]'::jsonb),
    'despatches', coalesce((
      select jsonb_agg(jsonb_build_object(
               'at', td.occurred_at, 'movement', td.movement_type,
               'quantity', td.quantity,
               'document', (select d.document_number from erp.document d
                             where d.id = td.document_id),
               'customer', (select p.name from erp.document d
                              join erp.party p on p.id = d.party_id
                             where d.id = td.document_id))
             order by td.occurred_at)
        from erp.trace_batch_despatches(b.id) td), '[]'::jsonb))
    from erp.batch b
   where b.tenant_id = erp.current_tenant_id() and b.id = p_batch_id
$$;

comment on function erp.batch_audit_export(uuid) is
  'Spec 5.8: audit trail export by batch. Everything that happened to it, '
  'across every table that touched it, in order — which is the export a '
  'regulator asks for and the one nothing could produce until now.';

-- -----------------------------------------------------------------------------
-- Installed
-- -----------------------------------------------------------------------------

create or replace function erp.configure_quality(
  p_identify_within interval default '4 hours',
  p_notify_within   interval default '24 hours'
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_cs     uuid;
begin
  perform erp.authorise('administration.configure', null, null, null,
                        'regulatory_clock', null);

  insert into erp.regulatory_clock (
    tenant_id, code, name, jurisdiction, identify_within, notify_within, status)
  values (v_tenant, 'default', 'Default regulatory clock', null,
          p_identify_within, p_notify_within, 'active')
  on conflict (tenant_id, code) do update
    set identify_within = excluded.identify_within,
        notify_within = excluded.notify_within, status = 'active';

  v_cs := erp.install_module_config(
    'quality', 'Quality and compliance',
    'What is inspected, how much of it, and against what limits.',
    jsonb_build_array(
      jsonb_build_object('kind','inspection_plan','key','goods_in','payload',
        jsonb_build_object(
          'code','goods_in','name','Goods-in inspection',
          'trigger_point','receipt',
          -- Square root plus one: what most inbound quality control actually
          -- uses, and configuration rather than code because the answer
          -- differs by item, customer and jurisdiction.
          'sampling_rule', jsonb_build_object('scheme','sqrt','plus',1),
          'characteristics', jsonb_build_array(
            jsonb_build_object('code','temperature','name','Temperature on arrival',
                               'lower',0,'upper',5),
            jsonb_build_object('code','packaging','name','Packaging intact',
                               'expected','intact'))))));

  return v_cs;
end;
$$;

create or replace function erp.configure_logistics()
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_cs     uuid;
begin
  v_cs := erp.install_module_config(
    'logistics', 'Logistics',
    'Which carriers may be used, what they charge and how long they take.',
    jsonb_build_array(
      jsonb_build_object('kind','carrier','key','ROAD','payload',
        jsonb_build_object(
          'code','ROAD','name','Road haulier',
          'services', jsonb_build_array(
            jsonb_build_object('code','ECONOMY','transit_days',4,
                               'base_minor',2000,'per_kg_minor',50),
            jsonb_build_object('code','NEXT_DAY','transit_days',1,
                               'base_minor',9000,'per_kg_minor',120)))),
      jsonb_build_object('kind','carrier','key','AIR','payload',
        jsonb_build_object(
          'code','AIR','name','Air freight',
          'services', jsonb_build_array(
            jsonb_build_object('code','EXPRESS','transit_days',1,
                               'base_minor',25000,'per_kg_minor',400))))));

  return v_cs;
end;
$$;

-- -----------------------------------------------------------------------------
-- B6 learns inspection plans and carriers
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

    -- What is inspected and how much of it. Promoted because a sampling rule
    -- is exactly the sort of thing that gets loosened quietly under delivery
    -- pressure and should have to be argued for.
    when 'inspection_plan' then
      if i.operation = 'remove' then
        update erp.inspection_plan ip set status = 'inactive', updated_at = now()
         where ip.tenant_id = v_tenant and ip.code = (p ->> 'code');
      else
        insert into erp.inspection_plan (
          tenant_id, code, name, item_class, trigger_point, sampling_rule,
          characteristics, status)
        values (v_tenant, p ->> 'code', p ->> 'name', p ->> 'item_class',
                coalesce(p ->> 'trigger_point', 'receipt'),
                coalesce(p -> 'sampling_rule', '{}'::jsonb),
                coalesce(p -> 'characteristics', '[]'::jsonb), 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, item_class = excluded.item_class,
              trigger_point = excluded.trigger_point,
              sampling_rule = excluded.sampling_rule,
              characteristics = excluded.characteristics,
              status = 'active', updated_at = now();
      end if;

    -- Which carriers may be used and what they charge. A tariff that anybody
    -- can edit is one where the cheapest carrier is whoever last touched it.
    when 'carrier' then
      if i.operation = 'remove' then
        update erp.carrier c set status = 'inactive', updated_at = now()
         where c.tenant_id = v_tenant and c.code = (p ->> 'code');
      else
        insert into erp.carrier (tenant_id, code, name, services, status)
        values (v_tenant, p ->> 'code', p ->> 'name',
                coalesce(p -> 'services', '[]'::jsonb), 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, services = excluded.services,
              status = 'active', updated_at = now();
      end if;

    else
      raise exception 'ERPWARE_PROMOTION_UNKNOWN_KIND: % cannot be promoted', i.object_kind
        using errcode = '23514',
              hint = 'Promotable kinds: config, terminology, legislation_binding, event_subscription, role, rule_set, state_machine, approval_chain, posting_rule, data_quality_rule, field_approval_rule, costing_policy, count_programme, receipt_tolerance, match_tolerance, budget, planning_policy, pricing_policy, inspection_plan, carrier';
  end case;
end;
$function$;

-- -----------------------------------------------------------------------------
-- Assertions
-- -----------------------------------------------------------------------------

create or replace function erp.quality_logistics_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  -- A plan with no characteristics inspects nothing and records that it did.
  select 'an inspection plan checks nothing',
         ip.code, 'no characteristics, so every inspection against it passes '
                  'without measuring anything'
    from erp.inspection_plan ip
   where ip.status = 'active'
     and jsonb_array_length(coalesce(ip.characteristics, '[]'::jsonb)) = 0
  union all
  -- A numeric characteristic with no limits cannot be out of specification.
  select 'an inspection characteristic has no limits',
         format('%s.%s', ip.code, c.value ->> 'code'),
         'nothing can be recorded against it that would be out of specification'
    from erp.inspection_plan ip
    cross join lateral jsonb_array_elements(ip.characteristics) c
   where ip.status = 'active'
     and (c.value ->> 'lower') is null and (c.value ->> 'upper') is null
     and (c.value ->> 'expected') is null
  union all
  -- A carrier with no services cannot be selected or booked.
  select 'a carrier quotes nothing',
         c.code, 'no services, so it can never be selected'
    from erp.carrier c
   where c.status = 'active'
     and jsonb_array_length(coalesce(c.services, '[]'::jsonb)) = 0
  union all
  select 'a carrier service has no transit time',
         format('%s.%s', c.code, sv.value ->> 'code'),
         'selection compares arrival dates, and a service with no transit time '
         'appears to arrive the day it leaves'
    from erp.carrier c
    cross join lateral jsonb_array_elements(c.services) sv
   where c.status = 'active' and (sv.value ->> 'transit_days') is null
  union all
  -- A clock that gives longer to identify than to notify is impossible to
  -- meet: you cannot tell people before you know who they are.
  select 'a regulatory clock allows longer to identify than to notify',
         rc.code,
         format('identify within %s, notify within %s', rc.identify_within, rc.notify_within)
    from erp.regulatory_clock rc
   where rc.status = 'active' and rc.identify_within > rc.notify_within
$$;

create or replace function erp.assert_quality_logistics_sane()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare v_count integer; v_detail text;
begin
  select count(*), string_agg(format('  %s [%s] %s', finding, reference, detail), E'\n')
    into v_count, v_detail from erp.quality_logistics_report();
  if v_count > 0 then
    raise exception 'ERPWARE_QUALITY_LOGISTICS_CONFIGURATION_DEAD: % finding(s)',
      v_count using errcode = 'P0001', detail = v_detail;
  end if;
  return 'quality and logistics: every plan measures and every carrier quotes';
end;
$$;

-- -----------------------------------------------------------------------------
-- Public surface
-- -----------------------------------------------------------------------------

create or replace function public.erp_recall_readiness(p_recall_id uuid default null)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb)
        from erp.recall_readiness(p_recall_id) r $$;

create or replace function public.erp_recall_evidence(p_recall_id uuid)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select erp.recall_evidence(p_recall_id) $$;

create or replace function public.erp_batch_audit(p_batch_id uuid)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select erp.batch_audit_export(p_batch_id) $$;

create or replace function public.erp_delivery_performance(p_days integer default 90)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select coalesce(jsonb_agg(to_jsonb(d)), '[]'::jsonb)
        from erp.delivery_performance(p_days) d $$;

create or replace function public.erp_select_carrier(
  p_shipment_id uuid, p_required_by date default null)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb)
        from erp.select_carrier(p_shipment_id, p_required_by) c $$;

create or replace function public.erp_excursion_impact(
  p_site_id uuid, p_location_id uuid, p_from timestamptz, p_to timestamptz)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select coalesce(jsonb_agg(to_jsonb(e)), '[]'::jsonb)
        from erp.assess_excursion_impact(p_site_id, p_location_id, p_from, p_to) e $$;

create or replace function public.erp_configure_quality()
returns uuid language sql volatile security invoker set search_path = ''
as $$ select erp.configure_quality() $$;

create or replace function public.erp_configure_logistics()
returns uuid language sql volatile security invoker set search_path = ''
as $$ select erp.configure_logistics() $$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.erp_recall_readiness(uuid)', 'public.erp_recall_evidence(uuid)',
    'public.erp_batch_audit(uuid)', 'public.erp_delivery_performance(integer)',
    'public.erp_select_carrier(uuid, date)',
    'public.erp_excursion_impact(uuid, uuid, timestamptz, timestamptz)',
    'public.erp_configure_quality()', 'public.erp_configure_logistics()'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_configure_quality', 'erp.configure_quality',
   'Installs the regulatory clock and submits the inspection plan as a B6 '
   'change set the caller cannot approve; authorises administration.configure.'),
  ('erp_configure_logistics', 'erp.configure_logistics',
   'Submits the carrier tariffs as a B6 change set the caller cannot approve; '
   'a tariff anybody can edit makes the cheapest carrier whoever last touched it.')
on conflict (function_name) do update
  set gate = excluded.gate, rationale = excluded.rationale;

-- -----------------------------------------------------------------------------
-- The suite
-- -----------------------------------------------------------------------------

create or replace function erp_test.quality_logistics_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  r record; a1 uuid := gen_random_uuid(); a2 uuid := gen_random_uuid();
  csf uuid; csp uuid; css uuid; csi uuid; csq uuid; csl uuid;
  v_second uuid; v_tok text; res jsonb;
  v_uom uuid; v_site uuid; v_recv uuid; v_desp uuid; v_quar uuid;
  v_sup uuid; v_cust uuid; v_item uuid; v_batch uuid;
  v_grn uuid; v_dn uuid; v_insp uuid; v_qe uuid; v_recall uuid;
  v_ship uuid; v_rel uuid; v_audit jsonb; v_ev jsonb;
  v_in boolean; v_n numeric; rd record; sc record;
  v_ok boolean; v_msg text;
begin
  select * into r from erp.provision_tenant('zzqual','Quality Suite','a@zzqual.test','Suite Admin');
  perform set_config('request.jwt.claims', json_build_object('sub',a1)::text, true);
  perform erp.claim_invitation(r.admin_token);
  res := public.erp_invite_principal('second@zzqual.test','Second Admin');
  v_second := (res->>'app_user_id')::uuid; v_tok := res->>'token';
  perform erp.grant_role(v_second,'administrator',null,null,'co-administrator');

  csf := erp.configure_finance();
  csp := erp.configure_procurement(100000000);
  css := erp.configure_sales(15);
  csi := erp.configure_inventory('average');
  csq := erp.configure_quality('4 hours', '24 hours');
  csl := erp.configure_logistics();

  perform set_config('request.jwt.claims', json_build_object('sub',a2)::text, true);
  perform erp.claim_invitation(v_tok);
  perform erp.approve_change_set(csf); perform erp.promote_change_set(csf);
  perform erp.approve_change_set(csp); perform erp.promote_change_set(csp);
  perform erp.approve_change_set(css); perform erp.promote_change_set(css);
  perform erp.approve_change_set(csi); perform erp.promote_change_set(csi);
  perform erp.approve_change_set(csq); perform erp.promote_change_set(csq);
  perform erp.approve_change_set(csl); perform erp.promote_change_set(csl);
  perform set_config('request.jwt.claims', json_build_object('sub',a1)::text, true);

  return query select 'inspection plans and carrier tariffs install as configuration',
    (select count(*) from erp.inspection_plan ip
      where ip.tenant_id = r.tenant_id and ip.status='active') = 1
    and (select count(*) from erp.carrier c
          where c.tenant_id = r.tenant_id and c.status='active') = 2,
    'a sampling rule that anybody can loosen is not a sampling rule';

  insert into erp.uom (tenant_id,code,name,uom_class,decimals,is_base,status)
  values (r.tenant_id,'EA','Each','quantity',0,true,'active') returning id into v_uom;
  insert into erp.site (tenant_id,entity_id,code,name,site_type,status)
  values (r.tenant_id,r.entity_id,'MAIN','Main','warehouse','active') returning id into v_site;
  insert into erp.location (tenant_id,site_id,code,name,location_type,status)
  values (r.tenant_id,v_site,'RECV','Receiving','receiving','active') returning id into v_recv;
  insert into erp.location (tenant_id,site_id,code,name,location_type,status)
  values (r.tenant_id,v_site,'DESP','Despatch','despatch','active') returning id into v_desp;
  insert into erp.location (tenant_id,site_id,code,name,location_type,status)
  values (r.tenant_id,v_site,'QUAR','Quarantine','quarantine','active') returning id into v_quar;
  insert into erp.party (tenant_id,code,name,status)
  values (r.tenant_id,'SUP','Supplier','active') returning id into v_sup;
  insert into erp.party (tenant_id,code,name,status)
  values (r.tenant_id,'CUST','Customer','active') returning id into v_cust;
  insert into erp.party_role (tenant_id,party_id,role_kind,attributes,status)
  values (r.tenant_id,v_cust,'customer', jsonb_build_object('credit_limit_minor',100000000),'active');
  insert into erp.item (tenant_id,code,name,stock_uom_id,is_batch_controlled,
                        quarantine_on_receipt,gross_weight_g,status)
  values (r.tenant_id,'CHILL','Chilled thing',v_uom,true,true,500,'active')
  returning id into v_item;

  insert into erp.batch (tenant_id, item_id, batch_number, status,
                         manufactured_on, expires_on)
  values (r.tenant_id, v_item, 'B-001', 'quarantine', current_date, current_date + 60)
  returning id into v_batch;

  -- ---------------------------------------------------------------------------
  -- Sampling.
  -- ---------------------------------------------------------------------------
  return query select 'the square-root-plus-one rule is arithmetic, not a guess',
    erp.sample_size(jsonb_build_object('scheme','sqrt','plus',1), 100) = 11
    and erp.sample_size(jsonb_build_object('scheme','fixed','size',5), 100) = 5
    and erp.sample_size(jsonb_build_object('scheme','all'), 100) = 100,
    'the sample never exceeds the lot, whatever the rule says';

  v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
  perform erp.add_document_line(v_grn, v_item, 100, 1000, 'chilled goods');
  update erp.document_line set batch_id = v_batch, location_id = v_quar
   where document_id = v_grn;
  perform erp.transition_document(v_grn,'post');

  v_insp := erp.raise_inspection(v_item, v_site, 100, v_batch, v_grn, 'receipt');
  return query select 'a receipt raises an inspection with a computed sample',
    v_insp is not null
    and (select ins.sample_size from erp.inspection ins where ins.id = v_insp) = 11,
    'eleven of a hundred, from the promoted rule';

  -- ---------------------------------------------------------------------------
  -- Results, and who decides whether they pass.
  -- ---------------------------------------------------------------------------
  v_in := erp.record_inspection_result(v_insp, 'temperature', 3);
  return query select 'within specification is computed, never supplied',
    v_in,
    'three degrees against a limit of nought to five';

  v_in := erp.record_inspection_result(v_insp, 'temperature', 9);
  return query select 'and a reading outside the limits fails, whoever recorded it',
    not v_in,
    'an inspector who can type the verdict is one whose limits are decoration';

  begin
    perform erp.record_inspection_result(v_insp, 'colour', 1);
    v_ok := false; v_msg := 'a result was recorded against a characteristic the plan does not ask for';
  exception when sqlstate '23503' then v_ok := true; v_msg := left(sqlerrm,52); end;
  return query select 'a result the plan does not ask for is refused', v_ok, v_msg;

  begin
    perform erp.disposition_inspection(v_insp, 'accept', null);
    v_ok := false; v_msg := 'a partial inspection was dispositioned';
  exception when sqlstate '23514' then
    v_ok := (sqlerrm like '%INCOMPLETE%'); v_msg := left(sqlerrm,52);
  end;
  return query select 'and a disposition on a partial record is refused', v_ok, v_msg;

  perform erp.record_inspection_result(v_insp, 'packaging', null, 'intact');

  begin
    perform erp.disposition_inspection(v_insp, 'accept', null);
    v_ok := false; v_msg := 'a failed inspection was accepted with no reason';
  exception when sqlstate '23514' then
    v_ok := (sqlerrm like '%CONCESSION%'); v_msg := left(sqlerrm,52);
  end;
  return query select 'accepting a failed inspection needs a stated concession',
    v_ok, v_msg;

  perform erp.disposition_inspection(v_insp, 'accept_with_concession',
                                     'second reading was the probe, not the goods');
  return query select 'and the concession is on the record for ever',
    (select ins.disposition_note is not null from erp.inspection ins where ins.id = v_insp),
    'accepting anyway is a different decision, and it is recorded as one';

  -- ---------------------------------------------------------------------------
  -- Quarantine and authorised release.
  -- ---------------------------------------------------------------------------
  return query select 'stock that must be inspected is received into quarantine',
    (select sum(sb.quantity) from erp.stock_balance sb
      where sb.batch_id = v_batch and sb.stock_status = 'quarantine') = 100,
    'available on arrival means it can be picked before anybody looks at it';

  begin
    perform erp.release_batch(v_batch, v_site, 'inspection passed', '');
    v_ok := false; v_msg := 'a batch was released without a signature';
  exception when sqlstate '23514' then v_ok := true; v_msg := left(sqlerrm,52); end;
  return query select 'a release without a basis and a signature is refused',
    v_ok, v_msg;

  v_rel := erp.release_batch(v_batch, v_site, 'inspection accepted with concession',
                             'QP/2026/001', v_insp);
  return query select 'a qualified release moves the stock and signs for it',
    (select sum(sb.quantity) from erp.stock_balance sb
      where sb.batch_id = v_batch and sb.stock_status = 'available') = 100
    and (select rr.signature from erp.release_record rr where rr.id = v_rel) = 'QP/2026/001',
    'erp.release_record has carried a signature since B7 and nothing wrote one';

  -- ---------------------------------------------------------------------------
  -- Deviations and corrective action.
  -- ---------------------------------------------------------------------------
  v_qe := erp.raise_quality_event('deviation', 'Temperature excursion in chiller',
                                  'high', v_site, v_item, v_batch);
  return query select 'a quality event always has a due date',
    (select qe.due_at is not null from erp.quality_event qe where qe.id = v_qe),
    'an event with none is one nobody chases, and those are the audit findings';

  begin
    perform erp.close_quality_event(v_qe, 'door left open', 'door closed', '');
    v_ok := false; v_msg := 'an event was closed with a repair and no fix';
  exception when sqlstate '23514' then
    v_ok := (sqlerrm like '%PREVENTIVE%'); v_msg := left(sqlerrm,52);
  end;
  return query select 'and cannot be closed without a preventive action', v_ok, v_msg;

  perform erp.close_quality_event(
    v_qe, 'chiller door propped open during a long load',
    'door closed and stock re-checked',
    'door alarm fitted and load procedure changed to a two-person handover');
  return query select 'closing records why, not merely that it stopped',
    (select qe.status from erp.quality_event qe where qe.id = v_qe) = 'closed',
    'corrective repairs this occurrence; preventive stops the next';

  -- ---------------------------------------------------------------------------
  -- Excursion impact.
  -- ---------------------------------------------------------------------------
  return query select 'an excursion assessment names what was in the location',
    exists (select 1 from erp.assess_excursion_impact(
              v_site, v_quar, clock_timestamp() - interval '1 hour', clock_timestamp())
             where batch_number = 'B-001'),
    -- clock_timestamp(), not now(): now() is the transaction's start time, and
    -- every movement this suite made happened after it. The first version of
    -- this case found nothing and would have found nothing however broken the
    -- assessment was.
    'the chiller is not interesting; what was in it is';

  -- ---------------------------------------------------------------------------
  -- Despatch, then a recall of what went out.
  -- ---------------------------------------------------------------------------
  v_dn := erp.open_document('delivery', v_cust, null, v_site);
  perform erp.add_document_line(v_dn, v_item, 40, 2500, 'despatched');
  update erp.document_line set batch_id = v_batch, location_id = v_quar
   where document_id = v_dn;
  perform erp.transition_document(v_dn,'post');

  v_recall := erp.raise_recall('Suspected temperature abuse',
                               'excursion during storage', 'class_2',
                               array[v_batch], 'default');
  return query select 'a recall derives its deadline from the clock, not from a field',
    (select rc.regulatory_deadline_at from erp.recall rc where rc.id = v_recall)
      between now() + interval '23 hours' and now() + interval '25 hours',
    'a deadline somebody types is one that moves';

  v_n := erp.capture_recall_impact(v_recall);
  return query select 'and capturing impact finds who actually received it',
    v_n >= 1
    and exists (select 1 from erp.recall_impact ri
                 where ri.recall_id = v_recall and ri.party_id = v_cust
                   and ri.quantity_despatched = 40),
    format('%s impacted despatch(es)', v_n);

  perform erp.log_recall_action(v_recall, 'notified', v_cust, null, null,
                                'telephoned and emailed', 'EM-1234');
  perform erp.log_recall_action(v_recall, 'recovered', v_cust,
    (select ri.id from erp.recall_impact ri where ri.recall_id = v_recall limit 1),
    25, 'collected by our driver', 'POD-9');

  select * into rd from erp.recall_readiness(v_recall);
  return query select 'readiness is measured against the clock that applies',
    rd.within_identify and rd.within_notify,
    format('identified in %s against %s, notified in %s against %s',
           rd.time_to_identify, rd.identify_target,
           rd.time_to_notify, rd.notify_target);

  return query select 'and what is unaccounted for is derived, not reported',
    rd.unaccounted_quantity = 15,
    'forty despatched, twenty-five back: fifteen is the number a regulator asks for';

  v_ev := erp.recall_evidence(v_recall);
  return query select 'the evidence export assembles into one document',
    jsonb_array_length(v_ev -> 'impacted') >= 1
    and jsonb_array_length(v_ev -> 'actions') = 2
    and (v_ev -> 'readiness') is not null,
    'what was recalled, who had it, what was done, and what did not come back';

  -- ---------------------------------------------------------------------------
  -- Audit export by batch.
  -- ---------------------------------------------------------------------------
  v_audit := erp.batch_audit_export(v_batch);
  return query select 'the batch audit crosses every table that touched it',
    jsonb_array_length(v_audit -> 'movements') >= 3
    and jsonb_array_length(v_audit -> 'inspections') = 1
    and jsonb_array_length(v_audit -> 'releases') = 1
    and jsonb_array_length(v_audit -> 'quality_events') = 1,
    'receipt, release and despatch; the inspection; the signature; the deviation';

  -- ---------------------------------------------------------------------------
  -- Logistics.
  -- ---------------------------------------------------------------------------
  v_ship := erp.plan_shipment(v_site, array[v_dn], current_date);
  return query select 'a shipment consolidates deliveries and weighs them',
    (select sh.total_weight_g from erp.shipment sh where sh.id = v_ship) = 20000,
    'forty units at five hundred grammes';

  select * into sc from erp.select_carrier(v_ship, current_date + 2);
  return query select 'carrier selection puts the ones that arrive in time first',
    sc.meets_date,
    format('%s %s: %s days, %s minor', sc.carrier_code, sc.service_code,
           sc.transit_days, sc.cost_minor);

  return query select 'and the cheapest that misses the date is not recommended',
    not exists (select 1 from erp.select_carrier(v_ship, current_date + 2) c
                 where c.recommended and not c.meets_date),
    'ordering purely by cost recommends a carrier that misses the date';

  perform erp.book_shipment(v_ship, 'ROAD', 'NEXT_DAY');
  return query select 'booking apportions the freight over the deliveries',
    (select sum(sl.freight_share_minor) from erp.shipment_line sl
      where sl.shipment_id = v_ship)
      = (select sh.freight_cost_minor from erp.shipment sh where sh.id = v_ship),
    'by weight, which is what the carrier charged for';

  perform erp.record_proof_of_delivery(v_ship, now(), 'J. Smith', 'POD-1');
  return query select 'proof of delivery closes the shipment and is measurable',
    (select count(*) from erp.delivery_performance(90) dp
      where dp.carrier_code = 'ROAD') = 1,
    'against what was promised, over delivered shipments only';

  -- ---------------------------------------------------------------------------
  -- Configuration assertions.
  -- ---------------------------------------------------------------------------
  return query select 'every plan measures and every carrier quotes',
    (select count(*) from erp.quality_logistics_report()) = 0,
    'a plan with no characteristics passes without measuring anything';

  update erp.regulatory_clock set identify_within = interval '48 hours'
   where tenant_id = r.tenant_id and code = 'default';
  return query select 'a clock allowing longer to identify than to notify fails the build',
    (select count(*) from erp.quality_logistics_report()
      where finding = 'a regulatory clock allows longer to identify than to notify') = 1,
    'you cannot tell people before you know who they are';
  update erp.regulatory_clock set identify_within = interval '4 hours'
   where tenant_id = r.tenant_id and code = 'default';

  set constraints all immediate;
  perform set_config('request.jwt.claims','',true);
  perform erp.begin_tenant_purge(r.tenant_id);
  delete from erp.tenant where id = r.tenant_id;
  perform erp.end_tenant_purge();
end;
$$;

create or replace function erp_test.assert_quality_logistics_suite()
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_pass integer; v_total integer; v_detail text;
  c_expected constant integer := 29;
begin
  create temporary table if not exists zz_ql_result
    (case_name text, passed boolean, detail text) on commit drop;
  delete from zz_ql_result;
  insert into zz_ql_result select * from erp_test.quality_logistics_suite();

  select count(*) filter (where passed), count(*),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_pass, v_total, v_detail from zz_ql_result;

  if v_total <> c_expected then
    raise exception 'ERPWARE_QUALITY_LOGISTICS_SUITE_INCOMPLETE: % cases, expected %',
      v_total, c_expected using errcode = 'P0001';
  end if;
  if v_pass < v_total then
    raise exception E'ERPWARE_QUALITY_LOGISTICS_SUITE_FAILED: %/%\n%',
      v_pass, v_total, v_detail using errcode = 'P0001';
  end if;

  return format('quality and logistics: %s/%s', v_pass, v_total);
end;
$$;

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_quality_logistics_sane();
select erp.assert_no_dead_configuration();
select erp.assert_public_api_safe();
select erp.assert_resource_coverage('en');
select erp.assert_isolation();

-- -----------------------------------------------------------------------------
-- Quality routing, finished
--
-- The receipt path chose the quarantine LOCATION for an inspect-on-arrival item
-- and left the stock STATUS as available. That is worse than not routing it at
-- all: the goods sit in a bay nobody picks from, marked as pickable, so the
-- control looks applied and the stock is one query away from being taken.
-- -----------------------------------------------------------------------------

create or replace function erp.post_document_stock(p_document_id uuid)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  d          erp.document%rowtype;
  dt         erp.document_type%rowtype;
  bt         erp_ref.document_type%rowtype;
  mt         erp_ref.movement_type%rowtype;
  ln         record;
  v_location uuid;
  v_cost     bigint;
  v_count    integer := 0;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503';
  end if;

  select * into dt from erp.document_type
   where tenant_id = v_tenant and id = d.document_type_id;
  select * into bt from erp_ref.document_type where code = dt.base_type_code;

  -- Nothing to do is not an error: most document types move no stock, and the
  -- caller should not have to know which.
  if not bt.affects_stock then
    return 0;
  end if;

  -- Posting twice would double the stock. The ledger is append-only, so there
  -- is no undoing it — a receipt is corrected by reversing it, never by
  -- posting it again.
  if exists (select 1 from erp.stock_movement m
              where m.tenant_id = v_tenant and m.document_id = p_document_id) then
    raise exception
      'ERPWARE_ALREADY_POSTED: % has already moved stock; reverse it rather '
      'than posting again', d.document_number
      using errcode = '23505';
  end if;

  if dt.stock_movement_type is null then
    raise exception
      'ERPWARE_NO_MOVEMENT_TYPE: % moves stock but names no movement type',
      dt.code
      using errcode = '23502',
      detail = 'erp_ref.document_type.affects_stock is true for base type '
               || dt.base_type_code;
  end if;

  select * into mt from erp_ref.movement_type where code = dt.stock_movement_type;

  if d.site_id is null then
    raise exception 'ERPWARE_NO_SITE: % moves stock but names no site', d.document_number
      using errcode = '23502';
  end if;

  perform erp.authorise(
    case when mt.direction = 'in' then 'procurement.receive' else 'sales.despatch' end,
    d.entity_id, d.site_id, null, 'document', p_document_id);

  for ln in
    select l.* from erp.document_line l
     where l.tenant_id = v_tenant and l.document_id = p_document_id
       and not l.is_cancelled and l.quantity > 0
     order by l.line_no
  loop
    v_location := coalesce(ln.location_id,
                           erp.default_posting_location(d.site_id, mt.direction));

    -- What this line's stock is worth, by the costing method in force. Inbound
    -- records what arrived; outbound consumes it. Either way the answer is
    -- written onto the movement, which is where the ledger reads it from —
    -- erp.stock_movement.unit_cost_minor has existed since B7 and until now
    -- carried the sales price, because nothing read it.
    if mt.direction = 'in' then
      v_cost := erp.receive_cost(
        ln.item_id, d.site_id, ln.quantity,
        coalesce(ln.unit_price_minor, 0), coalesce(ln.currency, d.currency),
        ln.batch_id, null);
    elsif mt.direction = 'out' then
      v_cost := erp.issue_cost(ln.item_id, d.site_id, ln.quantity);
    else
      -- A transfer does not change what stock cost; it changes where it is.
      v_cost := coalesce(ln.unit_price_minor, 0);
    end if;

    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id,
      batch_id, serial_id, container_id,
      -- One expression, both directions. B7's trigger reads these to decide
      -- which side of the balance to touch, so 'in' fills the destination and
      -- 'out' fills the source; a transfer would fill both.
      from_location_id, from_status, to_location_id, to_status,
      quantity, uom_id, unit_cost_minor, currency,
      document_id, document_line_id)
    values (
      v_tenant, d.entity_id, d.site_id, mt.code, ln.item_id,
      ln.batch_id, ln.serial_id, ln.container_id,
      case when mt.direction in ('out', 'transfer') then v_location end,
      case when mt.direction in ('out', 'transfer') then 'available'::erp.stock_status end,
      case when mt.direction in ('in',  'transfer') then v_location end,
      -- Quality routing at the ledger, not only at the location.
      -- erp.item.quarantine_on_receipt was read when choosing where the goods
      -- go and not when deciding what they may be used for, so an
      -- inspect-on-arrival item landed in the quarantine bay with an available
      -- status — pickable from a location nobody would think to look in.
      case when mt.direction in ('in', 'transfer') then
        case when mt.direction = 'in'
                  and (select i.quarantine_on_receipt from erp.item i
                        where i.id = ln.item_id)
             then 'quarantine'::erp.stock_status
             else 'available'::erp.stock_status end
      end,
      ln.quantity,
      coalesce(ln.uom_id, (select i.stock_uom_id from erp.item i where i.id = ln.item_id)),
      v_cost, coalesce(ln.currency, d.currency),
      p_document_id, ln.id);

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;
