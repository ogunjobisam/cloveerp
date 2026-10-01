set lock_timeout = '30s';

-- =============================================================================
-- 20261004600000  Despatch says what needs a person
-- -----------------------------------------------------------------------------
-- LPR3 of docs/spec/logistics-target-flow.md: nodes L5, L6, L7 and L8.
--
-- ── WHAT WAS THERE ───────────────────────────────────────────────────────────
--
-- LPR2 (20261002500000) made the shipment a document and despatch two presses,
-- and left four things for here:
--
--   * Nothing said a shipment was on its way or late, and nothing gathered the
--     shipments a person had to look at: one left planned because no carrier
--     quoted it, one past its arrival with no proof, one booked well above the
--     rate card. A planner found them by reading every shipment.
--   * The despatch cycle had no setting at all. Whether the rate card's
--     recommendation is taken, what counts as a cost typed too high, when a
--     shipment reads late, whether proof of delivery is recorded and which
--     deliveries are offered together were each fixed in code.
--   * The budget of two was declared and walked by nobody.
--   * The demonstration did not install logistics, so its Despatch screen and
--     delivery performance were empty; and the screen's performance report
--     read columns (party, deliveries, in_full, otif_pct) the door has never
--     returned, so it would have been blank with rows behind it.
--
-- ── WHAT CHANGES ─────────────────────────────────────────────────────────────
--
--   L6. logistics.shipping_policy, a setting of the despatch cycle, five
--       parameters, every default the clean path; erp.shipping_policy() reads
--       it at a company and site, and each parameter has its reader:
--         auto_select_carrier          erp.ship_deliveries()
--         cost_override_tolerance_pct  erp.shipment_reading()
--         late_after_days              erp.shipment_reading(), the sweep
--         proof_required               erp.shipment_reading(), the sweep
--         consolidate                  erp_deliveries_to_ship()
--   L5. erp.shipment_reading(): on its way and late are read, never states.
--       erp.shipment keeps the rate card's price at booking (quoted_cost_minor)
--       so a cost typed above it is judged against what was quoted then, not
--       against a rate card changed since. erp_shipment_exceptions() lists what
--       needs a person: planned, late, booked over tolerance. Nothing else.
--   L5. Proof not required: erp.deliver_unproved_shipments() moves a booked
--       shipment to delivered once its planned arrival and the grace have
--       passed, as the system's move (erp.derived_move_fact(), read again with
--       the shipment locked), from a job logistics installs. With proof
--       required, the default, it moves nothing.
--       Logistics is version 3: the job, offered to an organisation on 2.
--   L7. erp_test.despatch_walk(), walked by erp_test.step_budget_suite: a
--       planner and a driver, neither an administrator, two presses.
--   L8. The demonstration installs logistics, and every Tuesday ships the
--       week's posted deliveries; most are signed for on the day due, and the
--       first of each month's first Tuesday two days late. A demonstration
--       built before this takes logistics in its catch-up. The Despatch
--       screen's performance report reads the door's own columns.
--
-- Proof: erp_test.despatch_exceptions_suite (9 cases), and case 15 of
-- erp_test.step_budget_suite.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The setting, and what reads it (L6)
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('config.logistics.shipping_policy', 'en', 'Shipping policy', 'logistics',
   'The name of the logistics.shipping_policy configuration type: how deliveries are shipped, judged late and signed for.'),
  ('config.logistics.shipping_policy', 'de', 'Versandrichtlinie', 'logistics',
   'Der Name des Konfigurationstyps logistics.shipping_policy.'),
  ('job_handler.deliver_unproved.name', 'en', 'Deliver shipments that need no proof', 'logistics',
   'Job handler name (20261004600000).'),
  ('job_handler.deliver_unproved.name', 'de', 'Sendungen ohne Zustellnachweis zustellen', 'logistics', null)
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

insert into erp_ref.config_type
  (code, domain, module_code, name_key, description, value_schema,
   max_scope_level, is_singleton, default_value, consequence, cycle_code, clean_path) values
  ('logistics.shipping_policy', 'policy', 'logistics', 'config.logistics.shipping_policy',
   'How deliveries are shipped: whether Ship these deliveries takes the carrier the rate card '
   'recommends; how far above the rate card a typed cost may go before the shipment is flagged; '
   'how many days past its planned arrival a shipment reads late; whether proof of delivery is '
   'recorded, or a shipment is taken as delivered once its arrival has passed; and which posted '
   'deliveries the picker offers together.',
   jsonb_build_object('type','object','additionalProperties',false,
     'properties', jsonb_build_object(
       'auto_select_carrier', jsonb_build_object('type','boolean'),
       'cost_override_tolerance_pct', jsonb_build_object('type','number','minimum',0),
       'late_after_days', jsonb_build_object('type','integer','minimum',0),
       'proof_required', jsonb_build_object('type','boolean'),
       'consolidate', jsonb_build_object('type','string','enum', jsonb_build_array('customer_day','none')))),
   'site', true,
   jsonb_build_object('auto_select_carrier', true, 'cost_override_tolerance_pct', 10,
                      'late_after_days', 0, 'proof_required', true, 'consolidate', 'customer_day'),
   'without the recommendation a shipment nobody names a carrier for is left planned, on the '
   'exceptions list; a cost above the rate card by more than the tolerance is booked and flagged; '
   'a booked shipment past its arrival and the grace reads late; without proof a shipment is '
   'delivered by the system once its arrival and the grace have passed; and the picker groups '
   'one customer''s deliveries from one site and day, or none.',
   'despatch',
   'The rate card''s recommendation taken, ten per cent of grace on a typed cost, late from the day '
   'after arrival, proof recorded by whoever delivers, and one customer''s day offered together: '
   'two presses and nobody asked anything.')
on conflict (code) do nothing;

do $config_type$
begin
  if (select ct.default_value from erp_ref.config_type ct where ct.code = 'logistics.shipping_policy')
     is distinct from '{"auto_select_carrier": true, "cost_override_tolerance_pct": 10, "late_after_days": 0, "proof_required": true, "consolidate": "customer_day"}'::jsonb
     or (select ct.cycle_code from erp_ref.config_type ct where ct.code = 'logistics.shipping_policy') is distinct from 'despatch' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: logistics.shipping_policy is declared already, and not as 20261004600000 declares it';
  end if;
end
$config_type$;

create or replace function erp.shipping_policy(p_entity_id uuid default null, p_site_id uuid default null)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- The shipping policy in force at a company and site (20261004600000),
  -- layered key by key as the procurement policy is: the product's defaults,
  -- then what the organisation set, then its company, then its site.
  select coalesce(ct.default_value, '{}'::jsonb)
      || coalesce(erp.config_value('logistics.shipping_policy', null, null, null, null), '{}'::jsonb)
      || case when p_entity_id is null then '{}'::jsonb
              else coalesce(erp.config_value('logistics.shipping_policy', null, null, p_entity_id, null), '{}'::jsonb) end
      || case when p_site_id is null then '{}'::jsonb
              else coalesce(erp.config_value('logistics.shipping_policy', null, null, p_entity_id, p_site_id), '{}'::jsonb) end
    from erp_ref.config_type ct
   where ct.code = 'logistics.shipping_policy'
$$;

revoke all on function erp.shipping_policy(uuid, uuid) from public, anon;

comment on function erp.shipping_policy(uuid, uuid) is
  'logistics.shipping_policy at a company and site, over its defaults (20261004600000). Read by '
  'erp.ship_deliveries(), erp.shipment_reading(), erp.shipment_needs_no_proof() and erp_deliveries_to_ship().';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. What the rate card quoted, kept at booking
