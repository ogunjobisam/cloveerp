-- Platform staff can change organisation.
--
-- The account menu offers platform staff a list of their organisations to
-- switch between (src/components/erp/user-menu.tsx). Choosing one has failed
-- for every caller since 20260830124417, staff included, with "permission
-- denied for schema erp_meta". public.erp_set_active_tenant() is SECURITY
-- INVOKER, and its first statement asks erp_meta.platform_actor() whether the
-- caller is staff. A signed-in caller has had no USAGE on erp_meta since
-- 20260830024837, and 20260904720000 asserts it stays that way, so the door
-- cannot name the question it opens with. The refusal the door means to give
-- a non-staff caller, ERPWARE_TENANT_FIXED, was never reached either; the wall
-- answered first.
--
-- The fix is the one 20260904720000 gave erp_platform_run_check and
-- 20260904620000 gave erp_platform_generate_invoices: the door runs as its
-- owner, so it can reach the schema its check lives in. The body is unchanged,
-- and the search path stays empty.
--
-- Why running as the owner changes nothing either check answers:
--
--   * erp_meta.platform_actor() finds the staff row by auth.uid() or by the
--     address on that auth user. auth.uid() reads the request's JWT claims,
--     which a SECURITY DEFINER frame does not change. The owner is not the
--     subject it looks up.
--   * erp.set_active_tenant() (20260829180000) was SECURITY DEFINER already.
--     Its gate is membership: it refuses unless auth.uid() holds an active
--     principal in the organisation named, and it writes only that subject's
--     own row in erp_meta.principal_preference. It never reads current_user,
--     session_user or erp.session_is_trusted(), which are the only things a
--     definer frame would answer differently.
--
-- erp.public_api_report() refuses a registered SECURITY DEFINER door that
-- reaches neither erp.authorise() nor erp_meta.require_platform(). This door
-- reaches neither, on purpose. No organisation permission applies to choosing
-- between organisations. Its refusals are the staff check and the membership
-- test above, and 20260913070000 records it as touching only the caller's own
-- records (ungated_because = 'own_records'). Calling require_platform() here
-- would make that register row stale. So the allowance row takes the prefix
-- the rule reads as a declared exemption, beside erp_platform_me and
-- erp_platform_claim_ownership. The suite below is what proves both refusals.
--
-- Ordering: 20260913070000 may land before or after this file. Nothing here
-- depends on its column. If the column is there, the check in section 3
-- confirms the register still says own_records.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The door runs as its owner
-- ═════════════════════════════════════════════════════════════════════════════

alter function public.erp_set_active_tenant(uuid) security definer set search_path = '';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The allowance says why it needs neither gate function
-- ═════════════════════════════════════════════════════════════════════════════

update erp_meta.security_definer_allowance
   set rationale =
     'UNGATED BY DESIGN: records which of the caller''s own organisations is '
     'active, so no organisation permission can apply. It refuses anyone who is '
     'not platform staff through erp_meta.platform_actor() on its first line, '
     'then erp.set_active_tenant() refuses any organisation where auth.uid() '
     'holds no active principal. Runs as its owner because erp_meta is sealed '
     'to a signed-in caller, and both checks read the JWT subject, never the '
     'role. erp_test.active_tenant_switch_suite proves both refusals.'
 where schema_name = 'public' and function_name = 'erp_set_active_tenant';

do $allowance$
begin
  if not exists (select 1 from erp_meta.security_definer_allowance
                  where schema_name = 'public' and function_name = 'erp_set_active_tenant'
                    and rationale like 'UNGATED BY DESIGN:%') then
    raise exception 'CLOVEERP_ACTIVE_TENANT_ALLOWANCE_MISSING: public.erp_set_active_tenant has no security definer allowance row to annotate';
  end if;
end
$allowance$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The write register still says own records
-- ═════════════════════════════════════════════════════════════════════════════

do $register$
declare
  v_basis text;
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'erp_meta' and table_name = 'public_write_allowance'
                and column_name = 'ungated_because') then
    execute $q$select w.ungated_because from erp_meta.public_write_allowance w
               where w.function_name = 'erp_set_active_tenant'$q$
       into v_basis;
    if v_basis is distinct from 'own_records' then
      raise exception 'CLOVEERP_ACTIVE_TENANT_REGISTER_DRIFTED: erp_set_active_tenant is registered ungated because %, expected own_records',
        coalesce(v_basis, 'nothing');
    end if;
  end if;
end
$register$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The suite, calling the door as the data API does
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.active_tenant_switch_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_owner text := current_user;
  v_tag   text := substr(md5(random()::text), 1, 6);
  ra record; rb record; rc record;
  v_staff uuid := gen_random_uuid();
  v_other uuid := gen_random_uuid();
  v_result jsonb;
  v_now    uuid;
  v_ok     boolean;
  v_msg    text;
