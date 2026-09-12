-- The entitlement gate works. The suite was asking the wrong person.
--
-- erp_test.commercial_suite() reported two failures:
--
--   restricted refuses a write — a write was permitted on a restricted organisation
--   suspended withdraws access entirely — a read was permitted on a suspended organisation
--
-- The obvious reading is that §18.3 was never enforced. It is: 20260904190000
-- put the check in erp.authorise(), it is still there, and it raises
-- CLOVEERP_ORGANISATION_RESTRICTED and CLOVEERP_ORGANISATION_SUSPENDED with
-- the right wording on each.
--
-- What changed is who was asking. 20260910145350 added a platform-owner
-- override at the top of erp.authorise():
--
--   if erp.is_platform_owner() then ... return; end if;
--
-- and the suite claims the organisation's admin invitation as `ow` — a row it
-- inserts into erp_meta.platform_staff with staff_role 'owner'. So every case
-- in §18.3 ran through the override and returned before reaching the gate.
-- Both "failures" were the override working, measured as if it were the
-- entitlement rule failing.
--
-- The override is right and stays. Staff have to be able to reach an
-- organisation that has been suspended, because resolving what suspended it is
-- the whole job; locking your own people out of a non-paying customer helps
-- nobody. §18.3 is about the organisation's own people, so the suite now
-- proves it as one of them — a separate principal who claims the admin
-- invitation and holds no platform staff row.
--
-- And the override gets a case of its own. It was load-bearing and untested,
-- which is how it silently ate two other cases; now a suspended organisation
-- is proven to still admit the platform owner, so the next person to move that
-- block finds out from the build rather than from a customer.
--
-- Twenty cases become twenty-one, and the wrapper's pin moves with them.

do $comm$
declare
  v_def text;
  v_new text;
begin
  v_def := pg_get_functiondef('erp_test.commercial_suite()'::regprocedure);

  -- 1. A principal of the organisation, distinct from the platform owner.
  v_new := replace(v_def,
$old$  ow uuid := gen_random_uuid();$old$,
$new$  ow uuid := gen_random_uuid();
  ad uuid := gen_random_uuid();$new$);

  if v_new = v_def then
    raise exception 'CLOVEERP_COMMERCIAL_SUITE_UNRECOGNISED: the owner declaration is not where this migration expects it';
  end if;
  v_def := v_new;

  -- 2. §18.3 is asked of the organisation's admin, not of platform staff.
  v_new := replace(v_def,
$old$  perform set_config('request.jwt.claims',
                     json_build_object('sub', ow)::text, true);
  perform erp.claim_invitation(r.admin_token);

  update erp.tenant set status = 'restricted' where id = v_tenant;$old$,
$new$  -- §18.3 is about the organisation's own people. Claiming this invitation
  -- as the platform owner sent every case below through the override in
  -- erp.authorise() and proved nothing about entitlement.
  insert into auth.users (id, email) values (ad, 'admin-a@zzcomm.test');
  perform set_config('request.jwt.claims',
                     json_build_object('sub', ad)::text, true);
  perform erp.claim_invitation(r.admin_token);

  update erp.tenant set status = 'restricted' where id = v_tenant;$new$);

  if v_new = v_def then
    raise exception 'CLOVEERP_COMMERCIAL_SUITE_UNRECOGNISED: the section 18.3 fixture is not the one this migration expects';
  end if;
  v_def := v_new;

  -- 3. The override, proven deliberately rather than relied on by accident.
  v_new := replace(v_def,
$old$  return query select 'suspended withdraws access entirely', v_ok, v_msg;

  update erp.tenant set status = 'active' where id = v_tenant;$old$,
$new$  return query select 'suspended withdraws access entirely', v_ok, v_msg;

  -- Whoever moves the override in erp.authorise() should hear it from here.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', ow)::text, true);
  begin
    perform erp.authorise('master_data.write');
    v_ok := true; v_msg := 'platform owner retains access';
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 80);
  end;
  return query select 'but the platform owner is not locked out of it', v_ok,
    v_msg || ' — resolving what suspended an organisation is done from inside it';

  perform set_config('request.jwt.claims',
                     json_build_object('sub', ad)::text, true);

  update erp.tenant set status = 'active' where id = v_tenant;$new$);

  if v_new = v_def then
    raise exception 'CLOVEERP_COMMERCIAL_SUITE_UNRECOGNISED: the suspension case is not where this migration expects it';
  end if;
  v_def := v_new;

  -- 4. The suite still leaves nothing behind.
  v_new := replace(v_def,
$old$  delete from auth.users where id = ow;$old$,
$new$  delete from auth.users where id in (ow, ad);$new$);
  if v_new = v_def then
    raise exception 'CLOVEERP_COMMERCIAL_SUITE_UNRECOGNISED: the cleanup does not delete the owner as this migration expects';
  end if;
  v_def := v_new;

  v_new := replace(v_def,
$old$      and not exists (select 1 from auth.users u where u.id = ow),$old$,
$new$      and not exists (select 1 from auth.users u where u.id in (ow, ad)),$new$);
  if v_new = v_def then
    raise exception 'CLOVEERP_COMMERCIAL_SUITE_UNRECOGNISED: the leaves-nothing-behind case is not the one this migration expects';
  end if;

  execute v_new;
end
$comm$;

-- The pin moves by one, deliberately.
do $pin$
declare
  v_def text;
  v_new text;
begin
  v_def := pg_get_functiondef('erp_test.assert_commercial_suite()'::regprocedure);

  v_new := replace(v_def,
$old$  if v_total <> 20 then
    raise exception
      'CLOVEERP_COMMERCIAL_SUITE_SHRANK: % case(s), expected 20', v_total$old$,
$new$  if v_total <> 21 then
    raise exception
      'CLOVEERP_COMMERCIAL_SUITE_SHRANK: % case(s), expected 21', v_total$new$);

  if v_new = v_def then
    raise exception 'CLOVEERP_COMMERCIAL_PIN_UNRECOGNISED: erp_test.assert_commercial_suite() does not pin 20 cases';
  end if;

  execute v_new;
end
$pin$;

select erp_test.assert_commercial_suite();