-- ─────────────────────────────────────────────────────────────────────────────

alter table erp.shipment add column if not exists quoted_cost_minor bigint;

comment on column erp.shipment.quoted_cost_minor is
  'What the rate card priced the booked carrier and service at when the shipment was booked, or null when '
  'it quoted nothing and the planner gave the cost (20261004600000). A typed cost is judged against this, '
  'not against a rate card changed since.';

do $book$
declare
  v_sig  constant text := 'erp.book_shipment(uuid,text,text,bigint)';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$         freight_cost_minor = coalesce(p_cost_minor, v_cost),
$o$;
  v_new  constant text := $n$         freight_cost_minor = coalesce(p_cost_minor, v_cost),
         -- What the rate card quoted, whatever was typed (20261004600000).
         quoted_cost_minor = v_cost,
$n$;
  v_hits integer := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
begin
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % freight anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$book$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The recommendation, as the policy says
-- ─────────────────────────────────────────────────────────────────────────────

do $ship$
declare
  v_sig  constant text := 'erp.ship_deliveries(uuid[],date,text,text,bigint)';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  if v_service is null then
    select c.carrier_code, c.service_code, c.cost_minor into o
$o$;
  v_new  constant text := $n$  -- Unless the shipping policy says the planner chooses (20261004600000):
  -- then a shipment nobody names a carrier for is left planned, on the
  -- exceptions list, rather than booked with one nobody chose.
  if v_service is null
     and (v_carrier is not null
          or coalesce((erp.shipping_policy(
                         (select s.entity_id from erp.site s where s.tenant_id = v_tenant and s.id = v_site),
                         v_site) ->> 'auto_select_carrier')::boolean, true)) then
    select c.carrier_code, c.service_code, c.cost_minor into o
$n$;
  v_hits integer := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
begin
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % recommendation anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$ship$;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. On its way, late, over tolerance: read, never states (L5)
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.shipment_reading(p_shipment_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- What a shipment is doing, read from its dates, its costs and the shipping
  -- policy at its site (20261004600000). None of it is a state: a shipment
  -- is planned, booked, delivered or cancelled, and these are facts about a
  -- booked one.
  --
  --   on its way      booked, and its planned despatch is today or before
  --   late            booked, proof recorded, and past its planned arrival
  --                   and the grace; with proof not recorded the sweep
  --                   delivers it instead, so it is never late
  --   over tolerance  booked at a cost above what the rate card quoted by
  --                   more than the tolerance
  select jsonb_build_object(
           'on_its_way', sh.status = 'booked' and sh.planned_despatch <= erp.local_today(sh.site_id),
           'late', sh.status = 'booked' and sh.planned_arrival is not null
                   and coalesce((x.pol ->> 'proof_required')::boolean, true)
                   and sh.planned_arrival + coalesce((x.pol ->> 'late_after_days')::integer, 0)
                         < erp.local_today(sh.site_id),
           'days_late', case when sh.status = 'booked' and sh.planned_arrival is not null
                             then greatest(erp.local_today(sh.site_id) - sh.planned_arrival, 0) end,
           'over_tolerance', sh.status = 'booked' and sh.quoted_cost_minor is not null
                   and sh.freight_cost_minor * 100.0
                         > sh.quoted_cost_minor * (100 + coalesce((x.pol ->> 'cost_override_tolerance_pct')::numeric, 10)))
    from erp.shipment sh
   cross join lateral (select erp.shipping_policy(sh.entity_id, sh.site_id) as pol) x
   where sh.tenant_id = erp.current_tenant_id() and sh.id = p_shipment_id
$$;

revoke all on function erp.shipment_reading(uuid) from public, anon;

comment on function erp.shipment_reading(uuid) is
  'On its way, late and over tolerance, read from a shipment''s dates and costs and the shipping policy '
  'at its site (20261004600000). Facts about a booked shipment, never states.';

create or replace function public.erp_shipments(p_limit integer default 100)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by x->>'planned_despatch' desc nulls last), '[]'::jsonb) from (
    select jsonb_build_object('shipment_id', sh.id, 'reference', sh.reference,
      -- The document's number where it has one (20261002500000).
      'document_id', sh.document_id, 'number', coalesce(doc.document_number, sh.reference),
      'status', sh.status, 'carrier', c.name, 'service_code', sh.service_code,
      'planned_despatch', sh.planned_despatch, 'planned_arrival', sh.planned_arrival,
      'actual_despatch', sh.actual_despatch, 'actual_arrival', sh.actual_arrival,
      'destination', p.name, 'freight_cost_minor', sh.freight_cost_minor,
      -- What the rate card quoted, and what the shipment is doing (20261004600000).
      'quoted_cost_minor', sh.quoted_cost_minor,
      'on_its_way', coalesce((rd.r ->> 'on_its_way')::boolean, false),
      'late', coalesce((rd.r ->> 'late')::boolean, false),
      'currency', sh.currency, 'tracking_reference', sh.tracking_reference) as x
      from erp.shipment sh
      left join erp.carrier c on c.tenant_id = sh.tenant_id and c.id = sh.carrier_id
      left join erp.party p on p.tenant_id = sh.tenant_id and p.id = sh.destination_party_id
      left join erp.document doc on doc.tenant_id = sh.tenant_id and doc.id = sh.document_id
     cross join lateral (select erp.shipment_reading(sh.id) as r) rd
     where sh.tenant_id = erp.current_tenant_id()
     order by sh.planned_despatch desc nulls last limit greatest(p_limit, 1)) t
$$;

create or replace function public.erp_shipment_exceptions()
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- What needs a person, and nothing else (20261004600000): a shipment left
  -- planned because no carrier quoted it and nobody gave a cost; one past its
  -- arrival with no proof of delivery; one booked above the rate card by more
  -- than the tolerance. A shipment on the clean path is never here.
  select coalesce(jsonb_agg(x order by x ->> 'kind', x ->> 'number'), '[]'::jsonb) from (
    select jsonb_build_object(
             'shipment_id', sh.id, 'number', coalesce(doc.document_number, sh.reference),
             'kind', k.kind, 'reason', k.reason,
             'destination', p.name, 'carrier', c.name, 'status', sh.status,
             'planned_despatch', sh.planned_despatch, 'planned_arrival', sh.planned_arrival,
             'freight_cost_minor', sh.freight_cost_minor, 'quoted_cost_minor', sh.quoted_cost_minor,
             'currency', sh.currency) as x
      from erp.shipment sh
      left join erp.carrier c on c.tenant_id = sh.tenant_id and c.id = sh.carrier_id
      left join erp.party p on p.tenant_id = sh.tenant_id and p.id = sh.destination_party_id
      left join erp.document doc on doc.tenant_id = sh.tenant_id and doc.id = sh.document_id
     cross join lateral (select erp.shipment_reading(sh.id) as r) rd
     cross join lateral (values
       ('planned', 'No carrier quotes it and nobody gave a cost. Book it with a carrier, or cancel it.',
        sh.status = 'planned' and sh.document_id is not null),
       ('late', format('Due %s and not signed for.', sh.planned_arrival),
        coalesce((rd.r ->> 'late')::boolean, false)),
       ('over_tolerance', 'Booked above what the rate card quoted, by more than the shipping policy allows.',
        coalesce((rd.r ->> 'over_tolerance')::boolean, false))
     ) as k(kind, reason, applies)
     where sh.tenant_id = erp.current_tenant_id()
       and k.applies) t
