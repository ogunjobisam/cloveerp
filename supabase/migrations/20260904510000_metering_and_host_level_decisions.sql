-- =============================================================================
-- Carry-overs: the meters are recorded, and two host-level statements are
-- recorded as decisions.
--
-- Specification v1.2 §18.2 says usage is measured from what the platform
-- already produces. Part 18 built the register (erp_meta.meter_kind: four
-- meters, each naming what it is measured from), the store
-- (erp_meta.usage_meter), the writer (erp.record_meter()) and the reader
-- (erp.entitlement_usage()). What it did not do is call the writer: the only
-- function that recorded a meter was the commercial suite. So the two limits
-- that read the meters — documents per month, movements per month — were
-- limits nothing could ever reach, and a plan stating them was stating prose.
--
-- This migration wires each meter into the transaction path its own row names:
--
--   documents_posted    erp.transition_document(), the moment a document first
--                       reaches a committed state
--   movements_recorded  a statement trigger on erp.stock_movement, so every one
--                       of the twelve writers is counted without editing twelve
--                       writers
--   messages_sent       erp.complete_outbox(), the moment a consumer confirms
--                       delivery
--   active_users        erp.measure_active_users(), a scheduled sweep, because
--                       "distinct actors in the period" is a measure of the
--                       period rather than an event in it
--
-- And, in the house pattern, it asserts the wiring: erp.meter_coverage_report()
-- finds, for every meter kind, the function that records it, and
-- erp.assert_meters_recorded() fails the build when one has none. A meter the
-- register describes and nothing records is exactly the kind of green that
-- erp.entitlement_enforcement_report() was written to refuse.
--
-- Two carry-overs from the specification audit are recorded rather than built:
-- physical isolation per tenant (§2.1) and region pinning (§2.5) are host-level
-- properties of where a database runs, enforced by the platform that runs it,
-- not by SQL inside it. They go into erp_meta.policy_decision with the evidence
-- of where they are enforced, so the audit shows a decision, not a gap.
-- =============================================================================

-- ── documents_posted: the first committed state ──────────────────────────────
--
-- Re-emitted from 20260903 with one addition. A sales order passes through
-- three committed states; the meter counts a document once, when it first
-- becomes something the outside world believes, which is why the state before
-- the transition is read as well as the state after.

create or replace function erp.transition_document(p_document_id uuid, p_transition_code text, p_reason text default null::text)
returns text
language plpgsql
set search_path = ''
as $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  dt       erp.document_type%rowtype;
  bt       erp_ref.document_type%rowtype;
  v_ctx    jsonb;
  v_to     text;
  v_committed boolean;
  v_was_committed boolean;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503';
  end if;

  select * into dt from erp.document_type where tenant_id = v_tenant and id = d.document_type_id;
  select * into bt from erp_ref.document_type where code = dt.base_type_code;

  -- The context the guards are evaluated against, from the one function that
  -- knows how to build it. It was assembled here and nowhere else, which meant
  -- erp.available_transitions() — the function a screen asks "what may I do
  -- next?" — could only be called with '{}', and reported every value-banded
  -- transition as blocked. The menu and the enforcement now read one
  -- definition.
  v_ctx := erp.document_transition_context(p_document_id, p_transition_code);

  if p_transition_code = 'submit' and dt.approval_chain_code is not null then
    perform erp.request_approval('document', p_document_id, v_ctx, 1,
                                 d.entity_id, d.site_id);
  end if;

  -- §18.2: what the document was before it moved, so the meter counts the
  -- first commitment and not every committed state after it.
  select s.is_committed into v_was_committed
    from erp.object_state os
    join erp.state s on s.id = os.current_state_id
   where os.tenant_id = v_tenant and os.object_type = 'document'
     and os.object_id = p_document_id;

  v_to := erp.perform_transition('document', p_document_id, p_transition_code,
                                 v_ctx, p_reason);

  select s.is_committed into v_committed
    from erp.object_state os
    join erp.state s on s.id = os.current_state_id
   where os.tenant_id = v_tenant and os.object_type = 'document'
     and os.object_id = p_document_id;

  -- Committed means the outside world now believes this, and both ledgers have
  -- to agree at that moment.
  --
  -- Each half is asked separately, because a sales order passes through three
  -- committed states and only the first of them should raise anything. Asking
  -- "has this already posted?" of each ledger is what makes the second and
  -- third transitions quiet instead of a duplicate-posting error.
  if coalesce(v_committed, false) then
    if not coalesce(v_was_committed, false) then
      perform erp.record_meter('documents_posted', 1, v_tenant);
    end if;

    if bt.affects_stock
       and not exists (select 1 from erp.stock_movement m
                        where m.tenant_id = v_tenant and m.document_id = p_document_id)
    then
      perform erp.post_document_stock(p_document_id);
    end if;

    if bt.affects_finance
       and not exists (select 1 from erp.journal j
                        where j.tenant_id = v_tenant and j.document_id = p_document_id)
    then
      perform erp.post_document_finance(p_document_id);
    end if;
  end if;

  return v_to;
