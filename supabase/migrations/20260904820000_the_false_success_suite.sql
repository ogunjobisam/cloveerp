-- ─────────────────────────────────────────────────────────────────────────────
-- The suite that would have caught the false successes.
--
-- 20260904810000 repaired six doors that reported an outcome they had not
-- produced. A repair without a test is a repair that comes back, and this class
-- is invisible to every check the build already runs: the schema is right, the
-- isolation is right, the assertion surface is right. Only calling a door with
-- an identifier it cannot act on shows it.
--
-- So each case does exactly that — an identifier that has never existed — and
-- requires a refusal. The suite is deliberately blunt: if a door in this list
-- ever again returns success for a row it did not touch, this fails.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.false_success_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_tenant  uuid;
  v_admin   uuid;
  v_auth    uuid := gen_random_uuid();
  v_ghost   uuid := '00000000-0000-4000-8000-000000000000';
  v_ok      boolean;
  v_msg     text;
  v_cases   int := 0;
begin
  select t.tenant_id, t.admin_user_id into v_tenant, v_admin
    from erp.provision_tenant('false-success-suite', 'False Success Suite',
                              'suite@false-success.test', 'Suite Runner') t;

  -- The doors authorise before they look anything up, so the suite has to be
  -- somebody. It becomes the administrator provisioning created, the same way a
  -- person signs in: an auth identity bound to the app_user, and the claim that
  -- erp.principal_context() resolves from. Without this every case refuses on
  -- permission and the not-found check below is never reached — which is
  -- exactly what the first run of this suite did.
  insert into auth.users (id, email) values (v_auth, 'suite@false-success.test')
    on conflict (id) do nothing;
  update erp.app_user set auth_user_id = v_auth, status = 'active'
   where tenant_id = v_tenant and id = v_admin;
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_auth, 'role', 'authenticated')::text, true);

  -- Each door is called with an identifier no organisation holds. A door that
  -- returns instead of raising has reported work it did not do.
  <<doors>>
  declare
    d text;
    calls text[] := array[
      'select public.erp_retire_approval_band(%L::uuid)',
      'select public.erp_end_approver_assignment(%L::uuid)',
      'select public.erp_end_department_membership(%L::uuid)',
      'select public.erp_end_item_supplier(%L::uuid)',
      'select public.erp_retire_account_determination(%L::uuid)',
      'select erp.approve_change_set(%L::uuid)'
    ];
  begin
    foreach d in array calls loop
      v_cases := v_cases + 1;
      v_ok := false; v_msg := 'returned success for an identifier that does not exist';
      begin
        execute format(d, v_ghost);
      exception
        when others then
          if SQLERRM like '%NOT_FOUND%' then
            v_ok := true; v_msg := left(SQLERRM, 90);
          else
            v_ok := false; v_msg := 'refused, but not as a not-found: '||left(SQLERRM, 70);
          end if;
      end;
      return query select
        format('%s refuses an identifier that does not exist',
               substring(d from 'erp[_a-z.]*')),
        v_ok, v_msg;
    end loop;
  end doors;

  -- And the platform audit trail refuses to be rewritten, on the same
  -- connection that drains the outbox.
  v_cases := v_cases + 1;
  v_ok := false; v_msg := 'DELETE was permitted';
  begin
    delete from erp_meta.platform_audit where false;
    -- `where false` still fires a statement-level check but no row trigger, so
    -- force a row to exist and remove it for real.
    insert into erp_meta.platform_audit (actor_email, actor_role, action, tenant_id, tenant_code, reason)
      values ('suite@false-success.test','suite','probe', v_tenant, 'false-success-suite','append-only probe');
    delete from erp_meta.platform_audit where reason = 'append-only probe';
  exception when others then
    if SQLERRM like '%APPEND_ONLY%' then v_ok := true; v_msg := left(SQLERRM, 90); end if;
  end;
  return query select 'erp_meta.platform_audit refuses DELETE'::text, v_ok, v_msg;

  perform erp.begin_tenant_purge(v_tenant);
  delete from erp.tenant where id = v_tenant;
  perform erp.end_tenant_purge();

  if v_cases <> 7 then
    raise exception 'ERPWARE_SUITE_SHRANK: false_success_suite ran % cases, expected 7', v_cases;
  end if;
end;
$$;

revoke all on function erp_test.false_success_suite() from public, anon;

create or replace function erp_test.assert_false_success_suite()
returns text
language plpgsql
security definer
set search_path to ''
as $$
declare v_fail int; v_all int; v_detail text;
begin
  create temp table if not exists _fs on commit drop as
    select * from erp_test.false_success_suite();
  select count(*), count(*) filter (where not passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_all, v_fail, v_detail from _fs;
  if v_fail > 0 then
    raise exception E'ERPWARE_FALSE_SUCCESS_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail
      using errcode = 'P0001',
      hint = 'A door returned success for an identifier it could not act on. '
             'Add `if not found then raise` after the update.';
  end if;
  return format('false success: %s/%s cases pass', v_all - v_fail, v_all);
end;
$$;

revoke all on function erp_test.assert_false_success_suite() from public, anon;