$$;

revoke all on function public.erp_shipment_exceptions() from public, anon;
grant execute on function public.erp_shipment_exceptions() to authenticated;

comment on function public.erp_shipment_exceptions() is
  'The shipments that need a person: left planned, late, or booked over tolerance (20261004600000). '
  'Read by the Despatch screen''s Needs a person list.';

-- ─────────────────────────────────────────────────────────────────────────────
-- E. Deliveries offered together, as the policy says
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.erp_deliveries_to_ship(p_site_id uuid, p_within_days integer default 30, p_limit integer default 200)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by x ->> 'document_date' desc, x ->> 'travels_with', x ->> 'document_number' desc),
                  '[]'::jsonb)
    from (
      select jsonb_build_object(
               'document_id', d.id, 'document_number', d.document_number,
               'document_date', d.document_date, 'party', p.name,
               'state', s.code, 'state_name', s.name,
               'site_id', d.site_id, 'site', st.code,
               -- Deliveries that travel together under the shipping policy
               -- (20261004600000): one customer's from one site and day, or
               -- each on its own. The picker lists them side by side.
               'travels_with', case coalesce(erp.shipping_policy(d.entity_id, d.site_id) ->> 'consolidate', 'customer_day')
                                 when 'customer_day'
                                   then concat_ws('/', p.code, st.code, d.document_date::text)
                                 else d.document_number end) as x
        from erp.document d
        join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
        join erp.object_state os
          on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
        join erp.state s on s.id = os.current_state_id
        left join erp.party p on p.tenant_id = d.tenant_id and p.id = d.party_id
        left join erp.site st on st.tenant_id = d.tenant_id and st.id = d.site_id
       where d.tenant_id = erp.current_tenant_id()
         and dt.base_type_code = 'delivery'
         -- No site named: every site, for the Despatch strip's first step.
         and (p_site_id is null or d.site_id = p_site_id)
         and s.code = 'posted'
         and not d.is_cancelled
         and (p_within_days is null or d.document_date >= current_date - p_within_days)
         -- Not on a shipment already, unless that shipment was cancelled.
         and not exists (
               select 1
                 from erp.shipment_line sl
                 join erp.shipment sh on sh.tenant_id = sl.tenant_id and sh.id = sl.shipment_id
                where sl.tenant_id = d.tenant_id
                  and sl.document_id = d.id
                  and sh.status <> 'cancelled')
       order by d.document_date desc, d.document_number desc
       limit greatest(coalesce(p_limit, 200), 1)
    ) t
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- F. Proof not required: the system delivers (L5, the sweep)
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.shipment_needs_no_proof(p_document_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- A booked shipment, at a site whose shipping policy records no proof of
  -- delivery, past its planned arrival and the grace (20261004600000). The
  -- fact erp.derived_move_fact() reads, with the shipment's state locked.
  select coalesce(bool_or(
           sh.status = 'booked'
           and sh.planned_arrival is not null
           and not coalesce((erp.shipping_policy(sh.entity_id, sh.site_id) ->> 'proof_required')::boolean, true)
           and sh.planned_arrival
                 + coalesce((erp.shipping_policy(sh.entity_id, sh.site_id) ->> 'late_after_days')::integer, 0)
               <= erp.local_today(sh.site_id)), false)
    from erp.shipment sh
   where sh.tenant_id = erp.current_tenant_id() and sh.document_id = p_document_id
$$;

revoke all on function erp.shipment_needs_no_proof(uuid) from public, anon;

do $derived$
declare
  v_sig  constant text := 'erp.derived_move_fact(text,uuid,text)';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$            and erp.transfer_is_received_in_full(p_object_id)
             then 'erp.transfer_is_received_in_full'
         end
$o$;
  v_new  constant text := $n$            and erp.transfer_is_received_in_full(p_object_id)
             then 'erp.transfer_is_received_in_full'
           -- A shipment's delivery where its site records no proof, once its
           -- arrival and the grace have passed (20261004600000), asked for by
           -- erp.deliver_unproved_shipments().
           when dt.base_type_code = 'shipment' and p_transition_code = 'deliver'
            and erp.object_current_state('document', p_object_id) = 'booked'
            and erp.shipment_needs_no_proof(p_object_id)
             then 'erp.shipment_needs_no_proof'
         end
$n$;
  v_hits integer := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
begin
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % transfer close anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$derived$;

create or replace function erp.deliver_unproved_shipments(p_params jsonb default '{}'::jsonb)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  r        record;
  v_n      integer := 0;
begin
  -- Where the shipping policy records no proof of delivery, a booked shipment
  -- is delivered once its planned arrival and the grace have passed
  -- (20261004600000): the system's move, not anybody's, so the document's
  -- state and its history agree with what the policy says happened. With
  -- proof recorded, the default, nothing qualifies and nothing moves.
  for r in
    select sh.id, sh.document_id, sh.planned_arrival
      from erp.shipment sh
     where sh.tenant_id = v_tenant
       and sh.status = 'booked'
       and sh.document_id is not null
       and erp.shipment_needs_no_proof(sh.document_id)
     order by sh.planned_arrival, sh.id
  loop
    begin
      update erp.shipment
         set actual_arrival = r.planned_arrival::timestamptz,
             proof_of_delivery = jsonb_build_object(
               'signed_by', null, 'at', r.planned_arrival,
               'reference', null, 'recorded_by', null,
               'by', 'the system',
               'because', 'the shipping policy records no proof of delivery, so a shipment is taken as delivered on its planned arrival'),
             updated_at = now()
       where tenant_id = v_tenant and id = r.id;
      perform set_config('erp.deriving_move', r.document_id::text || ':deliver', true);
      perform erp.transition_document(r.document_id, 'deliver',
                                      'Arrived as planned; this site records no proof of delivery');
      perform set_config('erp.deriving_move', '', true);
      perform erp.mirror_shipment_status(r.id);
      v_n := v_n + 1;
    exception when others then
      perform set_config('erp.deriving_move', '', true);
      raise warning 'shipment % stays booked: %', r.id, sqlerrm;
    end;
  end loop;
  return v_n;
end;
$$;

revoke all on function erp.deliver_unproved_shipments(jsonb) from public, anon;

comment on function erp.deliver_unproved_shipments(jsonb) is
  'Delivers, as the system, each booked shipment at a site whose shipping policy records no proof, once '
  'its arrival and the grace have passed (20261004600000). The logistics.deliver_unproved job.';

insert into erp_ref.job_handler
  (code, name_key, description, module_code, sql_function, default_timeout_seconds, parameter_schema, forbids_overlap, is_current)
values
  ('logistics.deliver_unproved', 'job_handler.deliver_unproved.name',
   'Delivers booked shipments past their arrival at a site whose shipping policy records no proof of delivery. '
   'With proof recorded, the default, it moves nothing.',
   'logistics', 'deliver_unproved_shipments', 300,
   '{"type":"object","additionalProperties":false}', true, true)
on conflict (code) do update
  set description = excluded.description, sql_function = excluded.sql_function,
      parameter_schema = excluded.parameter_schema, is_current = excluded.is_current;

-- ─────────────────────────────────────────────────────────────────────────────
-- G. Logistics version 3: the job, installed and offered
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.despatch_pack_items()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  -- What logistics version 3 adds (20261004600000), read by
  -- erp.configure_logistics() for a new install and by the upgrade register
  -- for an organisation on version 2. Shipped switched on, unlike the packs'
  -- other jobs: it does nothing until a site records no proof, and a site
  -- that says so expects its shipments delivered without anybody switching
  -- something else on.
  select jsonb_build_array(
    jsonb_build_object('kind', 'job', 'key', 'deliver_unproved_shipments', 'payload',
      jsonb_build_object(
        'code', 'deliver_unproved_shipments',
        'name', 'Deliver shipments that need no proof',
        'handler_code', 'logistics.deliver_unproved',
        'schedule_kind', 'interval', 'interval_seconds', 3600,
        'is_enabled', true)))
$$;

revoke all on function erp.despatch_pack_items() from public, anon;

do $configure$
declare
  v_sig  constant text := 'erp.configure_logistics()';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$      || erp.shipment_pack_items());$o$;
  v_new  constant text := $n$      || erp.shipment_pack_items()
      -- The sweep that delivers where no proof is recorded (20261004600000).
      || erp.despatch_pack_items());$n$;
  v_hits integer := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