end;
$function$;

-- ── movements_recorded: one trigger, twelve writers ──────────────────────────
--
-- Twelve functions insert into erp.stock_movement (receipts, issues, counts,
-- transfers, splits, merges, write-offs, reversals, opening balances, works
-- order issue and output, warehouse tasks). Counting at the table counts all of
-- them and the thirteenth. A statement trigger with a transition table records
-- once per statement rather than once per row, grouped by organisation because
-- a trusted sweep may write for several.

create or replace function erp.meter_stock_movements()
returns trigger
language plpgsql
set search_path = ''
as $$
declare r record;
begin
  for r in select i.tenant_id, count(*) as n from inserted i group by i.tenant_id loop
    perform erp.record_meter('movements_recorded', r.n, r.tenant_id);
  end loop;
  return null;
end;
$$;

comment on function erp.meter_stock_movements is
  'Specification v1.2 §18.2. Records the movements_recorded meter for every '
  'row that reaches erp.stock_movement, whichever of the twelve writers put it '
  'there. Statement-level, so one receipt of forty lines is one write to the '
  'meter, not forty.';

drop trigger if exists t_stock_movement_meter on erp.stock_movement;
create trigger t_stock_movement_meter
  after insert on erp.stock_movement
  referencing new table as inserted
  for each statement execute function erp.meter_stock_movements();

-- ── messages_sent: delivery confirmed ────────────────────────────────────────
--
-- Re-emitted from 20260830 with the meter. A message is sent when the consumer
-- says so, not when it was queued: a queued message that fails every attempt
-- was never sent, and the meter should not say it was.

create or replace function erp.complete_outbox(p_outbox_id bigint)
returns void
language sql
set search_path = ''
as $function$
  update erp.event_outbox
     set status = 'published', published_at = now(), locked_at = null,
         locked_by = null, last_error = null
   where id = p_outbox_id
     and tenant_id = erp.require_tenant_id();
  select erp.record_meter('messages_sent', 1, erp.require_tenant_id());
$function$;

-- ── active_users: a measure of the period, taken on a schedule ───────────────
--
-- The register says active users are "distinct actors on erp.audit_entry
-- within the period". That is not an event a transaction can count as it
-- happens — the second action by the same person is not a second user — so it
-- is measured: the sweep counts the distinct actors so far this month, reads
-- what the meter already says, and records the difference. Run twice in a
-- day it changes nothing; run once a month it is exactly right.

create or replace function erp.measure_active_users()
returns table(tenant_code text, active_users numeric)
language plpgsql
set search_path = ''
as $$
declare
  r record;
  v_from date := date_trunc('month', current_date)::date;
  v_to   date := (date_trunc('month', current_date) + interval '1 month - 1 day')::date;
  v_now numeric; v_recorded numeric;
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
    select count(distinct a.actor_id) into v_now
      from erp.audit_entry a
     where a.tenant_id = r.id and a.actor_id is not null
       and a.recorded_at >= v_from and a.recorded_at < v_to + 1;

    select coalesce(sum(m.quantity), 0) into v_recorded
      from erp_meta.usage_meter m
     where m.tenant_id = r.id and m.meter_code = 'active_users'
       and m.period_start = v_from and m.period_end = v_to;

    if v_now > v_recorded then
      perform erp.record_meter('active_users', v_now - v_recorded, r.id, v_from, v_to);
    end if;

    tenant_code := r.code; active_users := v_now;
    return next;
  end loop;
end;
$$;

comment on function erp.measure_active_users is
  'Specification v1.2 §18.2. The scheduled measure behind the active_users '
  'meter: distinct actors on the audit stream this month, per organisation, '
  'recorded as the difference from what the meter already holds so the sweep '
  'is idempotent within a period.';

insert into erp_ref.job_handler
  (code, name_key, description, module_code, parameter_schema,
   default_timeout_seconds, forbids_overlap, is_current, sql_function)
values
  ('commercial.measure_active_users',
   'job_handler.measure_active_users.name',
   'Measures the active_users meter for every organisation: distinct actors on the audit stream this month. §18.2 requires usage measured from what the platform already produces, and this is the one meter that is a measure of a period rather than a count of events in it.',
   null, '{"type": "object", "additionalProperties": false}'::jsonb,
   300, true, true, 'measure_active_users')
