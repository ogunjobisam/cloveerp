-- =============================================================================
-- Part 18 — the adversarial suite
--
-- Part 18 makes four promises that are only worth anything if they hold against
-- an attack rather than in a diagram:
--
--   §18.1  an organisation cannot exceed its plan BY CALLING A FUNCTION
--          DIRECTLY. So the suite calls the function directly.
--   §18.1  exceeding produces a NAMED refusal and a notification. So the suite
--          checks the error code and that the event was raised.
--   §18.3  restricted refuses writes and RETAINS reads and export. So the suite
--          proves both halves — a gate that refused everything would pass a test
--          that only checked the refusal.
--   §18.2  a purge does not destroy the billing record. So the suite purges an
--          organisation and reads its meter afterwards.
--
-- The last is the one that cannot be established by reading the schema: a
-- foreign key added later would cascade the billing record away, and every
-- structural check would still pass. It is asserted here by actually deleting
-- the organisation.
-- =============================================================================

create or replace function erp_test.commercial_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  r record;
  ow uuid := gen_random_uuid();
  v_ok boolean; v_msg text; v_tenant uuid; v_code text := 'zzcomm-a';
  v_meter numeric; v_sub integer; v_before numeric;
begin
  select * into r from erp.provision_tenant(
    v_code, 'Commercial A', 'admin-a@zzcomm.test', 'Commercial A Admin');
  v_tenant := r.tenant_id;

  insert into auth.users (id, email) values (ow, 'owner@zzcomm.test');
  insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
  values ('owner@zzcomm.test', ow, 'Commercial Owner', 'owner');

  perform set_config('erp.job_tenant_id', v_tenant::text, true);

  -- ── §18.1 no subscription means unmetered ─────────────────────────────────

  return query select 'an organisation with no subscription is unlimited',
    erp.entitlement_limit('users', v_tenant) is null,
    'Part 18 must not change what organisations provisioned before it may do';

  -- ── §18.1 the plan, and the refusal ───────────────────────────────────────

  insert into erp_meta.subscription
    (tenant_id, tenant_code, plan_code, term_start, currency)
  values (v_tenant, v_code, 'starter', current_date, 'GBP');

  return query select 'a plan in force sets a limit',
    erp.entitlement_limit('companies', v_tenant) = 1,
    format('starter allows %s company', erp.entitlement_limit('companies', v_tenant));

  -- provision_tenant created one entity, so the organisation is already at its
  -- Starter limit of one company.
  return query select 'usage is counted from the objects themselves',
    erp.entitlement_usage('companies', v_tenant) = 1,
    'not from a counter somebody has to remember to increment';

  begin
    perform erp.require_entitlement('companies', 1);
    v_ok := false; v_msg := 'a second company was permitted on a one-company plan';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_ENTITLEMENT_EXCEEDED%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'exceeding the plan is refused by a NAMED error', v_ok, v_msg;

  -- §18.1 asks for a notification as well as a refusal, and the refusal cannot
  -- carry it: RAISE aborts the transaction, taking any event written alongside
  -- it. An earlier version of this suite asserted the event here and failed,
  -- which is how that was found. The notification is a sweep, and this is where
  -- it is proven.
  return query select 'the refusal alone raises no event, because it aborts its own transaction',
    not exists (select 1 from erp.event e
                 where e.tenant_id = v_tenant
                   and e.event_type = 'commercial.entitlement_exceeded'),
    'an event rolled back by the refusal that produced it is not a notification';

  -- Being AT a limit is not a breach, so the refusal above leaves nothing for
  -- the sweep to find — it worked. What the sweep exists for is the case no
  -- refusal can ever see: an organisation already over a limit because its plan
  -- was lowered beneath its usage. A second company, written directly the way
  -- pre-existing data is, puts it there.
  insert into erp.entity (tenant_id, code, name, legal_name,
                          base_currency, country_code, status)
  values (v_tenant, 'SECOND', 'Second company', 'Second company',
          'GBP', 'GB', 'active');

  return query select 'a plan lowered beneath existing usage leaves an organisation over it',
    erp.entitlement_usage('companies', v_tenant)
      > erp.entitlement_limit('companies', v_tenant),
    'two companies against a plan that allows one, and nothing is being attempted';

  perform erp.report_entitlement_breaches();

  -- The sweep clears the tenant context when it finishes, which is right for
  -- something that walks every organisation in turn: leaving the last one set
  -- would hand it to whatever ran next. The caller re-establishes its own.
  perform set_config('erp.job_tenant_id', v_tenant::text, true);

  return query select 'the sweep raises it instead, in a transaction that commits',
    exists (select 1 from erp.event e
             where e.tenant_id = v_tenant
               and e.event_type = 'commercial.entitlement_exceeded'),
    '§18.1: never a silent degradation and never a surprise invoice';

  -- Not "is null": erp.require_entitlement returns void, and comparing void to
  -- null asserts nothing. What is being tested is that it does not raise.
  begin
    perform erp.require_entitlement('users', 1);
    v_ok := true; v_msg := 'permitted';
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 80);
  end;
  return query select 'while a limit not yet reached is permitted', v_ok,
    v_msg || ' — starter allows ten users and the organisation has one';

  -- ── §18.1 capabilities are entitlement too ────────────────────────────────

  begin
    perform erp.set_capability('batch_expiry', true, 'suite');
    v_ok := false; v_msg := 'a capability off the plan was switched on';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_CAPABILITY_NOT_ON_PLAN%'
         or sqlerrm like 'ERPWARE_UNKNOWN_CAPABILITY%';
    v_msg := left(sqlerrm, 80);
  end;
  return query select 'a capability the plan does not carry is refused', v_ok, v_msg;

  -- ── §18.2 the meter ───────────────────────────────────────────────────────

  perform erp.record_meter('documents_posted', 5, v_tenant);
  perform erp.record_meter('documents_posted', 3, v_tenant);

  select coalesce(sum(m.quantity), 0) into v_meter
    from erp_meta.usage_meter m
   where m.tenant_id = v_tenant and m.meter_code = 'documents_posted';

  return query select 'a meter accumulates within its period',
    v_meter = 8, format('5 then 3 gives %s', v_meter);

  return query select 'and the organisation can read its own meters',
    exists (select 1 from erp.entitlement_report(v_tenant) er
             where er.entitlement_code = 'documents_per_month' and er.used = 8),
    '§18.2: the number on an invoice is one the customer has already seen';

  -- ── §18.3 restricted refuses writes and keeps reads ───────────────────────

  perform set_config('request.jwt.claims',
                     json_build_object('sub', ow)::text, true);
  perform erp.claim_invitation(r.admin_token);

  update erp.tenant set status = 'restricted' where id = v_tenant;

  begin
    perform erp.authorise('master_data.write');
    v_ok := false; v_msg := 'a write was permitted on a restricted organisation';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_ORGANISATION_RESTRICTED%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'restricted refuses a write', v_ok, v_msg;

  begin
    perform erp.authorise('master_data.read');
    v_ok := true; v_msg := 'reads retained';
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 80);
  end;
  return query select 'and RETAINS the read, because withholding data is not a collection method',
    v_ok, v_msg;

  update erp.tenant set status = 'suspended' where id = v_tenant;

  begin
    perform erp.authorise('master_data.read');
    v_ok := false; v_msg := 'a read was permitted on a suspended organisation';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_ORGANISATION_SUSPENDED%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'suspended withdraws access entirely', v_ok, v_msg;

  update erp.tenant set status = 'active' where id = v_tenant;

  begin
    perform erp.authorise('master_data.read');
    v_ok := true; v_msg := 'restored';
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 80);
  end;
  return query select 'and restoration is immediate on resolution', v_ok, v_msg;

  -- ── §18.2 the billing record outlives the organisation ────────────────────
  --
  -- The case that cannot be established by reading the schema. A foreign key
  -- added to erp_meta.usage_meter later would cascade the row away here, and
  -- every structural assertion would still pass.

  select coalesce(sum(m.quantity), 0) into v_before
    from erp_meta.usage_meter m where m.tenant_id = v_tenant;

  perform set_config('request.jwt.claims', '', true);
  update erp.tenant set status = 'suspended' where id = v_tenant;
  perform erp.begin_tenant_purge(v_tenant);
  delete from erp.tenant where id = v_tenant;
  perform erp.end_tenant_purge();

  return query select 'the organisation is gone',
    not exists (select 1 from erp.tenant t where t.id = v_tenant),
    'purged, and everything tenant-scoped with it';

  select coalesce(sum(m.quantity), 0) into v_meter
    from erp_meta.usage_meter m where m.tenant_id = v_tenant;

  return query select 'and the METER survived it',
    v_meter = v_before and v_meter > 0,
    format('%s before the purge, %s after — §18.2 requires the billing record to '
           'be retained independently of operational data', v_before, v_meter);

  select count(*) into v_sub from erp_meta.subscription s where s.tenant_id = v_tenant;
  return query select 'as did the subscription',
    v_sub = 1,
    'a billing record that vanished with the customer who owed on it would be no '
    'billing record at all';

  return query select 'and it still names the organisation readably',
    exists (select 1 from erp_meta.usage_meter m
             where m.tenant_id = v_tenant and m.tenant_code = v_code),
    'after the purge the id resolves to nothing, so the code is the only identity left';

  -- ── Clean up ──────────────────────────────────────────────────────────────

  delete from erp_meta.usage_meter where tenant_id = v_tenant;
  delete from erp_meta.subscription where tenant_id = v_tenant;
  delete from erp_meta.platform_staff where email like '%@zzcomm.test';
  delete from erp_meta.platform_audit where tenant_code like 'zzcomm-%';
  delete from auth.users where id = ow;

  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.code like 'zzcomm-%')
      and not exists (select 1 from erp_meta.usage_meter m where m.tenant_code like 'zzcomm-%')
      and not exists (select 1 from auth.users u where u.id = ow),
    'including the commercial rows, which nothing else would have removed';
end;
$$;

comment on function erp_test.commercial_suite is
  'Specification v1.2 Part 18, proven adversarially: the plan is exceeded by '
  'calling the function directly, restriction is tested on both the write it '
  'refuses and the read it keeps, and the billing record is read back after the '
  'organisation has been purged.';

create or replace function erp_test.assert_commercial_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _commercial_result on commit drop as
    select * from erp_test.commercial_suite();

  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not passed)
    into v_total, v_passed, v_detail
    from _commercial_result;

  -- The case count is asserted, so a case that disappears fails the build
  -- instead of passing quietly.
  if v_total <> 20 then
    raise exception
      'ERPWARE_COMMERCIAL_SUITE_SHRANK: % case(s), expected 20', v_total
      using errcode = 'P0001',
            hint = 'A suite that reports n/n without saying what n should be '
                   'cannot notice a test that stopped running.';
  end if;

  if v_passed <> v_total then
    raise exception 'ERPWARE_COMMERCIAL_SUITE_FAILED: %/%', v_passed, v_total
      using errcode = 'P0001', detail = v_detail;
  end if;

  return format('commercial: %s/%s', v_passed, v_total);
end;
$$;

select erp_test.assert_commercial_suite();
