-- =============================================================================
-- The suite that did not clean up after itself
--
-- erp_test.bootstrap_window_suite() creates a tenant, takes it live, and then
-- leaves it there. Every one of the other fifteen suites ends the same three
-- lines: open a purge window, delete the tenant, close the window. This one
-- ended by clearing the JWT claims and stopping.
--
-- On CI that is invisible, which is exactly why it survived review: the
-- database is created empty, the suite is the only thing that ever ran, and
-- the whole cluster is discarded a minute later. The tick was green and the
-- artefact was wrong.
--
-- Two things follow from it, and only the second is serious.
--
--   1. The suite is single-use. A second run fails on tenant_code_key rather
--      than on anything it is testing, so the one place a developer would run
--      it twice — a local database they keep — is the one place it cannot run.
--      Confirmed by running it: two local databases both carry a leftover
--      zzboot tenant and both refuse the suite.
--
--   2. It writes to auth.users. That is the platform's own identity table, not
--      the product's, and this suite is the only thing in this repository that
--      has ever inserted into it. erp.app_user.auth_user_id is unique across
--      every tenant, so a fabricated subject left behind is a subject that can
--      never be onboarded for real. The tenant cascade does not reach these
--      rows, because there is no foreign key to cascade along.
--
-- The tenant here is the only suite tenant that is live when its purge runs,
-- so this is also the first exercise of a path B6 wrote and nothing used:
-- guard_live_configuration() refuses direct writes to a live tenant's
-- configuration and exempts one caller, the purge window opened below.
--
-- A twenty-second case asserts the cleanup, so the fix is tested rather than
-- merely made. It runs after the deletes and reads back what is gone.
--
-- This migration deliberately does NOT delete anything a previous run left
-- behind. A migration that removes a tenant by hard-coded code, on every
-- database it is ever applied to, is a worse thing than the defect it repairs.
-- A database that already carries the leftover — only ever a scratch one, since
-- nothing runs this suite outside CI — is recovered by hand, once:
--
--   select erp.begin_tenant_purge(id) from erp.tenant where code = 'zzboot';
--   delete from erp.tenant where code = 'zzboot';
--   select erp.end_tenant_purge();
--   delete from auth.users where email like '%@zzboot.test';
--
-- =============================================================================

create or replace function erp_test.bootstrap_window_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  a1 uuid := gen_random_uuid();
  a2 uuid := gen_random_uuid();
  v_onboard jsonb; v_tenant uuid; v_env uuid; v_second uuid; v_tok text;
  res jsonb; v_cs uuid; v_ok boolean; v_msg text; v_promo uuid;
  v_before integer;