on conflict (code) do update set
  description = excluded.description, sql_function = excluded.sql_function,
  is_current = excluded.is_current;

insert into erp_ref.resource (key, locale, value, description) values
('job_handler.measure_active_users.name', 'en',
 'Measure active users',
 'The scheduled sweep behind the active_users meter. Named here because a job whose name does not resolve is a blank row on the operations screen.')
on conflict (key, locale) do update set
  value = excluded.value, description = excluded.description;

-- ── The assertion: every meter is recorded by something ──────────────────────

create or replace function erp.meter_coverage_report()
returns table(meter_code text, finding text, detail text)
language sql
stable
set search_path = ''
as $$
  with recorder as (
    -- A function in the product schema whose body records this meter. The
    -- suites are excluded: a meter only a test records is a meter nothing
    -- records.
    select m.code,
           string_agg(n.nspname || '.' || p.proname, ', ' order by p.proname) as recorded_by,
           bool_or(p.prorettype = 'pg_catalog.trigger'::regtype
                   and not exists (select 1 from pg_catalog.pg_trigger t
                                    where t.tgfoid = p.oid and not t.tgisinternal)) as trigger_unbound
      from erp_meta.meter_kind m
      left join pg_catalog.pg_proc p
        on p.prosrc like '%record_meter(''' || m.code || '''%'
       and p.proname <> 'record_meter'
      left join pg_catalog.pg_namespace n on n.oid = p.pronamespace and n.nspname = 'erp'
     where n.nspname is not null or p.oid is null
     group by m.code)
  select r.code, 'no transaction path records this meter',
         'erp_meta.meter_kind says it is measured from something; nothing calls erp.record_meter for it'
    from recorder r where r.recorded_by is null
  union all
  select r.code, 'the recorder is a trigger function no trigger fires', r.recorded_by
    from recorder r where r.trigger_unbound
$$;

create or replace function erp.assert_meters_recorded()
returns text
language plpgsql
set search_path = ''
as $$
declare v_count integer; v_detail text; v_kinds integer;
begin
  select count(*), string_agg(format('  %s — %s: %s', meter_code, finding, detail), E'\n')
    into v_count, v_detail
    from erp.meter_coverage_report();
  if v_count > 0 then
    raise exception 'ERPWARE_METER_UNRECORDED: % finding(s)', v_count
      using errcode = 'P0001', detail = v_detail,
            hint = '§18.2 requires usage measured from what the platform produces. '
                   'A meter nothing records is a limit nothing can reach.';
  end if;
  select count(*) into v_kinds from erp_meta.meter_kind;
  return format('meters: %s kind(s), each recorded by a transaction path', v_kinds);
end;
$$;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('meter_coverage', 'Every meter is recorded', 'assertion', 'platform',
   'erp', 'assert_meters_recorded', '', 'meter_coverage_report', '',
   'Every usage meter the commercial register describes is recorded by a function in the transaction path it names, so a plan limit that reads a meter is a limit that can be reached.',
   true, 67)
on conflict (code) do update set
  title = excluded.title, blurb = excluded.blurb, function_name = excluded.function_name,
  detail_function = excluded.detail_function, seq = excluded.seq;

-- ── Two host-level statements, recorded as decisions ─────────────────────────

insert into erp_meta.policy_decision
  (code, title, spec_reference, decision, rationale, status, evidence)
values
  ('physical_isolation_is_host_level',
   'Physical isolation per organisation is a property of where the database runs',
   'v1.2 §2.1',
   'The product ships logical isolation: one schema, tenant-scoped rows, row-level security on every table, asserted on every build. Physical isolation (a dedicated schema or database for one organisation) is provided by running a second instance of the same migrations for that organisation, and nothing in the product changes to do it.',
   '§2.1 says the application code is identical in both cases. That is only true if the product carries no switch for it: a "physical" mode inside the schema would be a second code path, tested less than the first, and the isolation it promised would rest on that path being right. A separate instance is isolated by construction. The decision is therefore that isolation beyond RLS is a deployment choice made by the host, and the product''s contribution is that its migrations build the same database from empty every time (§16), which is what makes a second instance cheap.',
   'accepted',
   'erp.assert_isolation() and erp_test.isolation_suite() prove the logical isolation on every build; supabase/ci/00_host_bootstrap.sql is the host contract a second instance is built from; .github/workflows/schema.yml builds the whole product from an empty database, which is the demonstration that a dedicated instance is one command away.'),
  ('region_pinning_is_host_level',
   'Data residency is decided by where the database is created, not by a column',
   'v1.2 §2.5',
   'An organisation''s data is pinned to a region by creating its database in that region. The product does not record a region per organisation and does not route by one: every row of an organisation lives in one database, so the database''s region is the organisation''s region.',
   'A region column would be a statement the product cannot enforce — SQL cannot keep a row on one continent — and a statement nothing enforces is the kind §10 refuses. Residency is enforced by the host''s placement of the instance and, for an organisation that needs a different region from the shared instance, by the physical-isolation decision above. The two decisions are one mechanism.',
   'accepted',
   'Supabase projects are created in a region and stay there; the shared instance''s region is a property of the project, visible on its dashboard. An organisation requiring another region is provisioned on its own instance in that region from the same migrations.')
on conflict (code) do update set
  title = excluded.title, spec_reference = excluded.spec_reference,
  decision = excluded.decision, rationale = excluded.rationale,
  status = excluded.status, evidence = excluded.evidence;

-- ── The suite ─────────────────────────────────────────────────────────────────

create or replace function erp_test.metering_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  r record;
  a1 uuid := gen_random_uuid();
  a2 uuid := gen_random_uuid();
  csf uuid; csp uuid; csi uuid;
  v_second uuid; v_tok text; res jsonb;
  v_uom uuid; v_site uuid; v_recv uuid; v_sup uuid; v_item uuid;
  v_req uuid; v_grn uuid; v_outbox bigint;
  v_ok boolean; v_msg text; v_n numeric; v_docs bigint; v_moves bigint;
begin
  select * into r from erp.provision_tenant(
    'zzmeter', 'Metering', 'admin@zzmeter.test', 'Metering Admin');
  insert into auth.users (id, email) values (a1, 'admin@zzmeter.test'), (a2, 'second@zzmeter.test');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);
  res := public.erp_invite_principal('second@zzmeter.test', 'Second Admin');
  v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
  perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');

  -- A consumer, so events reach the outbox and a message can be sent.
  perform erp_test.reopen_bootstrap_window(r.tenant_id);
  insert into erp.event_subscription (tenant_id, consumer_code, event_pattern, description, max_attempts, status)
  values (r.tenant_id, 'meter-test', '%', 'Everything, for the suite', 3, 'active');
  perform erp_test.close_bootstrap_window(r.tenant_id);

  csf := erp.configure_finance();
  csp := erp.configure_procurement(100000000);
  csi := erp.configure_inventory('average');
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(v_tok);
  perform erp.approve_change_set(csf); perform erp.promote_change_set(csf);
  perform erp.approve_change_set(csp); perform erp.promote_change_set(csp);
  perform erp.approve_change_set(csi); perform erp.promote_change_set(csi);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
  values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
  insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
  values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'warehouse', 'active') returning id into v_site;
  insert into erp.location (tenant_id, site_id, code, name, location_type, status)
  values (r.tenant_id, v_site, 'RECV', 'Receiving', 'receiving', 'active') returning id into v_recv;
  insert into erp.party (tenant_id, code, name, status)
  values (r.tenant_id, 'SUP', 'Supplier', 'active') returning id into v_sup;
  insert into erp.item (tenant_id, code, name, stock_uom_id, status)
  values (r.tenant_id, 'WID', 'Widget', v_uom, 'active') returning id into v_item;

  -- ── The assertion ─────────────────────────────────────────────────────────

  begin
    v_msg := erp.assert_meters_recorded(); v_ok := true;
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 160);
  end;
  return query select 'every meter kind is recorded by a transaction path',
    v_ok and v_msg like 'meters: 4 kind(s)%', v_msg;

  return query select 'nothing is metered before anything happens',
    not exists (select 1 from erp_meta.usage_meter m where m.tenant_id = r.tenant_id),
    'no usage_meter rows for a fresh organisation';

  -- ── documents_posted ──────────────────────────────────────────────────────

  v_req := erp.open_document('requisition', v_sup);
  perform erp.add_document_line(v_req, v_item, 10, 50000, 'Ten widgets');
  return query select 'a draft is not a posted document',
    coalesce(erp.entitlement_usage('documents_per_month', r.tenant_id), 0) = 0,
    'drafting and adding lines meter nothing';

  perform erp.transition_document(v_req, 'submit');
  perform erp.transition_document(v_req, 'approve');
  perform erp.transition_document(v_req, 'order');

  v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
  perform erp.add_document_line(v_grn, v_item, 100, 1000, 'first receipt');
  perform erp.transition_document(v_grn, 'post');

  select count(*) into v_docs
    from erp.object_state os join erp.state s on s.id = os.current_state_id
   where os.tenant_id = r.tenant_id and os.object_type = 'document' and s.is_committed;
  v_n := coalesce(erp.entitlement_usage('documents_per_month', r.tenant_id), 0);
  return query select 'a document is metered once, when it first reaches a committed state',
    v_docs >= 1 and v_n = v_docs,
    format('%s committed document(s), meter says %s', v_docs, v_n);

  -- ── movements_recorded ────────────────────────────────────────────────────

  select count(*) into v_moves from erp.stock_movement m where m.tenant_id = r.tenant_id;
  v_n := coalesce(erp.entitlement_usage('movements_per_month', r.tenant_id), 0);
  return query select 'every stock movement is metered, whichever writer recorded it',
    v_moves >= 1 and v_n = v_moves,
    format('%s movement(s) in the ledger, meter says %s', v_moves, v_n);

  perform erp.write_off_stock(v_item, v_site, v_recv, 10, 'damaged in the aisle');
  select count(*) into v_moves from erp.stock_movement m where m.tenant_id = r.tenant_id;
  v_n := coalesce(erp.entitlement_usage('movements_per_month', r.tenant_id), 0);
  return query select 'and a second writer adds to the same meter',
    v_n = v_moves,
    format('%s movement(s) after a write-off, meter says %s', v_moves, v_n);

  -- ── messages_sent ─────────────────────────────────────────────────────────

  select o.id into v_outbox from erp.event_outbox o
   where o.tenant_id = r.tenant_id and o.consumer_code = 'meter-test' order by o.id limit 1;
  return query select 'a queued message is not a sent one',
    v_outbox is not null
    and not exists (select 1 from erp_meta.usage_meter m
                     where m.tenant_id = r.tenant_id and m.meter_code = 'messages_sent'),
    'outbox rows exist; messages_sent is unrecorded';

  perform erp.complete_outbox(v_outbox);
  return query select 'delivery confirmed is a message sent',
    (select sum(m.quantity) from erp_meta.usage_meter m
      where m.tenant_id = r.tenant_id and m.meter_code = 'messages_sent') = 1,
    'one completion, one message';

  -- ── active_users ──────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  v_n := (select u.active_users from erp.measure_active_users() u where u.tenant_code = 'zzmeter');
  return query select 'active users are measured from the audit stream, per organisation',
    v_n = 2
    and (select sum(m.quantity) from erp_meta.usage_meter m
          where m.tenant_id = r.tenant_id and m.meter_code = 'active_users') = 2,
    format('%s distinct actors this month: both administrators', v_n);

  perform erp.measure_active_users();
  return query select 'and measuring twice in a period changes nothing',
    (select sum(m.quantity) from erp_meta.usage_meter m
      where m.tenant_id = r.tenant_id and m.meter_code = 'active_users') = 2,
    'the sweep records the difference, not the count again';

  -- ── The decisions ─────────────────────────────────────────────────────────

  return query select 'physical isolation and region pinning are recorded as host-level decisions',
    (select count(*) from erp_meta.policy_decision d
      where d.code in ('physical_isolation_is_host_level', 'region_pinning_is_host_level')
        and d.status = 'accepted' and coalesce(d.evidence, '') <> '') = 2,
    'two accepted decisions, each with the evidence of where it is enforced';

  -- ── Clean up ──────────────────────────────────────────────────────────────

  set constraints all immediate;
  perform erp.begin_tenant_purge(r.tenant_id);
  delete from erp.tenant where id = r.tenant_id;
  perform erp.end_tenant_purge();
  -- Billing records outlive a purge by design (they carry the code for that
  -- reason); the suite's do not.
  delete from erp_meta.usage_meter where tenant_id = r.tenant_id;
  delete from auth.users where id in (a1, a2);
  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.id = r.tenant_id)
    and not exists (select 1 from erp_meta.usage_meter m where m.tenant_id = r.tenant_id),
    'organisation and its meters gone';
end;
$$;

create or replace function erp_test.assert_metering_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _metering_result on commit drop as
    select * from erp_test.metering_suite();

  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_total, v_passed, v_detail
    from _metering_result;

  if v_passed < v_total then
    raise exception E'ERPWARE_METERING_SUITE_FAILED: %/%\n%', v_passed, v_total, v_detail
      using errcode = 'P0001';
  end if;
  return format('metering: %s/%s', v_passed, v_total);
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
select erp.assert_product_decisions_enforced();
select erp.assert_job_handlers_resolvable();
select erp.assert_entitlements_enforceable();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
select erp.assert_meters_recorded();
select erp_test.assert_metering_suite();