begin
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % shipment pack anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$configure$;

update erp_ref.module_installer
   set current_version = 3,
       description = description
         || ' Version 3 (20261004600000): the job that delivers shipments where no proof of delivery is recorded.'
 where install_code = 'logistics' and current_version = 2;

insert into erp_ref.module_upgrade_item (install_code, to_version, object_kind, object_key, payload, seq)
select 'logistics', 3, i.value ->> 'kind', i.value ->> 'key', i.value -> 'payload',
       100 + 10 * i.ordinality::integer
  from jsonb_array_elements(erp.despatch_pack_items()) with ordinality as i(value, ordinality)
on conflict (install_code, to_version, object_kind, object_key)
  do update set payload = excluded.payload, seq = excluded.seq;

do $register$
begin
  if (select current_version from erp_ref.module_installer
       where install_code = 'logistics') is distinct from 3 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: the logistics installer is not at version 3';
  end if;
  if (select count(*) from erp_ref.module_upgrade_item ui
       where ui.install_code = 'logistics' and ui.to_version = 3) <> 1 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: version 3 of logistics is not the one job it ships';
  end if;
end
$register$;

-- ─────────────────────────────────────────────────────────────────────────────
-- H. The demonstration ships (L8)
-- ─────────────────────────────────────────────────────────────────────────────

do $demo$
declare
  v_sigs constant text[] := array[
    'erp.ensure_demo_configuration(uuid,uuid)',
    'erp.demonstration_catch_up()',
    'erp.seed_demo_history(date,date,numeric)'];
  v_pairs constant text[] := array[
    -- ensure_demo_configuration: beside the close checklist.
    $o$  if not exists (select 1 from erp.change_set c where c.tenant_id = p_tenant_id and c.code = 'period-close') then
    perform erp.configure_period_close();
    v_did := v_did || '"period-close"'::jsonb;
  end if;
$o$,
    $n$  if not exists (select 1 from erp.change_set c where c.tenant_id = p_tenant_id and c.code = 'period-close') then
    perform erp.configure_period_close();
    v_did := v_did || '"period-close"'::jsonb;
  end if;

  -- Logistics, so the demonstration's deliveries leave on shipments and the
  -- Despatch screen has something to show (20261004600000).
  if not exists (select 1 from erp.module_installation i
                  where i.tenant_id = p_tenant_id and i.install_code = 'logistics') then
    perform erp.configure_logistics();
    v_did := v_did || '"logistics"'::jsonb;
  end if;
$n$,
    -- demonstration_catch_up: before logistics' newer version.
    $o$  -- ── Logistics' newer version (20261002500000) ─────────────────────────────
$o$,
    $n$  -- ── Logistics, for a demonstration built before it shipped (20261004600000)
  -- Only one that sells: a demonstration with nothing installed has nothing to
  -- ship, and its catch-up has its own answer for that.
  begin
    if not exists (select 1 from erp.module_installation i
                    where i.tenant_id = v_tenant and i.install_code = 'logistics')
       and exists (select 1 from erp.module_installation i
                    where i.tenant_id = v_tenant and i.install_code = 'sales-lifecycle') then
      perform erp.configure_logistics();
      v_notes := v_notes || to_jsonb('Logistics was installed, so the demonstration ships its deliveries.'::text);
    end if;
  exception when others then
    v_notes := v_notes || to_jsonb(format(
      'Logistics was not installed, so the demonstration does not ship: %s', sqlerrm));
  end;

  -- ── Logistics' newer version (20261002500000) ─────────────────────────────
$n$,
    -- seed_demo_history: before the weekend count.
    $o$  -- ── The weekend count ────────────────────────────────────────────────────
$o$,
    $n$  -- ── The week's shipments ─────────────────────────────────────────────────
  -- Every Tuesday the week's posted deliveries that no shipment carries leave
  -- on shipments, one for each customer and site, through Ship these
  -- deliveries with the rate card's recommendation (20261004600000). Each is
  -- signed for on the day it was due, except the first shipment of each
  -- month's first Tuesday, which arrives two days late; one still due when
  -- the history ends is on its way. Shipping moves no stock, which the
  -- deliveries moved, so it shares Tuesday with the return without either
  -- sizing itself against the other. Nothing here draws on random().
  if extract(isodow from v_day) = 2
     and exists (select 1 from erp.document_type dt
                  where dt.tenant_id = v_tenant and dt.code = 'shipment' and dt.status = 'active') then
    declare
      g        record;
      v_ship   uuid;
      v_first  boolean := extract(day from v_day) <= 7;
      v_arrive date;
    begin
      for g in
        select d.site_id, d.party_id, array_agg(d.id order by d.document_number) as ids
          from erp.document d
          join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
         where d.tenant_id = v_tenant
           and dt.base_type_code = 'delivery'
           and not d.is_cancelled
           and d.document_date between v_day - 6 and v_day
           and erp.object_current_state('document', d.id) = 'posted'
           and not exists (select 1 from erp.shipment_line sl
                             join erp.shipment sh on sh.tenant_id = sl.tenant_id and sh.id = sl.shipment_id
                            where sl.tenant_id = v_tenant and sl.document_id = d.id
                              and sh.status <> 'cancelled')
         group by d.site_id, d.party_id
         order by min(d.document_number)
      loop
        begin
          v_ship := erp.ship_deliveries(g.ids, v_day);
          v_arrive := null;
          select sh.planned_arrival + case when v_first then 2 else 0 end into v_arrive
            from erp.shipment sh
           where sh.tenant_id = v_tenant and sh.id = v_ship and sh.status = 'booked';
          if v_arrive is not null and v_arrive < erp.local_today(g.site_id) then
            perform erp.record_proof_of_delivery(v_ship, v_arrive::timestamptz + interval '11 hours',
                                                 'Goods in', 'DEMO-POD');
          end if;
          v_first := false;
          v_built := v_built + 1;
        exception when others then
          v_notes := v_notes || to_jsonb(format('A shipment of %s was not made: %s', v_day, sqlerrm));
        end;
      end loop;
    end;
  end if;

  -- ── The weekend count ────────────────────────────────────────────────────
$n$];
  v_def  text;
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_sigs, 1) loop
    v_def := pg_get_functiondef(v_sigs[v_i]::regprocedure);
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sigs[v_i], v_hits;
    end if;
    execute replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
end
$demo$;

-- ─────────────────────────────────────────────────────────────────────────────
-- I. Suites built as the demonstration is, which now installs logistics
-- ─────────────────────────────────────────────────────────────────────────────