begin
  begin
    -- Three organisations. The staff member and an ordinary person each hold
    -- an active principal in the first two; nobody here holds one in the third.
    perform set_config('request.jwt.claims', '', true);
    select * into ra from erp.provision_tenant('zzsata-' || v_tag, 'Switch Suite A', 'a@zzsat-' || v_tag || '.test', 'A Admin');
    select * into rb from erp.provision_tenant('zzsatb-' || v_tag, 'Switch Suite B', 'b@zzsat-' || v_tag || '.test', 'B Admin');
    select * into rc from erp.provision_tenant('zzsatc-' || v_tag, 'Switch Suite C', 'c@zzsat-' || v_tag || '.test', 'C Admin');

    insert into auth.users (id, email) values
      (v_staff, 'staff@zzsat-' || v_tag || '.test'),
      (v_other, 'person@zzsat-' || v_tag || '.test');
    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
    values ('staff@zzsat-' || v_tag || '.test', v_staff, 'Switch Suite Staff', 'support');
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email) values
      (ra.tenant_id, v_staff, 'person', 'active', 'Switch Suite Staff', 'staff@zzsat-' || v_tag || '.test'),
      (rb.tenant_id, v_staff, 'person', 'active', 'Switch Suite Staff', 'staff@zzsat-' || v_tag || '.test'),
      (ra.tenant_id, v_other, 'person', 'active', 'Switch Suite Person', 'person@zzsat-' || v_tag || '.test'),
      (rb.tenant_id, v_other, 'person', 'active', 'Switch Suite Person', 'person@zzsat-' || v_tag || '.test');

    -- 1
    return query
      select 'the door runs as its owner, with an empty search path',
             p.prosecdef and p.proconfig = array['search_path=""'],
             format('prosecdef %s, proconfig %s', p.prosecdef, p.proconfig)
        from pg_catalog.pg_proc p
       where p.oid = 'public.erp_set_active_tenant(uuid)'::regprocedure;

    -- 2. Signed in as staff, through the data API's role.
    perform set_config('request.jwt.claims', json_build_object('sub', v_staff, 'role', 'authenticated')::text, true);
    v_msg := null;
    execute 'set local role authenticated';
    begin
      v_result := public.erp_set_active_tenant(rb.tenant_id);
      v_now := erp.current_tenant_id();
    exception when others then
      v_result := null; v_now := null; v_msg := left(sqlerrm, 160);
    end;
    execute format('set local role %I', v_owner);
    return query select 'a platform staff member in two organisations switches to the second',
      (v_result ->> 'tenant_id')::uuid = rb.tenant_id and v_now = rb.tenant_id,
      coalesce(v_msg, format('door returned %s; the session now resolves to %s', v_result ->> 'tenant_id', v_now));

    -- 3
    v_msg := null;
    execute 'set local role authenticated';
    begin
      v_result := public.erp_set_active_tenant(ra.tenant_id);
      v_now := erp.current_tenant_id();
    exception when others then
      v_result := null; v_now := null; v_msg := left(sqlerrm, 160);
    end;
    execute format('set local role %I', v_owner);
    return query select 'and switches back to the first, which is the choice recorded',
      (v_result ->> 'tenant_id')::uuid = ra.tenant_id and v_now = ra.tenant_id
      and (select pp.active_tenant_id from erp_meta.principal_preference pp where pp.auth_user_id = v_staff) = ra.tenant_id,
      coalesce(v_msg, format('door returned %s; the session now resolves to %s', v_result ->> 'tenant_id', v_now));

    -- 4. The membership gate still answers from inside the definer frame.
    execute 'set local role authenticated';
    begin
      perform public.erp_set_active_tenant(rc.tenant_id);
      v_ok := false; v_msg := 'an organisation the staff member holds no principal in was accepted';
    exception when others then
      v_ok := sqlerrm like 'ERPWARE_NOT_A_MEMBER%'; v_msg := left(sqlerrm, 160);
    end;
    v_now := erp.current_tenant_id();
    execute format('set local role %I', v_owner);
    return query select 'a platform staff member is refused an organisation they hold no principal in, and their choice stands',
      v_ok and v_now = ra.tenant_id
      and (select pp.active_tenant_id from erp_meta.principal_preference pp where pp.auth_user_id = v_staff) = ra.tenant_id,
      v_msg;

    -- 5. Not staff: refused in the door's own words, not by the schema wall,
    --    even between two organisations the caller belongs to.
    perform set_config('request.jwt.claims', json_build_object('sub', v_other, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    begin
      perform public.erp_set_active_tenant(rb.tenant_id);
      v_ok := false; v_msg := 'a caller who is not platform staff changed organisation';
    exception when others then
      v_ok := sqlerrm like 'ERPWARE_TENANT_FIXED%'; v_msg := left(sqlerrm, 160);
    end;
    execute format('set local role %I', v_owner);
    return query select 'a caller who is not platform staff is refused, even between two organisations they belong to',
      v_ok and not exists (select 1 from erp_meta.principal_preference pp where pp.auth_user_id = v_other),
      v_msg;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;
end;
$$;
revoke all on function erp_test.active_tenant_switch_suite() from public, anon, authenticated;

create or replace function erp_test.assert_active_tenant_switch_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 5;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  select count(*), count(*) filter (where coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n') filter (where not coalesce(s.passed, false))
    into v_total, v_passed, v_detail
    from erp_test.active_tenant_switch_suite() s;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_ACTIVE_TENANT_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_ACTIVE_TENANT_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('active organisation switch: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_active_tenant_switch_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_active_tenant_switch_suite();

select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_invoker_doors_executable();
select erp.assert_governed_views_are_safe();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