begin
  -- ---------------------------------------------------------------------
  -- The self-service door
  -- ---------------------------------------------------------------------

  -- onboard_tenant() reads auth.uid() and then looks the subject up, because
  -- erp.app_user requires an email of every person. So the suite has to put one
  -- there: the self-service door starts at the platform's identity table, and a
  -- test that skipped it would be testing a different function.
  insert into auth.users (id, email) values (a1, 'solo@zzboot.test');
  insert into auth.users (id, email) values (a2, 'second@zzboot.test');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  v_onboard := erp.onboard_tenant('Bootstrap Window', 'zzboot');
  v_tenant := (v_onboard ->> 'tenant_id')::uuid;
  v_env    := (v_onboard ->> 'environment_id')::uuid;

  return query select 'the self-service door creates the is_self environment',
    v_env is not null
      and exists (select 1 from erp.environment e
                   where e.id = v_env and e.tenant_id = v_tenant and e.is_self),
    'without it every guard that asks answers "still being built", for ever';

  return query select 'and creates it not yet live',
    not (select e.is_live from erp.environment e where e.id = v_env),
    'a tenant has to be built before it can be governed';

  return query select 'erp.tenant_is_live() agrees',
    not erp.tenant_is_live(v_tenant),
    'the guard and the installer must answer this question the same way';

  -- ---------------------------------------------------------------------
  -- Inside the window
  -- ---------------------------------------------------------------------

  return query select 'and a root entity, so the tenant has a chart of accounts',
    (v_onboard ->> 'entity_id') is not null,
    'without one erp.configure_finance() refuses, and nothing that posts can '
    'be installed at all';

  v_cs := erp.configure_finance();
  perform erp.configure_inventory('average');

  return query select 'a solo administrator can install a module',
    (select cs.status from erp.change_set cs where cs.id = v_cs) = 'promoted',
    'B6 refuses self-approval; before go-live there is no second person for '
    'it to find, which made a self-service tenant unconfigurable';

  return query select 'and the configuration it promoted is really there',
    (select count(*) from erp.posting_rule pr
      where pr.tenant_id = v_tenant and pr.status = 'active')
      = (select count(*) from erp.change_set_item i
          where i.change_set_id = v_cs and i.object_kind = 'posting_rule'),
    'promoted is a status on a row; every posting rule the set named has to '
    'be in erp.posting_rule for that status to mean anything';

  return query select 'the promotion records which environment it happened in',
    (select p.environment_id from erp.promotion p
      where p.tenant_id = v_tenant order by p.started_at desc limit 1) = v_env,
    'the column was nullable and the subquery returned null for this tenant, '
    'so promotion half-worked rather than refusing';

  -- ---------------------------------------------------------------------
  -- Closing it
  -- ---------------------------------------------------------------------

  begin
    perform erp.go_live();
    v_ok := false; v_msg := 'go_live() succeeded with one administrator';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_SINGLE_ADMINISTRATOR%'; v_msg := sqlerrm;
  end;
  return query select 'go-live refuses a tenant with one administrator',
    v_ok, v_msg;

  res := public.erp_invite_principal('second@zzboot.test', 'Second Admin');
  v_second := (res ->> 'app_user_id')::uuid;
  v_tok := res ->> 'token';
  perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');

  return query select 'go-live succeeds once there are two',
    (erp.go_live() ->> 'is_live')::boolean,
    'the second principal is what makes separation of duties possible at all';

  return query select 'and the tenant is live afterwards',
    erp.tenant_is_live(v_tenant),
    'the window is closed by a row, not by a session setting';

  begin
    perform erp.go_live();
    v_ok := false; v_msg := 'go_live() succeeded twice';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_ALREADY_LIVE%'; v_msg := sqlerrm;
  end;
  return query select 'going live twice is refused',
    v_ok, v_msg;

  -- ---------------------------------------------------------------------
  -- After it — nothing is looser than it was
  -- ---------------------------------------------------------------------

  v_cs := erp.configure_sales(15);

  return query select 'after go-live the installer stops at submitted',
    (select cs.status from erp.change_set cs where cs.id = v_cs) = 'ready',
    'this is the control the product wants once there is a product to control';

  begin
    perform erp.approve_change_set(v_cs);
    v_ok := false; v_msg := 'the author approved their own change set';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_CHANGE_SET_SELF_APPROVAL%'; v_msg := sqlerrm;
  end;
  return query select 'and the author may not approve it',
    v_ok, v_msg;

  begin
    insert into erp.rule_set (tenant_id, code, name, status)
    values (v_tenant, 'zzboot-direct', 'Direct edit', 'active');
    v_ok := false; v_msg := 'a live tenant accepted a direct configuration edit';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_LIVE_CONFIG_EDIT%'; v_msg := sqlerrm;
  end;
  return query select 'the live-configuration guard is now on',
    v_ok, v_msg;

  -- The second administrator can, which is the point of having one.
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(v_tok);
  perform erp.approve_change_set(v_cs);
  v_promo := erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  return query select 'a second administrator can approve and promote',
    (select cs.status from erp.change_set cs where cs.id = v_cs) = 'promoted',
    'separation of duties has to be satisfiable or it is only an outage';

  return query select 'that promotion also names the environment',
    (select p.environment_id from erp.promotion p where p.id = v_promo) = v_env,
    'erp.promotion.environment_id is not null now, so this cannot regress '
    'quietly';

  -- ---------------------------------------------------------------------
  -- The refusals the new column and helper are for
  -- ---------------------------------------------------------------------

  begin
    perform erp.self_environment_id(gen_random_uuid());
    v_ok := false; v_msg := 'self_environment_id() returned for an unknown tenant';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_NO_SELF_ENVIRONMENT%'; v_msg := sqlerrm;
  end;
  return query select 'a tenant with no self environment is refused, not defaulted',
    v_ok, v_msg;

  return query select 'the promotion environment cannot be null',
    (select a.attnotnull from pg_attribute a
      where a.attrelid = 'erp.promotion'::regclass and a.attname = 'environment_id'),
    'a promotion whose history cannot say where it happened is not a record';

  -- ---------------------------------------------------------------------
  -- The finding that would have caught the original defect
  -- ---------------------------------------------------------------------

  select count(*) into v_before from erp.dead_configuration_report()
   where finding = 'a tenant has no environment marked is_self';

  -- Cleared rather than deleted: erp.change_set.source_environment_id points at
  -- this row now, which is itself part of the fix.
  update erp.environment set is_self = false where id = v_env;

  return query select 'a tenant with no is_self environment is dead configuration',
    (select count(*) from erp.dead_configuration_report()
      where finding = 'a tenant has no environment marked is_self') = v_before + 1,
    'this is the finding that would have made the original hole a build '
    'failure rather than a live tenant nobody governed';

  -- Put it back: the assertions at the end of this migration run over every
  -- tenant, this one included.
  update erp.environment set is_self = true where id = v_env;

  -- ---------------------------------------------------------------------
  -- The operational surface
  -- ---------------------------------------------------------------------

  return query select 'every operational wrapper is on the write allow-list',
    not exists (
      select 1 from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname like 'erp\_%'
         and p.provolatile = 'v'
         and not exists (select 1 from erp_meta.public_write_allowance w
                          where w.function_name = p.proname)),
    'the allow-list is the review; a wrapper missing from it is a write '
    'nobody wrote a reason for';

  return query select 'the operational surface reaches the shop floor',
    (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname in ('erp_receive_against', 'erp_record_count',
                          'erp_book_operation_time', 'erp_record_inspection_result',
                          'erp_close_period', 'erp_configure_tax')) = 6,
    'a product whose configuration screens work and whose operations do not '
    'is a configuration editor';

  perform set_config('request.jwt.claims', '', true);

  -- Every other suite ends here, and this one did not.
  --
  -- This tenant is live by now, which no other suite's is. The purge window is
  -- what makes that survivable: erp.guard_live_configuration() refuses a
  -- direct write to a live tenant's configuration and exempts exactly one
  -- caller — a trusted session that has opened a purge for this tenant.
  perform erp.begin_tenant_purge(v_tenant);
  delete from erp.tenant where id = v_tenant;
  perform erp.end_tenant_purge();

  -- The two subjects live outside the tenant and there is no foreign key from
  -- erp.app_user.auth_user_id to auth.users, so nothing cascaded to them. They
  -- have to go by name.
  delete from auth.users where id in (a1, a2);

  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.id = v_tenant)
      and not exists (select 1 from auth.users u where u.id in (a1, a2)),
    'a suite that is only correct on an empty database is only correct on CI';