do $suites$
declare
  v_sigs constant text[] := array[
    'erp_test.logistics_suite()',
    'erp_test.logistics_suite()',
    'erp_test.shipment_document_suite()',
    'erp_test.shipment_document_suite()'];
  v_pairs constant text[] := array[
    $o$    perform erp.ensure_demo_configuration(r2.tenant_id, r2.admin_user_id);
    perform erp.configure_logistics();
$o$,
    $n$    perform erp.ensure_demo_configuration(r2.tenant_id, r2.admin_user_id);
$n$,
    $o$    perform erp.ensure_demo_configuration(r.tenant_id, r.admin_user_id);
    perform erp.configure_logistics();

$o$,
    $n$    perform erp.ensure_demo_configuration(r.tenant_id, r.admin_user_id);

$n$,
    $o$    perform erp.ensure_demo_configuration(r.tenant_id, r.admin_user_id);
    perform erp.configure_logistics();

    -- ── 1. Installed as configuration ───────────────────────────────────────
$o$,
    $n$    perform erp.ensure_demo_configuration(r.tenant_id, r.admin_user_id);

    -- ── 1. Installed as configuration ───────────────────────────────────────
$n$,
    -- The installer moved on to version 3; the shipment came with 2.
    $o$                where i.tenant_id = r.tenant_id and i.install_code = 'logistics') = 2
$o$,
    $n$                where i.tenant_id = r.tenant_id and i.install_code = 'logistics')
              = (select mi.current_version from erp_ref.module_installer mi where mi.install_code = 'logistics')
$n$];
  v_def  text;
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_sigs, 1) loop
    v_def := pg_get_functiondef(v_sigs[v_i]::regprocedure);
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sigs[v_i], v_i, v_hits;
    end if;
    execute replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
end
$suites$;

-- ─────────────────────────────────────────────────────────────────────────────
-- J. A fixture: a site with stock, two customers, posted deliveries
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.despatch_fixture(p_tenant_id uuid, p_entity_id uuid, p_tag text,
                                                     p_deliveries integer default 4)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_uom uuid; v_site uuid; v_loc uuid; v_cust uuid; v_cust2 uuid; v_sup uuid; v_item uuid;
  v_grn uuid; v_dn uuid; v_dns uuid[] := '{}'; v_other uuid;
begin
  -- As erp_test.shipment_document_suite builds its own (20261002500000): one
  -- site, a kilogram a box so the rate card prices it (ROAD ECONOMY, 2000
  -- plus 50 a kilogram), p_deliveries posted to one customer and one to
  -- another, all dated today.
  select u.id into v_uom from erp.uom u where u.tenant_id = p_tenant_id order by u.code limit 1;
  insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
  values (p_tenant_id, p_entity_id, 'ZD' || upper(p_tag), 'Despatch ' || p_tag, 'warehouse', 'active')
  returning id into v_site;
  insert into erp.location (tenant_id, site_id, code, name, location_type, status)
  values (p_tenant_id, v_site, 'ZDSTK', 'Stock', 'bulk', 'active') returning id into v_loc;
  insert into erp.party (tenant_id, code, name, status)
  values (p_tenant_id, 'ZDC1' || upper(p_tag), 'Despatch customer', 'active') returning id into v_cust;
  insert into erp.party_role (tenant_id, party_id, role_kind, attributes, status)
  values (p_tenant_id, v_cust, 'customer', jsonb_build_object('credit_limit_minor', 100000000), 'active');
  insert into erp.party (tenant_id, code, name, status)
  values (p_tenant_id, 'ZDC2' || upper(p_tag), 'Despatch other customer', 'active') returning id into v_cust2;
  insert into erp.party_role (tenant_id, party_id, role_kind, attributes, status)
  values (p_tenant_id, v_cust2, 'customer', jsonb_build_object('credit_limit_minor', 100000000), 'active');
  insert into erp.party (tenant_id, code, name, status)
  values (p_tenant_id, 'ZDS' || upper(p_tag), 'Despatch supplier', 'active') returning id into v_sup;
  insert into erp.party_role (tenant_id, party_id, role_kind, status)
  values (p_tenant_id, v_sup, 'supplier', 'active');
  insert into erp.item (tenant_id, code, name, stock_uom_id, gross_weight_g, status)
  values (p_tenant_id, 'ZDBOX' || upper(p_tag), 'Despatch box', v_uom, 1000, 'active') returning id into v_item;
  v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
  perform erp.add_document_line(v_grn, v_item, 100, 1000, 'in');
  update erp.document_line set location_id = v_loc where document_id = v_grn;
  perform erp.transition_document(v_grn, 'post');
  for i in 1 .. p_deliveries loop
    v_dn := erp.open_document('delivery', v_cust, null, v_site);
    perform erp.add_document_line(v_dn, v_item, 2, 2500, 'out');
    update erp.document_line set location_id = v_loc where document_id = v_dn;
    perform erp.transition_document(v_dn, 'post');
    v_dns := v_dns || v_dn;
  end loop;
  v_other := erp.open_document('delivery', v_cust2, null, v_site);
  perform erp.add_document_line(v_other, v_item, 1, 2500, 'out');
  update erp.document_line set location_id = v_loc where document_id = v_other;
  perform erp.transition_document(v_other, 'post');
  return jsonb_build_object('site_id', v_site, 'customer_id', v_cust, 'other_customer_id', v_cust2,
                            'item_id', v_item, 'deliveries', to_jsonb(v_dns), 'other_delivery', v_other);
end;
$$;

revoke all on function erp_test.despatch_fixture(uuid, uuid, text, integer) from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- K. The budget of two, walked (L7)
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.despatch_walk()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  c_undo   constant text := 'CLOVEERP_DESPATCH_WALK_UNDO';
  v_hex    text := substr(md5(gen_random_uuid()::text), 1, 8);
  v_code   text;
  a1       uuid := gen_random_uuid();   -- the administrator, who sets up
  s_plan   uuid := gen_random_uuid();   -- the planner, who ships
  s_drive  uuid := gen_random_uuid();   -- the driver, who proves delivery
  p_plan   uuid; p_drive uuid;
  r        record;
  res      jsonb;
  v_r1     jsonb; v_r2 jsonb;
  v_fx     jsonb;
  v_ids    uuid[];
  v_ship   uuid;
  v_doc    uuid;
  v_booked text;
  v_need   integer;
  v_offer  boolean;
  v_steps  jsonb := '[]'::jsonb;
  v_subs   uuid[] := '{}';
  v_block  text;
  v_out    jsonb;
