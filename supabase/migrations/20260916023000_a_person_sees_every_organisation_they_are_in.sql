-- =============================================================================
-- A person sees every organisation they are in
--
-- On 16 September the owner's account held a principal in three organisations —
-- the console's own read says so — and the desk's account menu offered no way
-- to move between them. The staff guide tells a reader to "switch to Clove
-- ERP's own organisation from the account menu", and there was nothing there
-- to press.
--
-- public.erp_my_tenants() is what the menu asks. It is SECURITY INVOKER, so
-- row security answers it, and row security on erp.app_user is
-- "tenant_id = erp.current_tenant_id()" — the organisation the person is
-- working in. A read whose purpose is to list the others can never see them:
-- it returned one row, the menu needs more than one to offer a choice, and so
-- the choice was never offered. erp_platform_my_tenancies() reads the same
-- ground as its owner and returned three, which is how the two screens
-- disagreed.
--
-- The read now runs as its owner and is bound to the caller's own sign-in:
-- auth.uid() decides which rows come back, and nothing else does. It is still
-- the same shape, the same order and the same three keys, so the menu, the
-- quote builder and the selling setup read it unchanged.
--
-- erp.set_active_tenant() already refuses everybody but platform staff, and
-- the menu only offers the picker to them, so what changes here is that they
-- can see the organisations they are entitled to move between.
--
-- A sign-in is bound to one principal by invitation
-- (CLOVEERP_IDENTITY_ALREADY_BOUND), which is why the suite below builds its
-- second principal the way the owner's own second organisation was built:
-- platform staff entering an organisation with a reason, which is what makes
-- the principal. The support access on its own does not: entering is what
-- gives the person a role there, and so what the account menu is listing.
-- =============================================================================

create or replace function public.erp_my_tenants()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'tenant_id', t.id, 'code', t.code, 'name', t.name,
           'principal_id', u.id, 'is_active', u.tenant_id = erp.current_tenant_id())
           order by t.name), '[]'::jsonb)
    from erp.app_user u
    join erp.tenant t on t.id = u.tenant_id
   where (select auth.uid()) is not null
     and u.auth_user_id = (select auth.uid())
     and u.status = 'active'::erp.principal_status
$$;

