set lock_timeout = '30s';

-- =============================================================================
-- 20261011090000  A contract may name a client deployment
-- -----------------------------------------------------------------------------
-- Every client now runs in its own Supabase project at <code>.cloveerp.com,
-- and the control plane keeps the register of them (20261011020000). The
-- contracts stay on the control plane (the plan's decision 9): what was sold,
-- signed, invoiced and renewed is the selling organisation's record, and it
-- must outlive any one client's database. Until now a contract could only
-- name an organisation on the same database, so a client with its own
-- project could not be sold to at all.
--
-- A contract now names one customer, either way:
--
--   an organisation here   tenant_id set, deployment_code null, exactly as
--                          before. Nothing about this path changes.
--   a client deployment    tenant_id null, deployment_code naming the
--                          register's row, tenant_code holding the same code
--                          as every screen already reads it. One contract in
--                          force per deployment, as per organisation.
--
-- erp.create_contract_from_quote looks the code up as an organisation first
-- and, failing that, in the register: on the control plane only, and not for
-- a deployment that is retired or being retired. A contract may precede the
-- end of its deployment's build, which takes hours.
--
-- What a contract provisions cannot be written into another database from
-- here. So where an organisation's contract writes its subscription, and
-- tells it by an event in its own stream, a deployment's contract queues what
-- it owes the deployment in a new outbox, erp_meta.deployment_push:
--
--   subscription  the contract's position — plan, term, whether it renews,
--                 grace once it has expired, and every dated entitlement and
--                 feature row — written whenever the position changes
--                 (signing, an amendment, a renewal, a non-renewal, the end
--                 of the term). A newer one supersedes one still pending.
--   notice        what the organisation's own event stream would have been
--                 told: signed, amended, renewed, not renewed, a key date, an
--                 invoice issued, the term ended.
--
-- Platform staff are reconciled across the fleet from the control plane's
-- list, not pushed, so there is no third kind. Nothing applies the outbox
-- yet: the entitlement sync (the plan's Phase 3) will. Until then a client's
-- database enforces no limit, as it does today with no contract at all
-- (erp.entitlement_limit is null without a subscription).
--
-- The drift check learns the second model: a deployment's contract in force
-- with no subscription queued, or with the newest one disagreeing with the
-- contract, is drift as a missing or edited subscription is for an
-- organisation. It does not yet ask that a push was applied: nothing applies
-- one, and a release proof must not go red for a step that does not exist.
--
-- A deployment's contract is given its invoice schedule when it is signed: a
-- contract in force with no schedule is a finding on the platform's own
-- assurance, and a client with its own project has nobody here to remember
-- to press the button. An organisation's contract is scheduled as it always
-- was, by the console or the sweep.
--
-- Invoices go to the contract's billing contact or, without one, to the
-- deployment's first administrator, as an organisation's go to its
-- administrators. Usage is not yet metered across databases, so a
-- deployment's invoices carry no overage until it is (Phase 3).
--
-- The console reads both: the contracts door lists client deployments beside
-- organisations, each saying where it lives, and every contract row says
-- which deployment it names; the selling state lists the deployments a
-- contract may name, apart from the organisations a platform organisation may
-- be chosen from.
--
-- CLOVEERP_UNKNOWN_TENANT, raised by every door that names an organisation by
-- code or id, is registered at last, in words that cover both models.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The refusals
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal(
  'CLOVEERP_CONTRACT_DEPLOYMENT_RETIRED',
  'Making a contract with a client deployment that is retired or being retired.',
  'A retired deployment is gone, and one being retired is on its way out: neither has a database that will hold '
  'what the contract sells.',
  'Choose a client deployment from the Fleet view that is not retired, or request a new one.');

select erp.register_refusal(
  'CLOVEERP_UNKNOWN_TENANT',
  'Naming an organisation that nothing here holds.',
  'Each organisation is known by its code on the deployment that holds it. On the control plane a contract may '
  'also name a client deployment from the register. A code that is neither belongs to nobody here.',
  'Choose the organisation from the list, or, for a contract, the client deployment from the Fleet view.');

-- ─────────────────────────────────────────────────────────────────────────────
-- B. A contract names one customer
-- ─────────────────────────────────────────────────────────────────────────────

alter table erp_meta.contract alter column tenant_id drop not null;
alter table erp_meta.contract add column if not exists deployment_code text
  references erp_meta.deployment (code) on update cascade;

do $one$
begin
  if not exists (select 1 from pg_catalog.pg_constraint k
                  where k.conrelid = 'erp_meta.contract'::regclass and k.conname = 'contract_names_one_customer') then
    alter table erp_meta.contract add constraint contract_names_one_customer
      check ((tenant_id is null) = (deployment_code is not null));
  end if;
end
$one$;

create unique index if not exists contract_one_active_per_deployment
  on erp_meta.contract (deployment_code)
  where deployment_code is not null and status in ('active', 'terminating');

comment on column erp_meta.contract.tenant_id is
  'The organisation on this database the contract is with; null when the contract names a client deployment '
  'instead (20261011090000).';
comment on column erp_meta.contract.deployment_code is
  'The client deployment from the register the contract is with, when the customer runs in its own project; null '
  'for an organisation on this database. tenant_code holds the same code, as it holds an organisation''s '
  '(20261011090000).';

alter table erp_meta.contract_invoice alter column tenant_id drop not null;

comment on column erp_meta.contract_invoice.tenant_id is
  'The organisation invoiced, when the contract is with one on this database; null for a client deployment''s '
  'contract, whose code is in tenant_code (20261011090000).';

-- What the control plane owes a client deployment.
create table if not exists erp_meta.deployment_push (
  id          uuid primary key default gen_random_uuid(),
  code        text not null references erp_meta.deployment (code) on update cascade,
  kind        text not null check (kind in ('subscription', 'notice')),
  contract_id uuid references erp_meta.contract (id) on delete cascade,
  payload     jsonb not null,
  status      text not null default 'pending'
                check (status in ('pending', 'claimed', 'applied', 'failed', 'superseded')),
  attempts    integer not null default 0 check (attempts >= 0),
  run_id      text,
  detail      text,
  -- The clock, not the transaction's start: two positions queued in one
  -- transaction are still told apart by when.
  created_at  timestamptz not null default clock_timestamp(),
  claimed_at  timestamptz,
  settled_at  timestamptz,
  constraint deployment_push_subscription_names_contract
    check (kind <> 'subscription' or contract_id is not null)
);

comment on table erp_meta.deployment_push is
  'What the control plane owes a client deployment from its contract (20261011090000): its subscription, the '
  'contract''s position, queued whenever that changes, and the notices its organisation''s event stream would '
  'have been told. Applied in the deployment''s own database by the entitlement sync; empty on every database '
  'but the control plane.';
comment on column erp_meta.deployment_push.payload is
  'For a subscription, erp_meta.deployment_subscription_payload(contract) as it was when queued. For a notice, '
  '{"event_type": ..., "payload": ...}, the event an organisation here would have been sent.';
comment on column erp_meta.deployment_push.status is
  'pending until the sync claims it; claimed, then applied or failed; superseded when a newer subscription for '
  'the same deployment was queued before this one was claimed.';

create unique index if not exists deployment_push_one_pending_subscription
  on erp_meta.deployment_push (code) where kind = 'subscription' and status = 'pending';
create index if not exists deployment_push_open
  on erp_meta.deployment_push (created_at) where status in ('pending', 'claimed');
create index if not exists deployment_push_contract
  on erp_meta.deployment_push (contract_id, kind, created_at desc);

select erp_meta.register_table('erp_meta', 'deployment_push', 'platform_internal',
  'What the control plane owes a client deployment from its contract: its subscription and the notices its '
  'organisation would have been told. Written by the contract routines, applied by the entitlement sync.');

revoke all on table erp_meta.deployment_push from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The position, and the outbox's one writer
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_meta.deployment_subscription_payload(p_contract_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- Every dated row, not only those in force today, so an amendment dated
  -- from tomorrow needs no second push (20261011090000).
  select jsonb_build_object(
    'tenant_code', c.deployment_code,
    'contract_ref', c.id,
    'contract_status', c.status,
    'plan_code', c.plan_code,
    'support_severity_code', c.support_severity_code,
    'term_start', c.current_term_start,
    'term_end', c.current_term_end,
    'currency', c.currency,
    'renews', c.renewal_kind = 'automatic' and c.status in ('active', 'terminating'),
    'status', case when c.status = 'expired' then 'grace' else 'active' end,
    'entitlements', coalesce((select jsonb_agg(jsonb_build_object(
                                       'code', ce.entitlement_code, 'limit_value', ce.limit_value,
                                       'effective_from', ce.effective_from, 'effective_to', ce.effective_to)
                                     order by ce.entitlement_code, ce.effective_from, ce.id)
                                from erp_meta.contract_entitlement ce
                               where ce.contract_id = c.id), '[]'::jsonb),
    'capabilities', coalesce((select jsonb_agg(jsonb_build_object(
                                       'code', cc.capability_code,
                                       'effective_from', cc.effective_from, 'effective_to', cc.effective_to)
                                     order by cc.capability_code, cc.effective_from, cc.id)
                                from erp_meta.contract_capability cc
                               where cc.contract_id = c.id), '[]'::jsonb))
    from erp_meta.contract c
   where c.id = p_contract_id
     and c.deployment_code is not null
$$;

revoke all on function erp_meta.deployment_subscription_payload(uuid) from public, anon, authenticated, service_role;

comment on function erp_meta.deployment_subscription_payload(uuid) is
  'A client deployment''s contract as the position its database is to apply: plan, term, whether it renews, '
  'active or grace, and every dated entitlement and feature row. Null for an organisation''s contract. Called '
  'by the contract routines that provision, and by the drift check that compares (20261011090000).';

create or replace function erp_meta.queue_deployment_push(p_code text, p_kind text, p_contract_id uuid, p_payload jsonb)
returns uuid
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_id uuid;
begin
  -- One position pending per deployment: the newest is what it is owed, so
  -- one not yet claimed is superseded rather than applied after it
  -- (20261011090000).
  if p_kind = 'subscription' then
    update erp_meta.deployment_push p
       set status = 'superseded', settled_at = clock_timestamp(), detail = 'a later position was queued'
     where p.code = p_code and p.kind = 'subscription' and p.status = 'pending';
  end if;
  insert into erp_meta.deployment_push (code, kind, contract_id, payload)
  values (p_code, p_kind, p_contract_id, p_payload)
  returning id into v_id;
  return v_id;
end;
$$;

revoke all on function erp_meta.queue_deployment_push(text, text, uuid, jsonb) from public, anon, authenticated, service_role;

comment on function erp_meta.queue_deployment_push(text, text, uuid, jsonb) is
  'Queues what the control plane owes a client deployment: a subscription (superseding one still pending) or a '
  'notice. Called only from the contract routines, which run as their owner; executable by no session role '
  '(20261011090000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The contract routines learn the second model
-- ─────────────────────────────────────────────────────────────────────────────
--
-- Each is re-created whole from its body on main, with the change marked
-- (20261011090000). First, that the bodies are still the ones this was
-- written against: a body changed since would be silently undone.

do $guard$
declare
  r     record;
  v_src text;
begin
  for r in
    select * from (values
      ('erp.create_contract_from_quote(uuid,text,text,text,date,integer,text,integer,text,text,jsonb,jsonb,date,integer)',
       'e1a6ebf633511ed5643f3f493976ae63'),
      ('erp.provision_entitlement_from_contract(uuid)', '06b275cf3990ebc103d430d756d02f89'),
      ('erp.sign_contract(uuid,text,text,text)', '7c52a4a57e79a5705b5dd03f5aff46d0'),
      ('erp.sign_amendment(uuid,text,text,text)', '24cea2579b1af419c262ea56b4a99486'),
      ('erp.renew_contract(uuid,text,text,text)', '72a0616852922bc2b88788baca70e093'),
      ('erp.decline_renewal(uuid,text)', 'db78ae354ac61c637f8602cdace3a627'),
      ('erp.expire_contracts()', '62169da83e3c0bceb469e185ef7b0542'),
      ('erp.raise_contract_key_dates()', 'ada1e892391463f9a652147170766449'),
      ('erp.issue_contract_invoice(uuid)', 'bc058759107653b03840397fc79ccda5'),
      ('erp.contract_billing_recipients(uuid)', '8968267f72e9104961b14b661f13ff08'),
      ('erp.contract_provisioning_report()', '3ff1415b17ce48152eb070c374c143f2'),
      ('erp.contract_position(uuid)', '33992c1c3ce0a4a117dc632985c28dc5'),
      ('public.erp_platform_contracts()', 'c4fd3d19828519f3300da16fb073c4cb'),
      ('public.erp_platform_commercial_state()', '55ed378aa9841408eebee95eb7439b39')
    ) as v(sig, expected)
  loop
    v_src := (select p.prosrc from pg_catalog.pg_proc p where p.oid = r.sig::regprocedure);
    if strpos(v_src, '20261011090000') > 0 then
      continue;
    end if;
    if md5(v_src) <> r.expected then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261011090000 expects (md5 %)', r.sig, md5(v_src)
        using hint = 'Another migration changed it since. Carry that change into this one''s copy and update the anchor.';
    end if;
  end loop;
end
$guard$;

-- 1. A contract is made with an organisation here or a client deployment.

CREATE OR REPLACE FUNCTION erp.create_contract_from_quote(p_quote_document_id uuid, p_customer_tenant_code text, p_customer_legal_name text, p_platform_legal_name text, p_commencement date, p_initial_term_months integer DEFAULT 12, p_renewal_kind text DEFAULT 'automatic'::text, p_notice_days integer DEFAULT 90, p_governing_law text DEFAULT 'England and Wales'::text, p_billing_frequency text DEFAULT 'annual'::text, p_uplift_rule jsonb DEFAULT '{"kind": "none"}'::jsonb, p_termination_terms jsonb DEFAULT '{}'::jsonb, p_review_date date DEFAULT NULL::date, p_lead_days integer DEFAULT 30)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  v_deployment erp_meta.deployment;
begin
  v_staff := erp_meta.require_platform('operator');
  select po.tenant_id into v_platform from erp_meta.platform_organisation po;
  if v_platform is null then
    raise exception 'CLOVEERP_NO_PLATFORM_ORGANISATION: designate the platform''s organisation first' using errcode = '23503';
  end if;
  select * into v_tenant from erp.tenant t where t.code = p_customer_tenant_code;
  if not found then
    -- Or a client deployment from the register, which runs in its own
    -- project and is sold to from here: on the control plane alone, and
    -- not once it is retired or being retired. A contract may precede the
    -- end of its build (20261011090000).
    select * into v_deployment from erp_meta.deployment x where x.code = lower(btrim(coalesce(p_customer_tenant_code, '')));
    if not found then
      raise exception 'CLOVEERP_UNKNOWN_TENANT: % is neither an organisation on this deployment nor a client deployment', p_customer_tenant_code
        using errcode = '23503',
              hint = 'Choose the organisation, or the client deployment from the Fleet view, that the contract is with.';
    end if;
    perform erp.require_control_plane();
    if v_deployment.status in ('retiring', 'retired') then
      raise exception 'CLOVEERP_CONTRACT_DEPLOYMENT_RETIRED: % is %, and a contract is made with a deployment that will hold it', v_deployment.code, v_deployment.status
        using errcode = '23514',
              hint = 'Choose a client deployment from the Fleet view that is not retired, or request a new one.';
    end if;
  end if;
  if v_tenant.id = v_platform then
    raise exception 'CLOVEERP_PLATFORM_CANNOT_CONTRACT_WITH_ITSELF' using errcode = '23514';
  end if;
  if exists (select 1 from erp_meta.contract c
              where c.status in ('active', 'terminating')
                and (c.tenant_id = v_tenant.id or c.deployment_code = v_deployment.code)) then
    raise exception 'CLOVEERP_CONTRACT_IN_FORCE: % already has a contract in force; change it by amendment', coalesce(v_tenant.code, v_deployment.code)
      using errcode = '23514';
  end if;

  select cq.* into q from erp.commercial_quote cq where cq.tenant_id = v_platform and cq.document_id = p_quote_document_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_QUOTE: %', p_quote_document_id using errcode = '23503';
  end if;
  select * into d from erp.document x where x.id = p_quote_document_id;
  select s.code into v_state
    from erp.object_state os join erp.state s on s.id = os.current_state_id
   where os.tenant_id = v_platform and os.object_type = 'document' and os.object_id = p_quote_document_id;
  if v_state <> 'accepted' then
    raise exception 'CLOVEERP_QUOTE_NOT_ACCEPTED: version % is %, and a contract is created from an accepted quote', q.version, v_state
      using errcode = '23514', hint = 'Issue the order form and accept the quote when it comes back signed.';
  end if;
  if q.order_form_render_id is null then
    raise exception 'CLOVEERP_QUOTE_HAS_NO_ORDER_FORM' using errcode = '23514';
  end if;
  if p_renewal_kind not in ('automatic', 'by_agreement', 'none') or p_billing_frequency not in ('annual', 'quarterly', 'monthly') then
    raise exception 'CLOVEERP_CONTRACT_TERMS_UNKNOWN: renewal % or billing %', p_renewal_kind, p_billing_frequency using errcode = '23514';
  end if;

  -- What the quote sold, read from the document lines in the platform
  -- organisation's own context so the margin reader scopes correctly.
  perform erp_meta.act_in_tenant(v_platform);
  m := erp.quote_margin(p_quote_document_id);
  perform erp_meta.stop_acting_in_tenant();

  select x ->> 'plan_code' into v_plan from jsonb_array_elements(m -> 'lines') x where x ->> 'kind' = 'plan_tier' limit 1;
  if v_plan is null then
    raise exception 'CLOVEERP_QUOTE_HAS_NO_PLAN' using errcode = '23514';
  end if;
  select x ->> 'support_severity_code' into v_severity from jsonb_array_elements(m -> 'lines') x where x ->> 'kind' = 'support_tier' limit 1;
  v_annual := (m -> 'totals' ->> 'recurring_minor')::bigint * case q.term_kind when 'monthly' then 12 else 1 end;

  -- The customer is an organisation here or a client deployment, never both;
  -- tenant_code holds whichever code it is (20261011090000).
  insert into erp_meta.contract
    (tenant_id, tenant_code, platform_tenant_id, quote_document_id, quote_number, quote_version,
     customer_legal_name, platform_legal_name, plan_code, support_severity_code, term_kind, currency,
     annual_value_minor, billing_frequency, commencement, initial_term_months,
     current_term_start, current_term_end, renewal_kind, notice_days, governing_law,
     uplift_rule, termination_terms, review_date, lead_days, created_by, deployment_code)
  values (v_tenant.id, coalesce(v_tenant.code, v_deployment.code), v_platform, p_quote_document_id, d.document_number, q.version,
          p_customer_legal_name, p_platform_legal_name, v_plan, v_severity, q.term_kind, q.currency,
          v_annual, p_billing_frequency, p_commencement, p_initial_term_months,
          p_commencement, (p_commencement + make_interval(months => p_initial_term_months))::date,
          p_renewal_kind, p_notice_days, p_governing_law,
          coalesce(p_uplift_rule, '{"kind": "none"}'::jsonb), coalesce(p_termination_terms, '{}'::jsonb),
          p_review_date, p_lead_days, v_staff.email, v_deployment.code)
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
      values (v_id, l ->> 'entitlement_code',
              coalesce((l ->> 'band_to')::numeric,
                       (select pe.limit_value from erp_meta.plan_entitlement pe
                         where pe.plan_code = v_plan and pe.entitlement_code = l ->> 'entitlement_code')
                       + (l ->> 'quantity')::numeric),
              p_commencement);
    elsif l ->> 'kind' = 'plan_tier'
          and not exists (select 1 from jsonb_array_elements(m -> 'lines') b
                           where b ->> 'entitlement_code' = 'users') then
      -- The full users sold: what the plan includes and every extra full
      -- user on the quote. A users band, where one is sold, sets the limit
      -- instead (20260915011000).
      insert into erp_meta.contract_entitlement (contract_id, entitlement_code, limit_value, effective_from)
      select v_id, 'users',
             pi.included_users
               + coalesce((select sum((f ->> 'quantity')::numeric)
                             from jsonb_array_elements(m -> 'lines') f
                            where f ->> 'kind' = 'full_user'), 0),
             p_commencement
        from erp.price_item pi
        join erp.item i on i.tenant_id = pi.tenant_id and i.id = pi.item_id
       where pi.tenant_id = v_platform and i.code = l ->> 'item_code'
         and pi.included_users is not null;
    elsif l ->> 'kind' = 'light_user' then
      -- A light user item names no entitlement: its quantity is the number of
      -- light users sold, and that is the limit (20260914095000).
      insert into erp_meta.contract_entitlement (contract_id, entitlement_code, limit_value, effective_from)
      values (v_id, 'light_users', (l ->> 'quantity')::numeric, p_commencement);
    elsif l ->> 'kind' = 'capability_addon' then
      insert into erp_meta.contract_capability (contract_id, capability_code, effective_from)
      values (v_id, l ->> 'capability_code', p_commencement);
    end if;
  end loop;

  -- What is charged once, to ride on the first invoice issued.
  insert into erp_meta.contract_charge (contract_id, item_code, description, quantity, amount_minor, currency)
  select v_id, x ->> 'item_code', x ->> 'name', (x ->> 'quantity')::numeric, (x ->> 'quoted_minor')::bigint, q.currency
    from jsonb_array_elements(m -> 'lines') x
   where x ->> 'charge' = 'one_off';

  perform erp_meta.platform_log(
    v_staff, 'platform.contract_created', v_tenant.id, v_id::text,
    format('from quote %s v%s', d.document_number, q.version),
    jsonb_build_object('plan', v_plan, 'annual_value_minor', v_annual, 'commencement', p_commencement)
      || case when v_deployment.code is not null then jsonb_build_object('deployment', v_deployment.code) else '{}'::jsonb end);
  return v_id;
end;
$function$;

comment on function erp.create_contract_from_quote(uuid, text, text, text, date, integer, text, integer, text, text, jsonb, jsonb, date, integer) is
  'Creates a draft contract from an accepted quote, with an organisation on this database or, on the control '
  'plane, a client deployment from the register that is not retired: what was sold as dated entitlement and '
  'feature rows, the order form with its checksum, and the one-off charges. Platform operator and above '
  '(20260904610000, 20261011090000).';

-- 2. Signing provisions: a subscription here, or a position queued for the
--    deployment.

CREATE OR REPLACE FUNCTION erp.provision_entitlement_from_contract(p_contract_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c erp_meta.contract; v_sub uuid;
begin
  select * into c from erp_meta.contract where id = p_contract_id;
  if not found or c.status not in ('active', 'terminating') then
    raise exception 'CLOVEERP_CONTRACT_NOT_IN_FORCE: % is %', p_contract_id, coalesce(c.status, 'unknown') using errcode = '23514';
  end if;
  -- A client deployment's subscription lives in its own database: what it is
  -- owed is queued for it, and the queued row's id is returned in place of a
  -- subscription's (20261011090000).
  if c.tenant_id is null then
    return erp_meta.queue_deployment_push(c.deployment_code, 'subscription', c.id,
                                          erp_meta.deployment_subscription_payload(c.id));
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
$function$;

CREATE OR REPLACE FUNCTION erp.sign_contract(p_contract_id uuid, p_customer_signer text, p_platform_signer text, p_signature_meaning text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_staff erp_meta.platform_staff; c erp_meta.contract; v_sub uuid; v_scheduled integer;
begin
  v_staff := erp_meta.require_platform('operator');
  select * into c from erp_meta.contract where id = p_contract_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_CONTRACT: %', p_contract_id using errcode = '23503';
  end if;
  if c.status <> 'draft' then
    raise exception 'CLOVEERP_CONTRACT_ALREADY_SIGNED: % is %', p_contract_id, c.status using errcode = '23514';
  end if;
  if coalesce(btrim(p_customer_signer), '') = '' or coalesce(btrim(p_platform_signer), '') = '' or coalesce(btrim(p_signature_meaning), '') = '' then
    raise exception 'CLOVEERP_SIGNATURE_INCOMPLETE: a signature names both signers and what signing means (§9.3)' using errcode = '23514';
  end if;
  if not exists (select 1 from erp_meta.contract_document d where d.contract_id = p_contract_id and d.kind = 'order_form') then
    raise exception 'CLOVEERP_CONTRACT_HAS_NO_ORDER_FORM' using errcode = '23514';
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

  if c.tenant_id is not null then
    perform erp_meta.act_in_tenant(c.tenant_id);
    perform erp.append_event('commercial.contract_signed', 'tenant', c.tenant_id,
      jsonb_build_object('contract_id', c.id, 'plan', c.plan_code, 'term_end', c.current_term_end));
    perform erp_meta.stop_acting_in_tenant();
  else
    -- A client deployment is told by a notice queued for it, and its invoice
    -- schedule is written now: a contract in force with none is a finding,
    -- and nobody here is the deployment's to remember it (20261011090000).
    perform erp_meta.queue_deployment_push(c.deployment_code, 'notice', c.id,
      jsonb_build_object('event_type', 'commercial.contract_signed',
                         'payload', jsonb_build_object('contract_id', c.id, 'plan', c.plan_code, 'term_end', c.current_term_end)));
    v_scheduled := erp.generate_invoice_schedule(p_contract_id);
  end if;

  perform erp_meta.platform_log(v_staff, 'platform.contract_signed', c.tenant_id, c.id::text,
                                format('signed by %s and %s: %s', p_customer_signer, p_platform_signer, p_signature_meaning),
                                jsonb_build_object('subscription_id', v_sub, 'plan', c.plan_code)
                                  || case when c.deployment_code is not null
                                          then jsonb_build_object('deployment', c.deployment_code, 'invoices_scheduled', v_scheduled)
                                          else '{}'::jsonb end);
  return v_sub;
end;
$function$;

CREATE OR REPLACE FUNCTION erp.sign_amendment(p_amendment_id uuid, p_customer_signer text, p_platform_signer text, p_signature_meaning text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_staff erp_meta.platform_staff; a erp_meta.contract_amendment; c erp_meta.contract; x jsonb; v_sub uuid;
begin
  v_staff := erp_meta.require_platform('operator');
  select * into a from erp_meta.contract_amendment where id = p_amendment_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_AMENDMENT: %', p_amendment_id using errcode = '23503';
  end if;
  if a.signed_at is not null then
    raise exception 'CLOVEERP_AMENDMENT_ALREADY_SIGNED' using errcode = '23514';
  end if;
  if coalesce(btrim(p_customer_signer), '') = '' or coalesce(btrim(p_platform_signer), '') = '' or coalesce(btrim(p_signature_meaning), '') = '' then
    raise exception 'CLOVEERP_SIGNATURE_INCOMPLETE: a signature names both signers and what signing means (§9.3)' using errcode = '23514';
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

  if c.tenant_id is not null then
    perform erp_meta.act_in_tenant(c.tenant_id);
    perform erp.append_event('commercial.contract_amended', 'tenant', c.tenant_id,
      jsonb_build_object('contract_id', c.id, 'amendment_id', a.id, 'effective_from', a.effective_from));
    perform erp_meta.stop_acting_in_tenant();
  else
    -- The new position is queued above, superseding one still pending; the
    -- deployment is told as an organisation would be (20261011090000).
    perform erp_meta.queue_deployment_push(c.deployment_code, 'notice', c.id,
      jsonb_build_object('event_type', 'commercial.contract_amended',
                         'payload', jsonb_build_object('contract_id', c.id, 'amendment_id', a.id, 'effective_from', a.effective_from)));
  end if;

  perform erp_meta.platform_log(v_staff, 'platform.contract_amended', c.tenant_id, c.id::text,
                                format('amendment %s signed: %s', a.seq, a.title), a.changes);
  return v_sub;
end;
$function$;

-- 3. Renewal, non-renewal and the end of a term.

CREATE OR REPLACE FUNCTION erp.renew_contract(p_renewal_id uuid, p_customer_signer text, p_platform_signer text, p_signature_meaning text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_staff erp_meta.platform_staff; r erp_meta.renewal; c erp_meta.contract; v_state text; v_seq integer;
  v_amend uuid; v_annual bigint; m jsonb; v_sub uuid;
begin
  v_staff := erp_meta.require_platform('operator');
  select * into r from erp_meta.renewal where id = p_renewal_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_RENEWAL: %', p_renewal_id using errcode = '23503';
  end if;
  if r.status <> 'quoted' or r.quote_document_id is null then
    raise exception 'CLOVEERP_RENEWAL_NOT_QUOTED: the renewal is %', r.status using errcode = '23514';
  end if;
  select * into c from erp_meta.contract where id = r.contract_id;
  select s.code into v_state
    from erp.object_state os join erp.state s on s.id = os.current_state_id
   where os.tenant_id = c.platform_tenant_id and os.object_type = 'document' and os.object_id = r.quote_document_id;
  if v_state <> 'accepted' then
    raise exception 'CLOVEERP_QUOTE_NOT_ACCEPTED: the renewal quote is %', v_state using errcode = '23514';
  end if;
  if coalesce(btrim(p_customer_signer), '') = '' or coalesce(btrim(p_platform_signer), '') = '' or coalesce(btrim(p_signature_meaning), '') = '' then
    raise exception 'CLOVEERP_SIGNATURE_INCOMPLETE: a signature names both signers and what signing means (§9.3)' using errcode = '23514';
  end if;

  perform erp_meta.act_in_tenant(c.platform_tenant_id);
  m := erp.quote_margin(r.quote_document_id);
  perform erp_meta.stop_acting_in_tenant();
  v_annual := (m -> 'totals' ->> 'recurring_minor')::bigint * case c.term_kind when 'monthly' then 12 else 1 end;

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

  if c.tenant_id is not null then
    perform erp_meta.act_in_tenant(c.tenant_id);
    perform erp.append_event('commercial.contract_renewed', 'tenant', c.tenant_id,
      jsonb_build_object('contract_id', c.id, 'term_start', r.term_start, 'term_end', r.term_end, 'annual_value_minor', v_annual));
    perform erp_meta.stop_acting_in_tenant();
  else
    -- The renewed position is queued above; the deployment is told
    -- (20261011090000).
    perform erp_meta.queue_deployment_push(c.deployment_code, 'notice', c.id,
      jsonb_build_object('event_type', 'commercial.contract_renewed',
                         'payload', jsonb_build_object('contract_id', c.id, 'term_start', r.term_start, 'term_end', r.term_end,
                                                       'annual_value_minor', v_annual)));
  end if;
  perform erp_meta.platform_log(v_staff, 'platform.contract_renewed', c.tenant_id, c.id::text,
                                format('renewed to %s at %s', r.term_end, v_annual), jsonb_build_object('renewal_id', r.id));
  return v_amend;
end;
$function$;

CREATE OR REPLACE FUNCTION erp.decline_renewal(p_renewal_id uuid, p_note text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_staff erp_meta.platform_staff; r erp_meta.renewal; c erp_meta.contract;
begin
  v_staff := erp_meta.require_platform('operator');
  select * into r from erp_meta.renewal where id = p_renewal_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_RENEWAL: %', p_renewal_id using errcode = '23503';
  end if;
  if coalesce(btrim(p_note), '') = '' then
    raise exception 'CLOVEERP_NON_RENEWAL_HAS_NO_NOTE: a non-renewal says why' using errcode = '23514';
  end if;
  select * into c from erp_meta.contract where id = r.contract_id;
  update erp_meta.renewal set status = 'declined', decided_at = now(), decision_note = btrim(p_note) where id = p_renewal_id;
  -- §17.10: "non-renewal follows the lifecycle in §17.3 with the notice period
  -- honoured and export offered before any restriction". The contract runs to
  -- its term end as terminating; the subscription stops renewing; the
  -- organisation is told now, with its term end.
  update erp_meta.contract set status = 'terminating', renewal_kind = 'none', updated_at = now() where id = c.id;
  if c.tenant_id is not null then
    update erp_meta.subscription set renews = false, updated_at = now() where tenant_id = c.tenant_id and status <> 'terminated';
    perform erp_meta.act_in_tenant(c.tenant_id);
    perform erp.append_event('commercial.non_renewal_recorded', 'tenant', c.tenant_id,
      jsonb_build_object('contract_id', c.id, 'term_end', c.current_term_end, 'note', btrim(p_note)));
    perform erp_meta.stop_acting_in_tenant();
  else
    -- A client deployment's subscription stops renewing by a new position,
    -- read from the contract as it now stands, and it is told
    -- (20261011090000).
    perform erp_meta.queue_deployment_push(c.deployment_code, 'subscription', c.id,
                                           erp_meta.deployment_subscription_payload(c.id));
    perform erp_meta.queue_deployment_push(c.deployment_code, 'notice', c.id,
      jsonb_build_object('event_type', 'commercial.non_renewal_recorded',
                         'payload', jsonb_build_object('contract_id', c.id, 'term_end', c.current_term_end, 'note', btrim(p_note))));
  end if;
  perform erp_meta.platform_log(v_staff, 'platform.non_renewal_recorded', c.tenant_id, c.id::text, btrim(p_note), '{}'::jsonb);
end;
$function$;

CREATE OR REPLACE FUNCTION erp.expire_contracts()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c record; v_n integer := 0;
begin
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_SWEEP: this runs across every organisation, so it needs a session whose role bypasses row-level security; % does not', current_user
      using errcode = '42501';
  end if;
  for c in select * from erp_meta.contract x where x.status in ('active', 'terminating') and x.current_term_end < current_date loop
    update erp_meta.contract set status = 'expired', updated_at = now() where id = c.id;
    update erp_meta.renewal set status = 'lapsed', decided_at = now() where contract_id = c.id and status in ('proposed', 'quoted');
    if c.tenant_id is null then
      -- A client deployment goes to grace by the position queued for it, read
      -- from the contract now expired, and is told; there is no organisation
      -- here to act in, and one that failed would stop the sweep for every
      -- other contract (20261011090000).
      perform erp_meta.queue_deployment_push(c.deployment_code, 'subscription', c.id,
                                             erp_meta.deployment_subscription_payload(c.id));
      perform erp_meta.queue_deployment_push(c.deployment_code, 'notice', c.id,
        jsonb_build_object('event_type', 'commercial.term_ended',
                           'payload', jsonb_build_object('contract_id', c.id, 'term_end', c.current_term_end)));
    else
      -- §17.3: grace — service continues, administrators notified, no functional
      -- change. Restriction is a platform operator's act after the notice, never
      -- a sweep's.
      update erp_meta.subscription set status = 'grace', renews = false, updated_at = now()
       where tenant_id = c.tenant_id and status = 'active';
      perform erp_meta.act_in_tenant(c.tenant_id);
      perform erp.append_event('commercial.term_ended', 'tenant', c.tenant_id,
        jsonb_build_object('contract_id', c.id, 'term_end', c.current_term_end));
    end if;
    v_n := v_n + 1;
  end loop;
  perform erp_meta.stop_acting_in_tenant();
  return v_n;
end;
$function$;

CREATE OR REPLACE FUNCTION erp.raise_contract_key_dates()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c record; k record; v_event uuid; v_raised integer := 0;
begin
  if not erp.session_is_trusted() then
    raise exception
      'CLOVEERP_UNTRUSTED_SWEEP: this runs across every organisation, so it needs '
      'a session whose role bypasses row-level security; % does not', current_user
      using errcode = '42501';
  end if;
  for c in select * from erp_meta.contract where status in ('active', 'terminating') order by tenant_code loop
    -- A client deployment has no organisation here to act in (20261011090000).
    if c.tenant_id is not null then
      perform erp_meta.act_in_tenant(c.tenant_id);
    end if;
    for k in select * from erp.contract_key_dates(c.id) d
              where d.due_on >= current_date - 1 and d.days_left <= c.lead_days
                and not exists (select 1 from erp_meta.contract_notice n where n.contract_id = c.id and n.kind = d.kind and n.due_on = d.due_on)
    loop
      if c.tenant_id is null then
        -- Told by a notice queued for it; the key date is held as raised
        -- with no event of this database's (20261011090000).
        v_event := null;
        perform erp_meta.queue_deployment_push(c.deployment_code, 'notice', c.id,
          jsonb_build_object('event_type', 'commercial.' || case k.kind when 'expiry' then 'renewal' else k.kind end || '_announced',
                             'payload', jsonb_strip_nulls(jsonb_build_object('contract_id', c.id, 'due_on', k.due_on, 'days_left', k.days_left,
                                                                             'uplift_rule', case when k.kind = 'uplift' then c.uplift_rule end))));
      else
        v_event := erp.append_event(
          'commercial.' || case k.kind when 'expiry' then 'renewal' else k.kind end || '_announced', 'tenant', c.tenant_id,
          jsonb_strip_nulls(jsonb_build_object('contract_id', c.id, 'due_on', k.due_on, 'days_left', k.days_left,
                                               'uplift_rule', case when k.kind = 'uplift' then c.uplift_rule end)));
      end if;
      insert into erp_meta.contract_notice (contract_id, kind, due_on, event_id) values (c.id, k.kind, k.due_on, v_event);
      v_raised := v_raised + 1;
    end loop;
  end loop;
  perform erp_meta.stop_acting_in_tenant();
  return v_raised;
end;
$function$;

-- 4. Invoices: issued and sent to the deployment's billing contact or first
--    administrator.

CREATE OR REPLACE FUNCTION erp.issue_contract_invoice(p_invoice_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_staff erp_meta.platform_staff; i erp_meta.contract_invoice; c erp_meta.contract; v_over jsonb; v_over_minor bigint; v_lines jsonb; v_one_off jsonb; v_one_off_minor bigint := 0; v_terms jsonb; v_due date;
begin
  v_staff := erp_meta.require_platform('operator');
  select * into i from erp_meta.contract_invoice where id = p_invoice_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_INVOICE: %', p_invoice_id using errcode = '23503';
  end if;
  if i.status <> 'scheduled' then
    raise exception 'CLOVEERP_INVOICE_NOT_SCHEDULED: % is %', i.reference, i.status using errcode = '23514';
  end if;
  select * into c from erp_meta.contract where id = i.contract_id;
  -- Due fourteen days from issue, and what the invoice says about VAT, from the
  -- one place those terms are held (20260914093000).
  v_terms := erp.contract_invoice_terms(c.platform_legal_name);
  v_due := current_date + (v_terms ->> 'payment_days')::integer;
  v_over := erp.invoice_overage_lines(p_invoice_id);
  select coalesce(sum((x ->> 'net_minor')::bigint), 0) into v_over_minor from jsonb_array_elements(v_over) x;
  v_lines := jsonb_build_array(jsonb_build_object(
               'kind', 'subscription', 'description', format('%s plan, %s to %s', c.plan_code, i.period_start, i.period_end),
               'net_minor', i.subscription_minor)) || v_over;
  -- One-off charges not yet invoiced ride on this invoice, and say so.
  select coalesce(jsonb_agg(jsonb_build_object('kind', 'one_off', 'item_code', ch.item_code, 'description', ch.description,
                                               'quantity', ch.quantity, 'net_minor', ch.amount_minor)
                            order by ch.created_at), '[]'::jsonb),
         coalesce(sum(ch.amount_minor), 0)::bigint
    into v_one_off, v_one_off_minor
    from erp_meta.contract_charge ch
   where ch.contract_id = c.id and ch.invoice_id is null;
  update erp_meta.contract_charge set invoice_id = p_invoice_id where contract_id = c.id and invoice_id is null;
  v_lines := v_lines || v_one_off;
  update erp_meta.contract_invoice
     set status = 'issued', issued_at = now(), due_on = v_due, tax_statement = v_terms ->> 'tax_statement', lines = v_lines, overage_minor = v_over_minor, one_off_minor = v_one_off_minor,
         total_minor = i.subscription_minor + v_over_minor + v_one_off_minor
   where id = p_invoice_id;
  -- The invoice goes to the customer the moment it is issued (20260914097300).
  perform erp.queue_commercial_email('contract_invoice', p_invoice_id);
  if c.tenant_id is not null then
    perform erp_meta.act_in_tenant(c.tenant_id);
    perform erp.append_event('commercial.invoice_issued', 'tenant', c.tenant_id,
      jsonb_build_object('invoice_id', i.id, 'reference', i.reference, 'total_minor', i.subscription_minor + v_over_minor + v_one_off_minor, 'overage_minor', v_over_minor));
    perform erp_meta.stop_acting_in_tenant();
  else
    -- A client deployment is told by a notice queued for it (20261011090000).
    perform erp_meta.queue_deployment_push(c.deployment_code, 'notice', c.id,
      jsonb_build_object('event_type', 'commercial.invoice_issued',
                         'payload', jsonb_build_object('invoice_id', i.id, 'reference', i.reference,
                                                       'total_minor', i.subscription_minor + v_over_minor + v_one_off_minor,
                                                       'overage_minor', v_over_minor)));
  end if;
  perform erp_meta.platform_log(v_staff, 'platform.invoice_issued', c.tenant_id, i.reference,
                                format('%s %s, overage %s', i.subscription_minor + v_over_minor + v_one_off_minor, i.currency, v_over_minor), '{}'::jsonb);
  return jsonb_build_object('invoice_id', i.id, 'reference', i.reference, 'total_minor', i.subscription_minor + v_over_minor + v_one_off_minor,
                            'overage_minor', v_over_minor, 'lines', v_lines,
                            'due_on', v_due, 'tax_statement', v_terms ->> 'tax_statement');
end;
$function$;

CREATE OR REPLACE FUNCTION erp.contract_billing_recipients(p_contract_id uuid)
 RETURNS TABLE(address text, display_name text, source text)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select btrim(c.billing_email), nullif(btrim(c.billing_name), ''), 'billing_contact'::text
    from erp_meta.contract c
   where c.id = p_contract_id
     and erp.email_address_usable(c.billing_email)
  union all
  select a.address, a.display_name, 'administrator'::text
    from erp_meta.contract c
    cross join lateral erp.organisation_administrators(c.tenant_id) a
   where c.id = p_contract_id
     and not erp.email_address_usable(c.billing_email)
  union all
  -- A client deployment's organisation is in another database: its first
  -- administrator, as the register holds them until it is retired, stands in
  -- for an organisation's administrators (20261011090000).
  select btrim(d.owner_email), d.client_name, 'administrator'::text
    from erp_meta.contract c
    join erp_meta.deployment d on d.code = c.deployment_code
   where c.id = p_contract_id
     and c.tenant_id is null
     and not erp.email_address_usable(c.billing_email)
     and erp.email_address_usable(d.owner_email)
$function$;

-- 5. What the console and the drift check read.

CREATE OR REPLACE FUNCTION erp.contract_provisioning_report()
 RETURNS TABLE(finding text, reference text, detail text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  -- D35: a contract in force whose organisation has no subscription, or a
  -- subscription that disagrees with its contract. Either is drift.
  select 'a contract in force has provisioned no subscription', c.tenant_code, c.id::text
    from erp_meta.contract c
   where c.status in ('active', 'terminating')
     and c.tenant_id is not null
     and not exists (select 1 from erp_meta.subscription s where s.tenant_id = c.tenant_id and s.status <> 'terminated')
  union all
  select 'the subscription disagrees with the contract that provisioned it', c.tenant_code,
         format('subscription %s %s→%s, contract %s %s→%s', s.plan_code, s.term_start, s.term_end, c.plan_code, c.current_term_start, c.current_term_end)
    from erp_meta.contract c
    join erp_meta.subscription s on s.tenant_id = c.tenant_id and s.status <> 'terminated'
   where c.status in ('active', 'terminating')
     and c.tenant_id is not null
     and (s.plan_code <> c.plan_code or s.term_start <> c.current_term_start or s.term_end is distinct from c.current_term_end
          or s.renews <> (c.renewal_kind = 'automatic'))
  union all
  -- A client deployment's subscription is in its own database; what the
  -- control plane can see is the position queued for it. None queued, in
  -- flight or applied is a contract provisioning nothing; the newest
  -- disagreeing with the contract is drift. Whether a push was applied is
  -- not asked until something applies them (20261011090000).
  select 'a contract in force has queued no subscription for its deployment', c.tenant_code, c.id::text
    from erp_meta.contract c
   where c.status in ('active', 'terminating')
     and c.deployment_code is not null
     and not exists (select 1 from erp_meta.deployment_push p
                      where p.contract_id = c.id and p.kind = 'subscription'
                        and p.status in ('pending', 'claimed', 'applied'))
  union all
  select 'the subscription queued for the deployment disagrees with its contract', c.tenant_code,
         format('queued %s %s→%s, contract %s %s→%s', p.payload ->> 'plan_code', p.payload ->> 'term_start',
                p.payload ->> 'term_end', c.plan_code, c.current_term_start, c.current_term_end)
    from erp_meta.contract c
    cross join lateral (select x.payload
                          from erp_meta.deployment_push x
                         where x.contract_id = c.id and x.kind = 'subscription'
                           and x.status in ('pending', 'claimed', 'applied')
                         order by x.created_at desc, x.id desc
                         limit 1) p
    cross join lateral (select erp_meta.deployment_subscription_payload(c.id) as payload) n
   where c.status in ('active', 'terminating')
     and c.deployment_code is not null
     and (p.payload -> 'plan_code', p.payload -> 'support_severity_code', p.payload -> 'term_start',
          p.payload -> 'term_end', p.payload -> 'renews', p.payload -> 'status',
          p.payload -> 'entitlements', p.payload -> 'capabilities')
         is distinct from
         (n.payload -> 'plan_code', n.payload -> 'support_severity_code', n.payload -> 'term_start',
          n.payload -> 'term_end', n.payload -> 'renews', n.payload -> 'status',
          n.payload -> 'entitlements', n.payload -> 'capabilities')
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
$function$;

CREATE OR REPLACE FUNCTION erp.contract_position(p_contract_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'id', c.id, 'tenant_code', c.tenant_code, 'status', c.status,
    -- The client deployment the contract names, or null for an organisation
    -- here (20261011090000).
    'deployment_code', c.deployment_code,
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
    -- An organisation's subscription here, or, for a client deployment, the
    -- newest position queued for it and how far it has got
    -- (20261011090000).
    'subscription', coalesce(
                      (select jsonb_build_object('id', s.id, 'plan_code', s.plan_code, 'term_start', s.term_start, 'term_end', s.term_end,
                                                 'renews', s.renews, 'status', s.status)
                         from erp_meta.subscription s where s.tenant_id = c.tenant_id and s.status <> 'terminated' limit 1),
                      (select jsonb_build_object('id', p.id, 'plan_code', p.payload ->> 'plan_code',
                                                 'term_start', p.payload ->> 'term_start', 'term_end', p.payload ->> 'term_end',
                                                 'renews', (p.payload ->> 'renews')::boolean, 'status', p.payload ->> 'status',
                                                 'push_status', p.status, 'queued_at', p.created_at)
                         from erp_meta.deployment_push p
                        where p.contract_id = c.id and p.kind = 'subscription' and p.status <> 'superseded'
                        order by p.created_at desc, p.id desc
                        limit 1)),
    'notices', coalesce((select jsonb_agg(jsonb_build_object('kind', n.kind, 'due_on', n.due_on, 'raised_at', n.raised_at) order by n.due_on)
                           from erp_meta.contract_notice n where n.contract_id = c.id), '[]'::jsonb))
    from erp_meta.contract c where c.id = p_contract_id
$function$;

CREATE OR REPLACE FUNCTION public.erp_platform_contracts()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
               'unsigned_amendments', (select count(*) from erp_meta.contract_amendment a where a.contract_id = c.id and a.signed_at is null),
               -- The client deployment the contract names, or null for an
               -- organisation here (20261011090000).
               'deployment_code', c.deployment_code)
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
    -- Whom a contract may be made with: an organisation here, or a client
    -- deployment from the register that is not retired, each saying where it
    -- lives (20261011090000).
    'organisations', coalesce((select jsonb_agg(o.item order by o.code)
                                 from (select t.code, jsonb_build_object('code', t.code, 'name', t.name, 'where', 'organisation') as item
                                         from erp.tenant t where t.status::text in ('active', 'grace', 'restricted')
                                          and t.id <> coalesce((select po.tenant_id from erp_meta.platform_organisation po), '00000000-0000-0000-0000-000000000000'::uuid)
                                       union all
                                       select x.code, jsonb_build_object('code', x.code, 'name', x.client_name, 'where', 'deployment')
                                         from erp_meta.deployment x where x.status not in ('retiring', 'retired')) o), '[]'::jsonb),
    'findings', coalesce((select jsonb_agg(jsonb_build_object('finding', f.finding, 'reference', f.reference, 'detail', f.detail))
                            from erp.contract_provisioning_report() f), '[]'::jsonb));
end;
$function$;

CREATE OR REPLACE FUNCTION public.erp_platform_commercial_state()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v          erp_meta.platform_staff;
  v_platform uuid;
begin
  v := erp_meta.require_platform('support');
  select po.tenant_id into v_platform from erp_meta.platform_organisation po;
  return jsonb_build_object(
    'platform_organisation', (select jsonb_build_object(
        'tenant_id', po.tenant_id, 'tenant_code', po.tenant_code,
        'name', (select t.name from erp.tenant t where t.id = po.tenant_id),
        'designated_at', po.designated_at, 'designated_by', po.designated_by, 'reason', po.reason,
        'status', (select t.status::text from erp.tenant t where t.id = po.tenant_id))
      from erp_meta.platform_organisation po),
    -- Demonstration organisations are marked, because nobody sells from one.
    'candidates', coalesce((select jsonb_agg(jsonb_build_object(
                                     'code', t.code, 'name', t.name,
                                     'is_demonstration', erp.tenant_is_demonstration(t.id))
                                   order by t.name)
                              from erp.tenant t where t.status::text = 'active'), '[]'::jsonb),
    -- The client deployments a quote or a contract may name, kept apart from
    -- the organisations above, one of which may be designated to sell: a
    -- deployment never can be (20261011090000).
    'deployments', coalesce((select jsonb_agg(jsonb_build_object('code', x.code, 'name', x.client_name, 'status', x.status)
                                    order by x.client_name, x.code)
                               from erp_meta.deployment x where x.status not in ('retiring', 'retired')), '[]'::jsonb),
    'price_items', (select count(*) from erp.price_item pi where pi.tenant_id = v_platform),
    'selling', case when v_platform is null then null else jsonb_build_object(
        'installed', exists (select 1 from erp.state_machine m
                              where m.tenant_id = v_platform and m.code = 'commercial_quote' and m.status = 'active'),
        'price_book', (select jsonb_build_object('code', co.code, 'name', cv.value ->> 'name',
                                                 'version', cv.version, 'effective_from', cv.effective_from)
                         from erp.config_object co
                         join erp.config_version cv on cv.tenant_id = co.tenant_id and cv.config_object_id = co.id
                        where co.tenant_id = v_platform and co.config_type_code = 'commercial.price_book'
                          and co.status = 'active' and cv.status = 'active'
                          and cv.effective_from <= current_date
                          and (cv.effective_to is null or cv.effective_to > current_date)
                        order by co.code = 'CLOVE-LIST' desc, cv.version desc
                        limit 1),
        'rates', (select count(*) from erp.item_price p
                   where p.tenant_id = v_platform and p.price_kind = 'sales_list' and p.price_list_code like '%/%'),
        'waiting', exists (select 1 from erp.change_set cs
                            where cs.tenant_id = v_platform
                              and (cs.code = 'commercial' or cs.code like 'price-book-%')
                              and cs.status in ('draft', 'ready', 'approved', 'promoting')))
      end,
    'findings', coalesce((select jsonb_agg(jsonb_build_object('finding', f.finding, 'reference', f.reference, 'detail', f.detail))
                            from erp.commercial_report() f), '[]'::jsonb));
end;
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- E. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.contract_names_a_deployment_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 16;
  -- The register's own word, named rather than written inline
  -- (erp.record_status_literal_report(), 20261011040000).
  c_retired  constant text := 'retired';
  v_cases    integer := 0;
  v_tag      text := substr(md5(gen_random_uuid()::text), 1, 6);
  v_step     text := 'marking the control plane';
  v_state    text;
  v_kind     text := erp.deployment_kind();
  rp record; rc record;
  ad uuid := gen_random_uuid(); ow uuid := gen_random_uuid();
  v_platform uuid; v_pcode text;
  v_customer uuid; v_ccode text;
  v_dcode    text; v_gone text; v_owner_email text;
  v_qd uuid; v_qt uuid; v_qr uuid;
  v_dc uuid; v_tc uuid;
  v_push uuid; v_push2 uuid; v_amend uuid; v_renewal uuid; v_inv uuid;
  v_got text; v_got2 text; v_got3 text;
  v_json jsonb; v_json2 jsonb;
  v_n integer; v_n2 integer;
begin
  begin
    v_pcode := 'zzcnp-' || v_tag;
    v_ccode := 'zzcnc-' || v_tag;
    v_dcode := 'zzcnd-' || v_tag;
    v_gone  := 'zzcng-' || v_tag;
    v_owner_email := 'admin@' || v_dcode || '.test';

    -- The control plane's marker, undone at the end with everything else.
    delete from erp_meta.platform_setting where key = 'deployment.kind';
    insert into erp_meta.platform_setting (key, value, reason)
    values ('deployment.kind', '"production"'::jsonb, 'contract_names_a_deployment_suite');

    -- The selling organisation, an organisation it sells to, and an owner.
    v_step := 'standing up the platform organisation';
    select * into rp from erp.provision_tenant(v_pcode, 'Clove Platform Deployment Contracts', 'admin@' || v_pcode || '.test', 'Platform Admin');
    v_platform := rp.tenant_id;
    select * into rc from erp.provision_tenant(v_ccode, 'Gamma Foods Ltd', 'admin@' || v_ccode || '.test', 'Customer Admin');
    v_customer := rc.tenant_id;
    insert into auth.users (id, email) values (ad, 'admin@' || v_pcode || '.test'), (ow, 'owner@' || v_pcode || '.test');
    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
    values ('owner@' || v_pcode || '.test', ow, 'Deployment Contract Suite Owner', 'owner');
    perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
    perform erp.claim_invitation(rp.admin_token);
    perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
    -- With a reason, so that a database which already sells from an
    -- organisation moves the designation for the suite, and the undo moves it
    -- back, rather than refusing.
    perform erp.designate_platform_organisation(v_pcode, 'The deployment contract suite sells from its own organisation, and undoes it.');

    -- The book, and two accepted quotes: one for a client deployment, one for
    -- the organisation.
    v_step := 'opening the price book and accepting two quotes';
    perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
    perform erp_test.reopen_bootstrap_window(v_platform);
    perform erp.configure_commercial(10, 'administrator');
    perform erp.open_price_book('PB-2026', 'List 2026', array['GBP'], current_date - 1, null);
    perform erp_test.close_bootstrap_window(v_platform);
    perform erp.upsert_price_item('PLAN-STD', 'Standard plan', 'plan_tier', 'standard');
    perform erp.upsert_price_item('USERS-250', 'Up to 250 users', 'user_band', null, null, 'users', 101, 250);
    perform erp.upsert_price_item('CAP-SERIAL', 'Serialisation', 'capability_addon', null, 'serialisation');
    perform erp.set_rate('PB-2026', 'PLAN-STD', 'GBP', 1200000);
    perform erp.set_rate('PB-2026', 'USERS-250', 'GBP', 500000);
    perform erp.set_rate('PB-2026', 'CAP-SERIAL', 'GBP', 150000);
    perform erp.set_cost_model('PLAN-STD', 'GBP', 300000, 100000, 50000);
    perform erp.set_cost_model('USERS-250', 'GBP', 100000, 50000, 0);
    perform erp.set_cost_model('CAP-SERIAL', 'GBP', 20000, 10000, 0);
    v_qd := erp.open_commercial_quote('DELTA', 'Delta Client Ltd', 'PB-2026', 'annual', 12, 'GBP', 30, v_dcode);
    perform erp.add_quote_line(v_qd, 'PLAN-STD');
    perform erp.add_quote_line(v_qd, 'USERS-250');
    perform erp.add_quote_line(v_qd, 'CAP-SERIAL');
    perform erp.submit_quote(v_qd);
    perform erp.issue_quote(v_qd);
    perform erp.quote_transition(v_qd, 'accept', 'order form returned signed');
    v_qt := erp.open_commercial_quote('GAMMA', 'Gamma Foods Ltd', 'PB-2026', 'annual', 12, 'GBP', 30, v_ccode);
    perform erp.add_quote_line(v_qt, 'PLAN-STD');
    perform erp.submit_quote(v_qt);
    perform erp.issue_quote(v_qt);
    perform erp.quote_transition(v_qt, 'accept', 'order form returned signed');

    -- Two client deployments in the register: one live, one retired.
    v_step := 'registering two client deployments';
    insert into erp_meta.deployment (code, client_name, status, owner_email, note)
    values (v_dcode, 'Delta Client Ltd', 'live', v_owner_email, 'contract_names_a_deployment_suite'),
           (v_gone, 'Gone Client Ltd', c_retired, null, 'contract_names_a_deployment_suite');

    -- ── 1. A contract names a client deployment ────────────────────────────
    v_step := 'making a contract with a client deployment';
    perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
    v_dc := erp.create_contract_from_quote(v_qd, v_dcode, 'Delta Client Ltd', 'Clove Ltd', current_date);
    v_json := erp.contract_position(v_dc);
    v_cases := v_cases + 1;
    case_name := 'a contract names a client deployment by its code: no organisation here, the code held, and what the quote sold as dated rows';
    passed := coalesce((select c.tenant_id is null and c.deployment_code = v_dcode and c.tenant_code = v_dcode and c.status = 'draft'
                          from erp_meta.contract c where c.id = v_dc), false)
          and v_json ->> 'deployment_code' = v_dcode
          and jsonb_array_length(v_json -> 'entitlements') = 1
          and jsonb_array_length(v_json -> 'capabilities') = 1
          and jsonb_typeof(v_json -> 'subscription') = 'null'
          and exists (select 1 from erp_meta.platform_audit a
                       where a.action = 'platform.contract_created' and a.target = v_dc::text
                         and a.tenant_id is null and a.detail ->> 'deployment' = v_dcode);
    detail := format('%s: %s entitlement(s), %s feature(s), subscription %s',
                     v_json ->> 'tenant_code', jsonb_array_length(v_json -> 'entitlements'),
                     jsonb_array_length(v_json -> 'capabilities'), v_json -> 'subscription');
    return next;

    -- ── 2. A code that is neither ──────────────────────────────────────────
    v_step := 'naming a code that is neither';
    begin
      perform erp.create_contract_from_quote(v_qd, 'zzcnx-' || v_tag, 'Nobody Ltd', 'Clove Ltd', current_date);
      v_got := 'a contract was made';
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a code that is neither an organisation here nor a client deployment is refused, in words that say both';
    passed := v_got = 'CLOVEERP_UNKNOWN_TENANT: zzcnx-' || v_tag || ' is neither an organisation on this deployment nor a client deployment';
    detail := left(v_got, 140);
    return next;

    -- ── 3. Not a retired deployment ────────────────────────────────────────
    v_step := 'naming a retired deployment';
    begin
      perform erp.create_contract_from_quote(v_qd, v_gone, 'Gone Client Ltd', 'Clove Ltd', current_date);
      v_got := 'a contract was made';
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a retired deployment is sold nothing';
    passed := v_got like 'CLOVEERP_CONTRACT_DEPLOYMENT_RETIRED: ' || v_gone || ' is retired%'
          and not exists (select 1 from erp_meta.contract c where c.deployment_code = v_gone);
    detail := left(v_got, 140);
    return next;

    -- ── 4. Signing queues the position, and nothing is written here ────────
    v_step := 'signing the deployment''s contract';
    v_push := erp.sign_contract(v_dc, 'D. Client, Finance Director', 'P. Owner, Clove Ltd',
                                'Agreement to the order form and the terms it names');
    v_json := (select p.payload from erp_meta.deployment_push p where p.id = v_push);
    v_cases := v_cases + 1;
    case_name := 'signing provisions no subscription here: the position is queued for the deployment, which is told by a notice, not by an event here';
    passed := (select c.status from erp_meta.contract c where c.id = v_dc) = 'active'
          and not exists (select 1 from erp_meta.subscription s where s.tenant_code = v_dcode)
          and coalesce((select p.kind = 'subscription' and p.status = 'pending' and p.code = v_dcode and p.contract_id = v_dc
                          from erp_meta.deployment_push p where p.id = v_push), false)
          and v_json = erp_meta.deployment_subscription_payload(v_dc)
          and v_json ->> 'tenant_code' = v_dcode and v_json ->> 'plan_code' = 'standard'
          and v_json ->> 'status' = 'active' and (v_json ->> 'renews')::boolean
          and v_json ->> 'term_end' = ((current_date + interval '12 months')::date)::text
          and exists (select 1 from jsonb_array_elements(v_json -> 'entitlements') e
                       where e ->> 'code' = 'users' and (e ->> 'limit_value')::numeric = 250)
          and exists (select 1 from jsonb_array_elements(v_json -> 'capabilities') x where x ->> 'code' = 'serialisation')
          and (select count(*) from erp_meta.deployment_push p where p.code = v_dcode and p.kind = 'subscription') = 1
          and exists (select 1 from erp_meta.deployment_push p
                       where p.code = v_dcode and p.kind = 'notice' and p.contract_id = v_dc
                         and p.payload ->> 'event_type' = 'commercial.contract_signed')
          and not exists (select 1 from erp.event e
                           where e.event_type = 'commercial.contract_signed' and e.payload ->> 'contract_id' = v_dc::text);
    detail := coalesce(left(v_json::text, 160), 'nothing queued');
    return next;

    -- ── 5. And schedules its invoices ──────────────────────────────────────
    v_step := 'reading the deployment''s invoice schedule';
    v_cases := v_cases + 1;
    case_name := 'a deployment''s contract is given its invoice schedule when it is signed, so the customer view finds none missing';
    v_n := (select count(*) from erp_meta.contract_invoice i
             where i.contract_id = v_dc and i.tenant_id is null and i.tenant_code = v_dcode
               and i.reference like 'INV-' || upper(v_dcode) || '-%');
    passed := v_n = 1
          and erp.generate_invoice_schedule(v_dc) = 0
          and not exists (select 1 from erp.customer_view_report() f where f.detail = v_dc::text);
    detail := format('%s invoice(s) scheduled for an annual term', v_n);
    return next;

    -- ── 6. One customer, one contract in force ─────────────────────────────
    v_step := 'making a second contract with the same deployment';
    begin
      perform erp.create_contract_from_quote(v_qd, v_dcode, 'Delta Client Ltd', 'Clove Ltd', current_date);
      v_got := 'a second contract was made';
    exception when others then
      v_got := sqlerrm;
    end;
    begin
      insert into erp_meta.contract
        (tenant_id, tenant_code, platform_tenant_id, quote_document_id, quote_number, quote_version,
         customer_legal_name, platform_legal_name, plan_code, term_kind, currency, commencement, initial_term_months,
         current_term_start, current_term_end, governing_law, created_by, status, deployment_code)
      select null, c.tenant_code, c.platform_tenant_id, c.quote_document_id, c.quote_number, c.quote_version,
             c.customer_legal_name, c.platform_legal_name, c.plan_code, c.term_kind, c.currency, c.commencement, c.initial_term_months,
             c.current_term_start, c.current_term_end, c.governing_law, c.created_by, 'active', c.deployment_code
        from erp_meta.contract c where c.id = v_dc;
      v_got2 := 'a second was held';
    exception when others then
      v_got2 := sqlstate || ' ' || sqlerrm;
    end;
    begin
      insert into erp_meta.contract
        (tenant_id, tenant_code, platform_tenant_id, quote_document_id, quote_number, quote_version,
         customer_legal_name, platform_legal_name, plan_code, term_kind, currency, commencement, initial_term_months,
         current_term_start, current_term_end, governing_law, created_by, deployment_code)
      select v_customer, c.tenant_code, c.platform_tenant_id, c.quote_document_id, c.quote_number, c.quote_version,
             c.customer_legal_name, c.platform_legal_name, c.plan_code, c.term_kind, c.currency, c.commencement, c.initial_term_months,
             c.current_term_start, c.current_term_end, c.governing_law, c.created_by, c.deployment_code
        from erp_meta.contract c where c.id = v_dc;
      v_got3 := 'one naming both was held';
    exception when others then
      v_got3 := sqlstate || ' ' || sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a deployment holds one contract in force, by the routine and by the table, and a contract names one customer, never two';
    passed := v_got like 'CLOVEERP_CONTRACT_IN_FORCE: ' || v_dcode || ' already has a contract in force%'
          and v_got2 like '23505 %contract_one_active_per_deployment%'
          and v_got3 like '23514 %contract_names_one_customer%';
    detail := left(v_got, 60) || ' / ' || left(v_got2, 80) || ' / ' || left(v_got3, 80);
    return next;

    -- ── 7. The console reads both models ───────────────────────────────────
    v_step := 'reading the console';
    v_json := public.erp_platform_contracts();
    v_json2 := public.erp_platform_commercial_state();
    v_cases := v_cases + 1;
    case_name := 'the console offers deployments that are not retired beside organisations, each saying where it lives, and names the deployment on its contract';
    passed := exists (select 1 from jsonb_array_elements(v_json -> 'organisations') o
                       where o ->> 'code' = v_dcode and o ->> 'where' = 'deployment' and o ->> 'name' = 'Delta Client Ltd')
          and exists (select 1 from jsonb_array_elements(v_json -> 'organisations') o
                       where o ->> 'code' = v_ccode and o ->> 'where' = 'organisation' and o ->> 'name' = 'Gamma Foods Ltd')
          and not exists (select 1 from jsonb_array_elements(v_json -> 'organisations') o where o ->> 'code' in (v_gone, v_pcode))
          and exists (select 1 from jsonb_array_elements(v_json -> 'contracts') x
                       where x ->> 'id' = v_dc::text and x ->> 'deployment_code' = v_dcode and x ->> 'tenant_code' = v_dcode)
          and not exists (select 1 from jsonb_array_elements(v_json -> 'findings') f where f ->> 'reference' = v_dcode)
          and exists (select 1 from jsonb_array_elements(v_json2 -> 'deployments') x
                       where x ->> 'code' = v_dcode and x ->> 'name' = 'Delta Client Ltd' and x ->> 'status' = 'live')
          and not exists (select 1 from jsonb_array_elements(v_json2 -> 'deployments') x where x ->> 'code' = v_gone)
          and not exists (select 1 from jsonb_array_elements(v_json2 -> 'candidates') x where x ->> 'code' = v_dcode)
          and erp.contract_position(v_dc) -> 'subscription' ->> 'push_status' = 'pending'
          and erp.contract_position(v_dc) -> 'subscription' ->> 'plan_code' = 'standard';
    detail := format('%s organisation(s) offered, %s deployment(s) listed; position %s',
                     jsonb_array_length(v_json -> 'organisations'), jsonb_array_length(v_json2 -> 'deployments'),
                     erp.contract_position(v_dc) -> 'subscription');
    return next;

    -- ── 8. Drift is caught for a deployment as for an organisation ─────────
    v_step := 'losing and editing the queued position';
    v_got := erp.assert_contract_provisions_entitlement();
    delete from erp_meta.deployment_push p where p.contract_id = v_dc and p.kind = 'subscription';
    begin
      perform erp.assert_contract_provisions_entitlement();
      v_got2 := 'it passed';
    exception when others then
      v_got2 := sqlerrm;
    end;
    v_n := (select count(*) from erp.contract_provisioning_report() f
             where f.finding = 'a contract in force has queued no subscription for its deployment' and f.detail = v_dc::text);
    perform erp.provision_entitlement_from_contract(v_dc);
    update erp_meta.deployment_push p set payload = jsonb_set(p.payload, '{plan_code}', '"enterprise"')
     where p.contract_id = v_dc and p.kind = 'subscription' and p.status = 'pending';
    v_n2 := (select count(*) from erp.contract_provisioning_report() f
              where f.finding = 'the subscription queued for the deployment disagrees with its contract' and f.reference = v_dcode);
    perform erp.provision_entitlement_from_contract(v_dc);
    v_cases := v_cases + 1;
    case_name := 'a deployment''s contract with no position queued, or with one that disagrees, is drift, and provisioning again mends it';
    passed := v_got like 'contracts: % in force%'
          and v_got2 like 'CLOVEERP_CONTRACT_DRIFT%'
          and v_n = 1 and v_n2 = 1
          and not exists (select 1 from erp.contract_provisioning_report() f where f.reference = v_dcode)
          and (select count(*) from erp_meta.deployment_push p
                where p.contract_id = v_dc and p.kind = 'subscription' and p.status = 'pending') = 1
          and exists (select 1 from erp_meta.deployment_push p
                       where p.contract_id = v_dc and p.kind = 'subscription' and p.status = 'superseded'
                         and p.payload ->> 'plan_code' = 'enterprise');
    detail := left(v_got, 60) || ' / ' || left(v_got2, 60) || format(' / %s missing, %s disagreeing', v_n, v_n2);
    return next;

    -- ── 9. An amendment supersedes the position still pending ──────────────
    v_step := 'signing an amendment';
    v_push := (select p.id from erp_meta.deployment_push p
                where p.contract_id = v_dc and p.kind = 'subscription' and p.status = 'pending');
    v_amend := erp.amend_contract(v_dc, 'More users from tomorrow', current_date + 1,
                                  '{"entitlements": [{"code": "users", "limit_value": 500}]}'::jsonb, 'growth at a second site');
    v_push2 := erp.sign_amendment(v_amend, 'D. Client, Finance Director', 'P. Owner, Clove Ltd', 'Agreement to amendment 1');
    v_json := (select p.payload from erp_meta.deployment_push p where p.id = v_push2);
    v_cases := v_cases + 1;
    case_name := 'a signed amendment queues the new position, dated rows and all, superseding the one still pending, and the deployment is told';
    passed := (select p.status from erp_meta.deployment_push p where p.id = v_push) = 'superseded'
          and (select p.status from erp_meta.deployment_push p where p.id = v_push2) = 'pending'
          and exists (select 1 from jsonb_array_elements(v_json -> 'entitlements') e
                       where e ->> 'code' = 'users' and (e ->> 'limit_value')::numeric = 500
                         and e ->> 'effective_from' = (current_date + 1)::text)
          and exists (select 1 from jsonb_array_elements(v_json -> 'entitlements') e
                       where e ->> 'code' = 'users' and (e ->> 'limit_value')::numeric = 250
                         and e ->> 'effective_to' = (current_date + 1)::text)
          and exists (select 1 from erp_meta.deployment_push p
                       where p.contract_id = v_dc and p.kind = 'notice' and p.payload ->> 'event_type' = 'commercial.contract_amended')
          and not exists (select 1 from erp.contract_provisioning_report() f where f.reference = v_dcode);
    detail := coalesce(v_json ->> 'entitlements', 'nothing queued');
    return next;

    -- ── 10. An invoice is issued to the deployment's administrator ─────────
    v_step := 'issuing the deployment''s invoice';
    v_inv := (select i.id from erp_meta.contract_invoice i where i.contract_id = v_dc order by i.period_start limit 1);
    v_json := erp.issue_contract_invoice(v_inv);
    v_cases := v_cases + 1;
    case_name := 'a deployment''s invoice is issued and sent to its first administrator, and the deployment is told';
    passed := (select i.status from erp_meta.contract_invoice i where i.id = v_inv) = 'issued'
          and (v_json ->> 'total_minor')::bigint = 1850000
          and exists (select 1 from erp_meta.commercial_email e
                       where e.contract_invoice_id = v_inv and e.kind = 'contract_invoice'
                         and e.to_address = v_owner_email and e.recipient_source = 'administrator'
                         and e.tenant_id is null and e.tenant_code = v_dcode)
          and exists (select 1 from erp_meta.deployment_push p
                       where p.contract_id = v_dc and p.kind = 'notice' and p.payload ->> 'event_type' = 'commercial.invoice_issued'
                         and p.payload -> 'payload' ->> 'invoice_id' = v_inv::text);
    detail := format('%s for %s, to %s', v_json ->> 'reference', v_json ->> 'total_minor',
                     coalesce((select string_agg(e.to_address || ' as ' || e.recipient_source, ', ')
                                 from erp_meta.commercial_email e where e.contract_invoice_id = v_inv), 'nobody'));
    return next;

    -- ── 11. The key-date sweep, beside an organisation's contract ──────────
    v_step := 'raising key dates beside an organisation''s contract';
    v_tc := erp.create_contract_from_quote(v_qt, v_ccode, 'Gamma Foods Ltd', 'Clove Ltd', current_date);
    perform erp.sign_contract(v_tc, 'G. Customer, Finance Director', 'P. Owner, Clove Ltd',
                              'Agreement to the order form and the terms it names');
    update erp_meta.contract set notice_days = 355 where id in (v_dc, v_tc);   -- deadline in ten days
    v_n := erp.raise_contract_key_dates();
    v_n2 := erp.raise_contract_key_dates();
    v_cases := v_cases + 1;
    case_name := 'the key-date sweep tells the organisation by an event and the deployment by a notice, once, and stops for neither';
    passed := v_n >= 2 and v_n2 = 0
          and exists (select 1 from erp.event e where e.tenant_id = v_customer and e.event_type = 'commercial.notice_deadline_announced')
          and exists (select 1 from erp_meta.contract_notice n where n.contract_id = v_tc and n.kind = 'notice_deadline' and n.event_id is not null)
          and exists (select 1 from erp_meta.contract_notice n where n.contract_id = v_dc and n.kind = 'notice_deadline' and n.event_id is null)
          and (select count(*) from erp_meta.deployment_push p
                where p.contract_id = v_dc and p.kind = 'notice'
                  and p.payload ->> 'event_type' = 'commercial.notice_deadline_announced') = 1;
    detail := format('%s raised, then %s', v_n, v_n2);
    return next;

    -- ── 12. A renewal ───────────────────────────────────────────────────────
    v_step := 'renewing the deployment''s contract';
    perform set_config('request.jwt.claims', '', true);
    perform erp.propose_renewals();
    v_renewal := (select r.id from erp_meta.renewal r where r.contract_id = v_dc and r.status = 'proposed');
    perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
    v_qr := erp.open_renewal_quote(v_renewal);
    perform erp.submit_quote(v_qr);
    perform erp.issue_quote(v_qr);
    perform erp.quote_transition(v_qr, 'accept', 'renewal signed');
    perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
    v_n := (select count(*) from erp_meta.contract_invoice i where i.contract_id = v_dc);
    perform erp.renew_contract(v_renewal, 'D. Client, Finance Director', 'P. Owner, Clove Ltd', 'Agreement to renew');
    v_json := (select p.payload from erp_meta.deployment_push p
                where p.contract_id = v_dc and p.kind = 'subscription' and p.status = 'pending');
    v_cases := v_cases + 1;
    case_name := 'a renewal extends the deployment''s term, queues the renewed position, schedules the next term''s invoices, and tells it';
    passed := (select c.current_term_end from erp_meta.contract c where c.id = v_dc) = (current_date + interval '24 months')::date
          and v_json ->> 'term_end' = ((current_date + interval '24 months')::date)::text
          and (select count(*) from erp_meta.contract_invoice i where i.contract_id = v_dc and i.tenant_id is null) = v_n + 1
          and exists (select 1 from erp_meta.deployment_push p
                       where p.contract_id = v_dc and p.kind = 'notice' and p.payload ->> 'event_type' = 'commercial.contract_renewed')
          and not exists (select 1 from erp.contract_provisioning_report() f where f.reference = v_dcode);
    detail := format('term to %s; %s invoice(s) before, %s after', v_json ->> 'term_end', v_n,
                     (select count(*) from erp_meta.contract_invoice i where i.contract_id = v_dc));
    return next;

    -- ── 13. A non-renewal ───────────────────────────────────────────────────
    v_step := 'declining the next renewal';
    insert into erp_meta.renewal (contract_id, term_start, term_end, uplift_rule, uplift_pct,
                                  previous_annual_value_minor, proposed_annual_value_minor, currency)
    select c.id, c.current_term_end, (c.current_term_end + interval '12 months')::date, c.uplift_rule, 0,
           c.annual_value_minor, c.annual_value_minor, c.currency
      from erp_meta.contract c where c.id = v_dc
    returning id into v_renewal;
    perform erp.decline_renewal(v_renewal, 'The client moves to another provider when this term ends.');
    v_json := (select p.payload from erp_meta.deployment_push p
                where p.contract_id = v_dc and p.kind = 'subscription' and p.status = 'pending');
    v_cases := v_cases + 1;
    case_name := 'a non-renewal queues a position that no longer renews, and tells the deployment';
    passed := (select c.status from erp_meta.contract c where c.id = v_dc) = 'terminating'
          and not (v_json ->> 'renews')::boolean
          and v_json ->> 'contract_status' = 'terminating' and v_json ->> 'status' = 'active'
          and exists (select 1 from erp_meta.deployment_push p
                       where p.contract_id = v_dc and p.kind = 'notice' and p.payload ->> 'event_type' = 'commercial.non_renewal_recorded')
          and not exists (select 1 from erp.contract_provisioning_report() f where f.reference = v_dcode);
    detail := format('renews %s, %s', v_json ->> 'renews', v_json ->> 'contract_status');
    return next;

    -- ── 14. The end of a term, beside an organisation's ────────────────────
    v_step := 'ending both terms';
    perform set_config('request.jwt.claims', '', true);
    update erp_meta.contract set current_term_start = current_date - 366, current_term_end = current_date - 1 where id in (v_dc, v_tc);
    v_n := erp.expire_contracts();
    v_json := (select p.payload from erp_meta.deployment_push p
                where p.contract_id = v_dc and p.kind = 'subscription' and p.status = 'pending');
    v_cases := v_cases + 1;
    case_name := 'the end of a term moves the organisation to grace by its subscription and the deployment by a queued position, and the sweep stops for neither';
    passed := v_n >= 2
          and (select c.status from erp_meta.contract c where c.id = v_dc) = 'expired'
          and (select c.status from erp_meta.contract c where c.id = v_tc) = 'expired'
          and (select s.status from erp_meta.subscription s where s.tenant_id = v_customer) = 'grace'
          and exists (select 1 from erp.event e where e.tenant_id = v_customer and e.event_type = 'commercial.term_ended')
          and v_json ->> 'status' = 'grace' and not (v_json ->> 'renews')::boolean
          and v_json ->> 'contract_status' = 'expired'
          and exists (select 1 from erp_meta.deployment_push p
                       where p.contract_id = v_dc and p.kind = 'notice' and p.payload ->> 'event_type' = 'commercial.term_ended');
    detail := format('%s expired; the deployment is owed %s, renewing %s', v_n, v_json ->> 'status', v_json ->> 'renews');
    return next;

    -- ── 15. Only on the control plane ──────────────────────────────────────
    v_step := 'making a contract on a client deployment';
    perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
    delete from erp_meta.platform_setting where key = 'deployment.kind';
    insert into erp_meta.platform_setting (key, value, reason)
    values ('deployment.kind', '"client"'::jsonb, 'contract_names_a_deployment_suite');
    begin
      perform erp.create_contract_from_quote(v_qd, v_dcode, 'Delta Client Ltd', 'Clove Ltd', current_date);
      v_got := 'a contract was made';
    exception when others then
      v_got := sqlerrm;
    end;
    delete from erp_meta.platform_setting where key = 'deployment.kind';
    insert into erp_meta.platform_setting (key, value, reason)
    values ('deployment.kind', '"production"'::jsonb, 'contract_names_a_deployment_suite');
    v_cases := v_cases + 1;
    case_name := 'a contract names a client deployment on the control plane alone';
    passed := v_got like 'CLOVEERP_NOT_THE_CONTROL_PLANE%';
    detail := left(v_got, 140);
    return next;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('erp.job_tenant_id', '', true);
  perform set_config('request.jwt.claims', '', true);

  -- ── 16. Undone ─────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the suite leaves nothing behind: no deployment, contract, queued row or marker of its own';
  passed := not exists (select 1 from erp_meta.deployment d where d.code in (v_dcode, v_gone))
        and not exists (select 1 from erp_meta.contract c where c.tenant_code in (v_dcode, v_ccode))
        and not exists (select 1 from erp_meta.deployment_push p where p.code in (v_dcode, v_gone))
        and not exists (select 1 from erp.tenant t where t.code in (v_pcode, v_ccode))
        and erp.deployment_kind() = v_kind;
  detail := format('deployment kind %s, as before', erp.deployment_kind());
  return next;

  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_CONTRACT_NAMES_A_DEPLOYMENT_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.contract_names_a_deployment_suite() from public, anon;

create or replace function erp_test.assert_contract_names_a_deployment_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)), count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.contract_names_a_deployment_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_CONTRACT_NAMES_A_DEPLOYMENT_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A contract with a client deployment misbehaves: read the case that failed.';
  end if;
  if v_total <> 16 then
    raise exception 'CLOVEERP_CONTRACT_NAMES_A_DEPLOYMENT_SUITE_SHRANK: % case(s), expected 16', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('contract names a deployment: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_contract_names_a_deployment_suite() from public, anon;

comment on function erp_test.assert_contract_names_a_deployment_suite() is
  'A contract may name a client deployment, on the control plane alone and not a retired one: signing, amending, '
  'renewing, not renewing and the end of the term queue its position for the deployment instead of writing a '
  'subscription here; its invoices are scheduled at signing and go to its first administrator; drift is caught; '
  'the sweeps stop for neither model (20261011090000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- The generators, which are idempotent and run at the end of every migration.
-- ─────────────────────────────────────────────────────────────────────────────

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
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
select erp.assert_personal_data_register_sound();