begin
  -- Despatch walked by pressing (20261004600000): an organisation configured
  -- as the demonstration is, which installs logistics; a planner who ships and
  -- a driver who proves delivery, neither an administrator, each holding only
  -- what their press needs. Two presses, from posted deliveries to delivered.
  begin
    v_code := 'zzdesw-' || v_hex;
    select * into r from erp.provision_tenant(
      v_code, 'Despatch walk', 'admin@' || v_code || '.test', 'Walk Admin');
    update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@' || v_code || '.test'), (s_plan, 'planner@' || v_code || '.test'),
           (s_drive, 'driver@' || v_code || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    perform erp.ensure_demo_configuration(r.tenant_id, r.admin_user_id);
    v_fx := erp_test.despatch_fixture(r.tenant_id, r.entity_id, v_hex, 2);
    select array_agg(x::uuid) into v_ids from jsonb_array_elements_text(v_fx -> 'deliveries') x;

    v_r1 := public.erp_save_role(null, 'planner', 'Planner', 'Ships what is posted',
                                 array['logistics.read', 'logistics.plan']);
    v_r2 := public.erp_save_role(null, 'driver', 'Driver', 'Delivers and records proof',
                                 array['logistics.read', 'logistics.despatch']);
    res := public.erp_invite_principal('planner@' || v_code || '.test', 'Pat Planner');
    p_plan := (res ->> 'app_user_id')::uuid;
    perform erp.grant_role(p_plan, 'planner', null, null, 'ships');
    perform set_config('request.jwt.claims', json_build_object('sub', s_plan)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    res := public.erp_invite_principal('driver@' || v_code || '.test', 'Dee Driver');
    p_drive := (res ->> 'app_user_id')::uuid;
    perform erp.grant_role(p_drive, 'driver', null, null, 'delivers');
    perform set_config('request.jwt.claims', json_build_object('sub', s_drive)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    update erp.environment set is_live = true where tenant_id = r.tenant_id and is_self;

    -- ─────────────────────────────────────────────────────────────────────
    -- The cycle: Ship these deliveries, then Record proof of delivery.
    -- ─────────────────────────────────────────────────────────────────────
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', s_plan)::text, true);
      v_ship := public.erp_ship_deliveries(v_ids, null, null, null, null);
      v_steps := v_steps || jsonb_build_object('door', 'erp_ship_deliveries', 'person', 'planner');
      v_subs := v_subs || s_plan;
      select sh.status::text, sh.document_id into v_booked, v_doc from erp.shipment sh where sh.id = v_ship;
      v_need := jsonb_array_length(public.erp_shipment_exceptions());

      perform set_config('request.jwt.claims', json_build_object('sub', s_drive)::text, true);
      v_offer := exists (select 1 from jsonb_array_elements(public.erp_shipments(200)) s
                          where (s ->> 'shipment_id')::uuid = v_ship and s ->> 'status' = 'booked');
      perform public.erp_record_proof_of_delivery(v_ship, now(), 'A. Customer', null);
      v_steps := v_steps || jsonb_build_object('door', 'erp_record_proof_of_delivery', 'person', 'driver');
      v_subs := v_subs || s_drive;
    exception when others then
      v_block := format('press %s: %s', jsonb_array_length(v_steps) + 1, left(sqlerrm, 300));
    end;

    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_out := jsonb_build_object(
      'roles_in_force', coalesce((v_r1 ->> 'in_force')::boolean and (v_r2 ->> 'in_force')::boolean, false),
      'live', erp.tenant_is_live(r.tenant_id),
      'presses', jsonb_array_length(v_steps),
      'people', (select count(distinct u) from unnest(v_subs) u),
      'administrators_pressing', (select count(*) from erp.organisation_administrators() a
                                   where a.app_user_id in (p_plan, p_drive)),
      'booked_in_one', v_booked = 'booked',
      'needs_a_person', v_need,
      'offered_to_the_driver', coalesce(v_offer, false),
      'state', erp.object_current_state('document', v_doc),
      'status_after', (select sh.status::text from erp.shipment sh where sh.id = v_ship),
      'blocked', v_block,
      'steps', v_steps);

    raise exception using message = c_undo;
  exception when others then
    if sqlerrm <> c_undo then
      v_out := jsonb_build_object('presses', 0, 'people', 0, 'blocked',
                 'setting up: ' || left(sqlerrm, 300), 'steps', v_steps);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return v_out;
end;
$$;

revoke all on function erp_test.despatch_walk() from public, anon, authenticated;

do $walk$
declare
  v_sig  constant text := 'erp_test.step_budget_suite()';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  c_expected constant integer := 14;
$o$,
    $n$  c_expected constant integer := 15;
$n$,
    $o$  v_vat     jsonb;
$o$,
    $n$  v_vat     jsonb;
  v_desp    jsonb;
$n$,
    $o$  if v_cases <> c_expected then
$o$,
    $n$  -- ── 15. Despatch, walked ───────────────────────────────────────────────
  --
  -- The budget is two (20261002500000), walked here (20261004600000): a
  -- planner ships two posted deliveries, which books the carrier the rate card
  -- recommends in the same press, and a driver records proof. Neither is an
  -- administrator, and nothing lands on the exceptions list.
  v_desp := erp_test.despatch_walk();

  v_cases := v_cases + 1;
  case_name := 'despatch is two presses by a planner and a driver who are not administrators, ship and prove, booked in the first and needing nobody else';
  passed := coalesce(v_desp ->> 'blocked' is null
            and (v_desp ->> 'roles_in_force')::boolean
            and (v_desp ->> 'live')::boolean
            and (v_desp ->> 'administrators_pressing')::integer = 0
            and (v_desp ->> 'presses')::integer = 2
            and (v_desp ->> 'people')::integer = 2
            and (v_desp ->> 'booked_in_one')::boolean
            and (v_desp ->> 'needs_a_person')::integer = 0
            and (v_desp ->> 'offered_to_the_driver')::boolean
            and v_desp ->> 'state' = 'delivered'
            and v_desp ->> 'status_after' = 'delivered', false);
  detail := coalesce('blocked at ' || (v_desp ->> 'blocked') || '; ', '')
            || format('roles in force %s, live %s, %s administrator(s) pressing; %s press(es) by %s person(s); booked in one %s; %s needing a person; offered to the driver %s; the shipment %s, its status %s',
                      coalesce(v_desp ->> 'roles_in_force', 'unknown'), coalesce(v_desp ->> 'live', 'unknown'),
                      coalesce(v_desp ->> 'administrators_pressing', 'an unknown number of'),
                      coalesce(v_desp ->> 'presses', '0'), coalesce(v_desp ->> 'people', '0'),
                      coalesce(v_desp ->> 'booked_in_one', 'unknown'), coalesce(v_desp ->> 'needs_a_person', 'unknown'),
                      coalesce(v_desp ->> 'offered_to_the_driver', 'unknown'),
                      coalesce(v_desp ->> 'state', 'nothing'), coalesce(v_desp ->> 'status_after', 'unknown'));
  return next;

  if v_cases <> c_expected then
$n$];
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
$walk$;

do $walk_count$
declare
  v_sig  constant text := 'erp_test.assert_step_budget_suite()';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  -- (20261001300000).
  c_expected constant integer := 14;
$o$;
  v_new  constant text := $n$  -- (20261001300000); despatch, walked, is case 15 (20261004600000).
  c_expected constant integer := 15;
$n$;
  v_hits integer := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
begin
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % count anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$walk_count$;

update erp_meta.flow_budget
   set rationale = rationale || ' Walked by erp_test.despatch_walk() (20261004600000).'
 where flow_code = 'despatch' and rationale not like '%despatch_walk%';

-- ─────────────────────────────────────────────────────────────────────────────
-- L. The proof: erp_test.despatch_exceptions_suite
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.despatch_exceptions_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 9;
  v_cases integer := 0;
  v_tag   text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1      uuid := gen_random_uuid();
  a2      uuid := gen_random_uuid();
  v_step  text := 'provisioning';
  v_state text;
  v_owner text := current_user;
  r       record; r2 record;
  v_fx    jsonb;
  v_dn    uuid[];
  v_other uuid;
  v_s1 uuid; v_s2 uuid; v_s3 uuid; v_s4 uuid; v_s5 uuid;
  v_ex    jsonb;
  v_row   jsonb;
  v_rows  jsonb;
  v_n     integer;
  v_ok    boolean;
  v_txt   text;
  v_tue   date;
  v_conf  jsonb;
begin
  begin
    v_step := 'an organisation configured as the demonstration is';
    perform set_config('request.jwt.claims', '', true);
    select * into r from erp.provision_tenant(
      'zzdx-' || v_tag, 'Despatch exceptions suite', 'admin@zzdx-' || v_tag || '.test', 'Despatch Admin');
    update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzdx-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    perform erp.ensure_demo_configuration(r.tenant_id, r.admin_user_id);
    v_fx := erp_test.despatch_fixture(r.tenant_id, r.entity_id, v_tag, 5);
    select array_agg(x::uuid order by o) into v_dn
      from jsonb_array_elements_text(v_fx -> 'deliveries') with ordinality as t(x, o);
    v_other := (v_fx ->> 'other_delivery')::uuid;

    -- ── 1. The setting ─────────────────────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'the shipping policy is a setting of despatch, five parameters, each default the clean path';
    select b.parameters, b.settings into v_n, v_txt
      from erp.parameter_budget_report() b where b.cycle_code = 'despatch';
    passed := v_n = 5 and v_txt like '%logistics.shipping_policy (5)%'
          and erp.shipping_policy() = '{"auto_select_carrier": true, "cost_override_tolerance_pct": 10, "late_after_days": 0, "proof_required": true, "consolidate": "customer_day"}'::jsonb;
    detail := format('%s parameter(s): %s', v_n, v_txt);
    return next;

    -- ── 2. The clean path needs nobody ─────────────────────────────────────
    v_step := 'shipping with every default';
    v_s1 := erp.ship_deliveries(array[v_dn[1]]);
    select x into v_row from jsonb_array_elements(public.erp_shipments(200)) x
     where (x ->> 'shipment_id')::uuid = v_s1;
    v_cases := v_cases + 1;
    case_name := 'shipped with every default, it is booked at the rate card''s price, on its way, not late, and needs nobody';
    passed := v_row ->> 'status' = 'booked'
          and (v_row ->> 'quoted_cost_minor')::bigint = (v_row ->> 'freight_cost_minor')::bigint
          and (v_row ->> 'on_its_way')::boolean and not (v_row ->> 'late')::boolean
          and not exists (select 1 from jsonb_array_elements(public.erp_shipment_exceptions()) e
                           where (e ->> 'shipment_id')::uuid = v_s1);
    detail := coalesce(v_row::text, 'not listed');
    return next;

    -- ── 3. A cost typed above the rate card ────────────────────────────────
    v_step := 'shipping at a cost well above the rate card';
    v_s2 := erp.ship_deliveries(array[v_dn[2]], null, 'ROAD', 'ECONOMY', 999999);
    v_ok := exists (select 1 from jsonb_array_elements(public.erp_shipment_exceptions()) e
                     where (e ->> 'shipment_id')::uuid = v_s2 and e ->> 'kind' = 'over_tolerance');
    perform erp.set_config_value('logistics.shipping_policy',
              jsonb_build_object('cost_override_tolerance_pct', 1000000));
    v_cases := v_cases + 1;
    case_name := 'a cost above the rate card by more than the tolerance is booked and flagged; inside it, not';
    passed := v_ok
          and (select sh.status::text from erp.shipment sh where sh.id = v_s2) = 'booked'
          and (select sh.quoted_cost_minor < sh.freight_cost_minor from erp.shipment sh where sh.id = v_s2)
          and not exists (select 1 from jsonb_array_elements(public.erp_shipment_exceptions()) e
                           where (e ->> 'shipment_id')::uuid = v_s2);
    detail := format('flagged at ten per cent %s; quoted %s, booked at %s', v_ok,
                     (select sh.quoted_cost_minor from erp.shipment sh where sh.id = v_s2),
                     (select sh.freight_cost_minor from erp.shipment sh where sh.id = v_s2));
    return next;

    -- ── 4. The planner chooses ─────────────────────────────────────────────
    v_step := 'shipping with the recommendation switched off';
    perform erp.set_config_value('logistics.shipping_policy',
              jsonb_build_object('auto_select_carrier', false));
    v_s3 := erp.ship_deliveries(array[v_dn[3]]);
    v_s4 := erp.ship_deliveries(array[v_dn[4]], null, 'ROAD', null, null);
    v_cases := v_cases + 1;
    case_name := 'without the recommendation, a shipment nobody names a carrier for is left planned and needs a person; one named is booked';
    passed := (select sh.status::text from erp.shipment sh where sh.id = v_s3) = 'planned'
          and exists (select 1 from jsonb_array_elements(public.erp_shipment_exceptions()) e
                       where (e ->> 'shipment_id')::uuid = v_s3 and e ->> 'kind' = 'planned')
          and (select sh.status::text from erp.shipment sh where sh.id = v_s4) = 'booked';
    detail := format('unnamed %s, named %s',
                     (select sh.status from erp.shipment sh where sh.id = v_s3),
                     (select sh.status from erp.shipment sh where sh.id = v_s4));
    return next;

    -- ── 5. Late, and the grace ─────────────────────────────────────────────
    v_step := 'a booked shipment past its arrival';
    perform erp.set_config_value('logistics.shipping_policy', '{}'::jsonb);
    update erp.shipment set planned_despatch = current_date - 5, planned_arrival = current_date - 2
     where id = v_s1;
    v_ok := exists (select 1 from jsonb_array_elements(public.erp_shipment_exceptions()) e
                     where (e ->> 'shipment_id')::uuid = v_s1 and e ->> 'kind' = 'late')
        and (select (x ->> 'late')::boolean from jsonb_array_elements(public.erp_shipments(200)) x
              where (x ->> 'shipment_id')::uuid = v_s1);
    perform erp.set_config_value('logistics.shipping_policy', jsonb_build_object('late_after_days', 3));
    v_cases := v_cases + 1;
    case_name := 'a booked shipment past its arrival with no proof reads late and needs a person; inside the grace it does not';
    passed := v_ok
          and not exists (select 1 from jsonb_array_elements(public.erp_shipment_exceptions()) e
                           where (e ->> 'shipment_id')::uuid = v_s1);
    detail := format('late with no grace %s', v_ok);
    return next;

    -- ── 6. Proof not required: the system delivers ─────────────────────────
    v_step := 'the sweep, with no proof recorded';
    perform erp.set_config_value('logistics.shipping_policy', jsonb_build_object('proof_required', false));
    -- As the job runs it: the organisation and nobody in it.
    perform set_config('request.jwt.claims', '', true);
    perform set_config('erp.job_tenant_id', r.tenant_id::text, true);
    v_n := erp.deliver_unproved_shipments('{}'::jsonb);
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'where no proof is recorded, the job delivers a shipment past its arrival as the system''s move, and leaves one still due';
    passed := v_n = 1
          and erp.object_current_state('document', (select sh.document_id from erp.shipment sh where sh.id = v_s1)) = 'delivered'
          and (select sh.status::text from erp.shipment sh where sh.id = v_s1) = 'delivered'
          and (select sh.proof_of_delivery ->> 'by' from erp.shipment sh where sh.id = v_s1) = 'the system'
          and (select sh.actual_arrival::date = sh.planned_arrival from erp.shipment sh where sh.id = v_s1)
          and (select sh.status::text from erp.shipment sh where sh.id = v_s4) = 'booked'
          and exists (select 1 from erp.access_log l
                       where l.tenant_id = r.tenant_id and l.granted
                         and l.object_id = (select sh.document_id from erp.shipment sh where sh.id = v_s1)
                         and l.reason like 'derived%'
                         and l.reason like '%shipment_needs_no_proof%');
    detail := format('%s delivered; the past one %s, the due one %s', v_n,
                     (select sh.status from erp.shipment sh where sh.id = v_s1),
                     (select sh.status from erp.shipment sh where sh.id = v_s4));
    return next;

    -- ── 7. With proof required, the job moves nothing ──────────────────────
    v_step := 'the sweep, with proof recorded';
    perform erp.set_config_value('logistics.shipping_policy', '{}'::jsonb);
    update erp.shipment set planned_despatch = current_date - 5, planned_arrival = current_date - 2
     where id = v_s4;
    v_cases := v_cases + 1;
    case_name := 'with proof recorded, the default, the job is installed, switched on, and moves nothing';
    passed := erp.deliver_unproved_shipments('{}'::jsonb) = 0
          and (select sh.status::text from erp.shipment sh where sh.id = v_s4) = 'booked'
          and exists (select 1 from erp.job j
                       where j.tenant_id = r.tenant_id and j.code = 'deliver_unproved_shipments'
                         and j.handler_code = 'logistics.deliver_unproved' and j.is_enabled)
          and (select i.installer_version from erp.module_installation i
                where i.tenant_id = r.tenant_id and i.install_code = 'logistics') = 3;
    detail := format('the due one %s', (select sh.status from erp.shipment sh where sh.id = v_s4));
    return next;

    -- ── 8. Offered together ────────────────────────────────────────────────
    v_step := 'reading the deliveries to ship';
    v_rows := public.erp_deliveries_to_ship(null, 30, 200);
    v_ok := (select count(distinct x ->> 'travels_with') from jsonb_array_elements(v_rows) x
              where (x ->> 'document_id')::uuid in (v_dn[5], v_other)) = 2
        and exists (select 1 from jsonb_array_elements(v_rows) x where (x ->> 'document_id')::uuid = v_dn[5]);
    perform erp.set_config_value('logistics.shipping_policy', jsonb_build_object('consolidate', 'none'));
    v_rows := public.erp_deliveries_to_ship(null, 30, 200);
    v_cases := v_cases + 1;
    case_name := 'the picker groups one customer''s deliveries of one site and day, and none when the policy says none';
    passed := v_ok
          and (select x ->> 'travels_with' from jsonb_array_elements(v_rows) x
                where (x ->> 'document_id')::uuid = v_dn[5])
              = (select d.document_number from erp.document d where d.id = v_dn[5]);
    detail := format('two customers two groups %s', v_ok);
    perform erp.set_config_value('logistics.shipping_policy', '{}'::jsonb);
    return next;

    -- ── 9. The demonstration ships ─────────────────────────────────────────
    v_step := 'a demonstration built across a month''s first Tuesday';
    perform set_config('request.jwt.claims', '', true);
    select * into r2 from erp.provision_tenant(
      'zzdxd-' || v_tag, 'Despatch demonstration', 'admin@zzdxd-' || v_tag || '.test', 'Demo Admin');
    update erp.environment set is_live = false where tenant_id = r2.tenant_id and is_self;
    insert into auth.users (id, email) values (a2, 'admin@zzdxd-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(r2.admin_token);
    v_conf := erp.ensure_demo_configuration(r2.tenant_id, r2.admin_user_id);
    -- The first Tuesday of the month two months back, and the six days before.
    v_tue := date_trunc('month', current_date - interval '2 months')::date;
    v_tue := v_tue + ((9 - extract(isodow from v_tue)::integer) % 7);
    perform erp.seed_demo_history(v_tue - 6, v_tue - 2, 1);
    perform erp.seed_demo_history(v_tue - 1, v_tue, 1);
    v_cases := v_cases + 1;
    case_name := 'a demonstration installs logistics and ships its week''s deliveries on Tuesday, signed for, one late';
    passed := (v_conf -> 'installed') ? 'logistics'
          and (select count(*) from erp.shipment sh where sh.tenant_id = r2.tenant_id) >= 1
          and (select count(*) from erp.shipment sh
                where sh.tenant_id = r2.tenant_id and sh.status = 'delivered'
                  and sh.actual_arrival::date > sh.planned_arrival) = 1
          and exists (select 1 from erp.delivery_performance(400) d);
    detail := format('%s shipment(s), %s delivered, %s late; installed %s',
                     (select count(*) from erp.shipment sh where sh.tenant_id = r2.tenant_id),
                     (select count(*) from erp.shipment sh where sh.tenant_id = r2.tenant_id and sh.status = 'delivered'),
                     (select count(*) from erp.shipment sh where sh.tenant_id = r2.tenant_id and sh.status = 'delivered'
                        and sh.actual_arrival::date > sh.planned_arrival),
                     v_conf -> 'installed');
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  execute format('set local role %I', v_owner);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('erp.job_tenant_id', '', true);

  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_DESPATCH_EXCEPTIONS_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the fixture stopped; a case that cannot run is a case that fails.';
  end if;
  if exists (select 1 from erp.tenant t where t.code in ('zzdx-' || v_tag, 'zzdxd-' || v_tag))
     or exists (select 1 from auth.users u where u.id in (a1, a2)) then
    raise exception 'CLOVEERP_DESPATCH_EXCEPTIONS_SUITE_LEAKED: the fixture was not undone'
      using hint = 'The suite must raise CLOVEERP_SUITE_UNDO inside its block so everything it made rolls back.';
  end if;
end;
$$;

revoke all on function erp_test.despatch_exceptions_suite() from public, anon, authenticated;

create or replace function erp_test.assert_despatch_exceptions_suite()
returns text
language plpgsql
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
    from erp_test.despatch_exceptions_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_DESPATCH_EXCEPTIONS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A shipping parameter stopped being read, a shipment that needs nobody landed on the exceptions list, or the demonstration stopped shipping. Read the case that failed.';
  end if;
  if v_total <> 9 then
    raise exception 'CLOVEERP_DESPATCH_EXCEPTIONS_SUITE_SHRANK: % case(s), expected 9', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('despatch exceptions: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_despatch_exceptions_suite() from public, anon;

comment on function erp_test.assert_despatch_exceptions_suite() is
  'The shipping policy''s five parameters are each read, the exceptions list holds only what needs a person, '
  'the sweep delivers as the system where no proof is recorded, and the demonstration ships (20261004600000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- M. The words the Despatch screen adds
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, module_code, description)
select erp_ref.ui_key(v.text), 'en', v.text, 'logistics',
       'A screen string of the Despatch screen (20261004600000).'
  from (values
    ('Needs a person'),
    ('Shipments left planned, late, or booked above the rate card by more than the shipping policy allows. A shipment on the clean path is never here.'),
    ('Nothing needs a person. A shipment appears here when no carrier quotes it, when it is past its arrival with no proof, or when it was booked well above the rate card.'),
    ('Shipment'),
    ('Why'),
    ('Customer'),
    ('Due'),
    ('Carrier'),
    ('Shipments'),
    ('On time'),
    ('On time %'),
    ('Freight'),
    ('Late'),
    ('booked and past their arrival'),
    ('on time, ninety days'),
    ('On time by carrier'),
    ('Delivered on or before the planned arrival, last ninety days.'),
    ('Delivered on or before the planned arrival, over the last ninety days, by carrier.'),
    ('No shipment delivered in the window. On time is measured from proof of delivery against the planned arrival, so this fills once shipments are signed for.'),
    ('shipments delivered, ninety days')
  ) as v(text)
on conflict do nothing;

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
select erp.assert_authorising_doors_are_volatile();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
select erp.assert_every_transition_is_driven();
select erp.assert_parameter_budget();