comment on function public.erp_my_tenants() is
  'Every organisation the signed-in person holds an active principal in, with '
  'which one they are working in. Runs as its owner because row security scopes '
  'erp.app_user to the organisation in context, and the whole purpose of this '
  'read is the ones that are not.';

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('public', 'erp_my_tenants',
   'UNGATED BY DESIGN: bound to the caller''s own identity. It returns nothing without a signed-in '
   'subject, and only rows whose principal is that subject''s own and active. It reads across '
   'organisations because a person who belongs to two is entitled to know it; it writes nothing, '
   'and moving between them is erp.set_active_tenant(), which refuses everybody but platform staff.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

-- ── The suite ────────────────────────────────────────────────────────────────

create or replace function erp_test.my_organisations_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  ra record; rb record; rc record;
  one uuid := gen_random_uuid();
  two uuid := gen_random_uuid();
  v_a text := 'zzmo-a-' || substr(md5(random()::text), 1, 6);
  v_b text := 'zzmo-b-' || substr(md5(random()::text), 1, 6);
  v_c text := 'zzmo-c-' || substr(md5(random()::text), 1, 6);
  res jsonb;
begin
  select * into ra from erp.provision_tenant(v_a, 'My Organisations A', 'one@zzmo.test', 'Person One');
  select * into rb from erp.provision_tenant(v_b, 'My Organisations B', 'admin-b@zzmo.test', 'Admin B');
  select * into rc from erp.provision_tenant(v_c, 'My Organisations C', 'two@zzmo.test', 'Person Two');
  insert into auth.users (id, email) values (one, 'one@zzmo.test'), (two, 'two@zzmo.test');

  -- One principal by invitation. A sign-in is bound to one principal that way
  -- (CLOVEERP_IDENTITY_ALREADY_BOUND), so the second comes the way the owner's
  -- own second organisation came: platform staff, entering with a reason.
  perform set_config('request.jwt.claims', json_build_object('sub', one)::text, true);
  perform erp.claim_invitation(ra.admin_token);
  perform set_config('request.jwt.claims', json_build_object('sub', two)::text, true);
  perform erp.claim_invitation(rc.admin_token);

  insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
  values ('one@zzmo.test', one, 'Person One', 'owner');
  perform set_config('request.jwt.claims', json_build_object('sub', one)::text, true);
  perform public.erp_platform_enter_tenant(rb.tenant_id,
    'Suite: a person who belongs to two organisations sees both');

  perform set_config('request.jwt.claims', json_build_object('sub', one)::text, true);
  res := public.erp_my_tenants();
  return query select 'a person in two organisations sees both'::text,
    (select count(*) from jsonb_array_elements(res)) = 2
    and exists (select 1 from jsonb_array_elements(res) x where x ->> 'code' = v_a)
    and exists (select 1 from jsonb_array_elements(res) x where x ->> 'code' = v_b),
    format('%s organisation(s): %s', (select count(*) from jsonb_array_elements(res)),
           coalesce((select string_agg(x ->> 'code', ', ') from jsonb_array_elements(res) x), 'none'));

  return query select 'and neither of them is somebody else''s'::text,
    not exists (select 1 from jsonb_array_elements(res) x where x ->> 'code' = v_c),
    'the third organisation belongs to another person';

  return query select 'the one being worked in is marked as such'::text,
    (select count(*) from jsonb_array_elements(res) x where (x ->> 'is_active')::boolean) <= 1,
    'at most one is active, which is what the menu ticks';

  perform set_config('request.jwt.claims', json_build_object('sub', two)::text, true);
  res := public.erp_my_tenants();
  return query select 'the other person sees only their own'::text,
    (select count(*) from jsonb_array_elements(res)) = 1
    and exists (select 1 from jsonb_array_elements(res) x where x ->> 'code' = v_c),
    format('%s organisation(s)', (select count(*) from jsonb_array_elements(res)));

  perform set_config('request.jwt.claims', '', true);
  res := public.erp_my_tenants();
  return query select 'nobody signed in sees nothing'::text,
    res = '[]'::jsonb, res::text;

  -- ── Clean up ─────────────────────────────────────────────────────────────

  perform erp.begin_tenant_purge(ra.tenant_id);
  delete from erp.tenant where id = ra.tenant_id;
  perform erp.end_tenant_purge();
  perform erp.begin_tenant_purge(rb.tenant_id);
  delete from erp.tenant where id = rb.tenant_id;
  perform erp.end_tenant_purge();
  perform erp.begin_tenant_purge(rc.tenant_id);
  delete from erp.tenant where id = rc.tenant_id;
  perform erp.end_tenant_purge();
  delete from erp_meta.platform_staff where email = 'one@zzmo.test';
  delete from auth.users where id in (one, two);

  return query select 'the suite leaves nothing behind'::text,
    not exists (select 1 from erp.tenant t where t.code in (v_a, v_b, v_c))
    and not exists (select 1 from erp_meta.platform_staff st where st.email = 'one@zzmo.test'),
    'three organisations and the staff row gone';
end;
$$;

revoke all on function erp_test.my_organisations_suite() from public, anon;

create or replace function erp_test.assert_my_organisations_suite()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _my_organisations_result on commit drop as
    select * from erp_test.my_organisations_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _my_organisations_result;
  if v_total <> 6 then
    raise exception 'CLOVEERP_SUITE_SHRANK: my_organisations_suite ran % cases, expected 6', v_total;
  end if;
  if v_passed < v_total then
    raise exception E'CLOVEERP_MY_ORGANISATIONS_SUITE_FAILED: %/%\n%', v_passed, v_total, v_detail
      using errcode = 'P0001';
  end if;
  return format('my organisations: %s/%s', v_passed, v_total);
end;
$$;

revoke all on function erp_test.assert_my_organisations_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_writes_name_their_rows();
select erp_test.assert_my_organisations_suite();