end;
$$;

create or replace function erp_test.assert_bootstrap_window_suite()
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_pass integer; v_total integer; v_detail text;
  -- Twenty-one, plus the case that the cleanup happened.
  c_expected constant integer := 22;
begin
  create temporary table if not exists zz_boot_result
    (case_name text, passed boolean, detail text) on commit drop;
  delete from zz_boot_result;
  insert into zz_boot_result select * from erp_test.bootstrap_window_suite();

  select count(*) filter (where passed), count(*),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_pass, v_total, v_detail from zz_boot_result;

  if v_total <> c_expected then
    raise exception 'ERPWARE_BOOTSTRAP_WINDOW_SUITE_INCOMPLETE: % cases, expected %',
      v_total, c_expected using errcode = 'P0001';
  end if;
  if v_pass < v_total then
    raise exception E'ERPWARE_BOOTSTRAP_WINDOW_SUITE_FAILED: %/%\n%',
      v_pass, v_total, v_detail using errcode = 'P0001';
  end if;

  return format('bootstrap window: %s/%s', v_pass, v_total);
end;
$$;

comment on function erp_test.bootstrap_window_suite() is
  'The bootstrap window, end to end: the self-service door, what a solo '
  'administrator may install inside the window, closing it, and that nothing '
  'is looser afterwards. Purges its tenant and the two subjects it fabricated, '
  'so it is repeatable on a database that is not thrown away.';

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_no_dead_configuration();
select erp.assert_public_api_safe();
select erp.assert_isolation();
