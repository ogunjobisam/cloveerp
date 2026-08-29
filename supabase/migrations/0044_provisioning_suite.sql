-- =============================================================================
-- ERPWare — the adversarial suite for provisioning and the write surface
--
-- Everything 0041 and 0042 added is a way IN. That makes each of them worth
-- attacking rather than demonstrating: the interesting question is never "does
-- provisioning work", it is "what does the door refuse".
--
-- Two of these cases exist because the first draft got them wrong, and both
-- were found by running this rather than by reading it:
--
--   Provisioning created the administrator but no invitation, so the tenant
--   was reachable by nobody — erp.set_job_principal() refuses to adopt a
--   person, deliberately, so an invitation is the only door.
--
--   Provisioning created the self environment as live and then tried to insert
--   the administrator role, which B6's guard correctly refused. A tenant has to
--   be built before it can be governed; the guard says so itself.
--
-- Also repaired here: erp_test.assert_stock_invariants() and
-- erp_test.assert_gateway_suite() reported "n/n cases passed" without asserting
-- what n should be, so a case that quietly stopped existing would have been
-- reported as success. The CI workflow already claimed all three suites
-- asserted their own counts. Only the isolation suite did.
-- =============================================================================

create or replace function erp_test.provisioning_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  r          record;
  r2         record;
  r3         record;
  v_uid      uuid := gen_random_uuid();
  v_uid2     uuid := gen_random_uuid();
  v_claimed  uuid;
  v_new      uuid;
  v_res      jsonb;
  v_tok      text;
  v_ok       boolean;
  v_msg      text;
begin
  -- ---------------------------------------------------------------- shape --
  select * into r from erp.provision_tenant(
    'zzsuite-a', 'Suite Tenant A', 'admin@suite-a.test', 'Suite A Admin');

  return query select 'provisioning returns a tenant, entity, admin and token',
    r.tenant_id is not null and r.entity_id is not null
      and r.admin_user_id is not null and length(r.admin_token) = 64,
    format('tenant=%s token_len=%s', left(r.tenant_id::text, 8), length(r.admin_token));

  return query select 'the self environment exists and is live',
    exists (select 1 from erp.environment e
             where e.tenant_id = r.tenant_id and e.is_self and e.is_live),
    'B6 needs exactly one is_self environment, and it must be governed after build';

  return query select 'the administrator role holds every permission',
    (select count(*) from erp.role_permission rp where rp.tenant_id = r.tenant_id)
      = (select count(*) from erp_ref.permission),
    format('%s of %s',
      (select count(*) from erp.role_permission rp where rp.tenant_id = r.tenant_id),
      (select count(*) from erp_ref.permission));

  return query select 'the first administrator is invited, not active',
    (select u.status from erp.app_user u where u.id = r.admin_user_id) = 'invited',
    'an account nobody has signed into must not already be active';

  return query select 'the invitation stores a digest, not the token',
    not exists (select 1 from erp.invitation i where i.token_digest = r.admin_token),
    'reading erp.invitation must not yield a usable credential';

  -- ----------------------------------------------------------- refusals ---
  begin
    perform erp.provision_tenant('zzsuite-a', 'Duplicate', 'x@y.test', 'X');
    v_ok := false; v_msg := 'a duplicate tenant code was accepted';
  exception when others then v_ok := true; v_msg := sqlerrm; end;
  return query select 'a duplicate tenant code is refused', v_ok, v_msg;

  begin
    execute 'set local role authenticated';
    perform erp.provision_tenant('zzsuite-x', 'Sneaky', 'x@y.test', 'X');
    execute 'reset role';
    v_ok := false; v_msg := 'an untrusted session provisioned a tenant';
  exception when others then
    execute 'reset role';
    v_ok := (sqlstate = '42501'); v_msg := sqlerrm;
  end;
  return query select 'an untrusted session cannot provision a tenant', v_ok, v_msg;

  begin
    update erp.role set name = 'edited' where tenant_id = r.tenant_id;
    v_ok := false; v_msg := 'a live configuration edit was allowed';
  exception when sqlstate '42501' then v_ok := true; v_msg := left(sqlerrm, 70);
  end;
  return query select 'configuration cannot be edited directly once live', v_ok, v_msg;

  -- -------------------------------------------------------------- claim ---
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
  v_claimed := erp.claim_invitation(r.admin_token);

  return query select 'a valid token binds the signed-in subject to its principal',
    v_claimed = r.admin_user_id,
    format('claimed %s', left(v_claimed::text, 8));

  return query select 'the principal resolves after claiming',
    (select erp.current_principal_id()) = r.admin_user_id,
    'erp.principal_context() must now find the row';

  return query select 'claiming activates the principal',
    (select u.status from erp.app_user u where u.id = r.admin_user_id) = 'active',
    'invited becomes active exactly when the identity is bound';

  begin
    perform erp.claim_invitation(r.admin_token);
    v_ok := false; v_msg := 'the token was reusable';
  exception when others then
    v_ok := (sqlerrm like '%INVITATION_NOT_OPEN%'
             or sqlerrm like '%IDENTITY_ALREADY_BOUND%'); v_msg := sqlerrm;
  end;
  return query select 'a token cannot be redeemed twice', v_ok, v_msg;

  begin
    perform erp.claim_invitation(repeat('a', 64));
    v_ok := false; v_msg := 'an unknown token was accepted';
  exception when others then
    v_ok := (sqlerrm like '%INVITATION_NOT_OPEN%'); v_msg := sqlerrm;
  end;
  return query select 'an unknown token is refused', v_ok, v_msg;

  -- Expiry needs a genuinely aged row, and getting there is less obvious than
  -- it looks. A short validity plus pg_sleep() does not work: now() is
  -- transaction start time, so an invitation minted and redeemed inside one
  -- transaction can never be expired, and the case passed on a different
  -- refusal entirely while the expiry branch went unrun.
  --
  -- The attribution trigger coalesces created_at on INSERT rather than
  -- overwriting it, so an explicitly aged row survives — and
  -- invitation_expiry_sane is satisfied because expires_at is still after
  -- created_at. Both timestamps in the past is the one shape that reaches the
  -- branch.
  select * into r2 from erp.provision_tenant(
    'zzsuite-b', 'Suite Tenant B', 'admin@suite-b.test', 'Suite B Admin');
  v_tok := encode(extensions.gen_random_bytes(32), 'hex');
  insert into erp.invitation (tenant_id, app_user_id, token_digest,
                              created_at, expires_at)
  values (r2.tenant_id, r2.admin_user_id,
          encode(extensions.digest(v_tok, 'sha256'), 'hex'),
          now() - interval '2 days', now() - interval '1 day');
  -- A FRESH subject, and the reason is asserted rather than the mere fact of a
  -- refusal. With the already-bound subject still in the claims this case
  -- passed on ERPWARE_IDENTITY_ALREADY_BOUND without ever reaching the expiry
  -- check — green, and proving nothing.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', gen_random_uuid())::text, true);
  begin
    perform erp.claim_invitation(v_tok);
    v_ok := false; v_msg := 'an expired token was accepted';
  exception when others then
    v_ok := (sqlerrm like '%INVITATION_NOT_OPEN%'); v_msg := sqlerrm;
  end;
  return query select 'an expired token is refused, for being expired', v_ok, v_msg;

  -- One identity, one principal, forever. A fresh tenant, because tenant B's
  -- invitation is deliberately expired above.
  select * into r3 from erp.provision_tenant(
    'zzsuite-c', 'Suite Tenant C', 'admin@suite-c.test', 'Suite C Admin');
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
  begin
    perform erp.claim_invitation(r3.admin_token);
    v_ok := false; v_msg := 'one subject claimed two principals';
  exception when others then
    v_ok := (sqlerrm like '%IDENTITY_ALREADY_BOUND%'); v_msg := left(sqlerrm, 70);
  end;
  return query select 'one sign-in cannot become a second principal', v_ok, v_msg;

  -- --------------------------------------------------------- write API ---
  -- Back to tenant A's administrator, who holds everything.
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);

  v_res := public.erp_invite_principal('colleague@suite-a.test', 'A Colleague');
  v_new := (v_res->>'app_user_id')::uuid;
  v_tok := v_res->>'token';
  return query select 'erp_invite_principal creates a principal and returns one token',
    v_new is not null and length(v_tok) = 64,
    format('user=%s', left(v_new::text, 8));

  v_res := public.erp_create_service_principal('Suite dispatch worker');
  return query select 'a service principal is created with no authentication identity',
    (select u.kind = 'service' and u.auth_user_id is null and u.status = 'active'
       from erp.app_user u where u.id = (v_res->>'app_user_id')::uuid),
    'spec 2.4: service accounts are first class, and never sign in';

  -- A principal holding nothing must not be able to administer.
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid2)::text, true);
  perform erp.claim_invitation(v_tok);
  begin
    perform public.erp_invite_principal('nope@suite-a.test', 'Nope');
    v_ok := false; v_msg := 'a principal with no grants invited someone';
  exception when others then v_ok := true; v_msg := left(sqlerrm, 70); end;
  return query select 'the write surface refuses a caller holding no permission',
    v_ok, v_msg;

  -- ------------------------------------------------------------ cleanup ---
  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(r.tenant_id);
  delete from erp.tenant where id = r.tenant_id;
  perform erp.end_tenant_purge();
  perform erp.begin_tenant_purge(r2.tenant_id);
  delete from erp.tenant where id = r2.tenant_id;
  perform erp.end_tenant_purge();
  perform erp.begin_tenant_purge(r3.tenant_id);
  delete from erp.tenant where id = r3.tenant_id;
  perform erp.end_tenant_purge();
end;
$$;

create or replace function erp_test.assert_provisioning_suite()
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  -- A suite that loses a case reports success. This is the guard against that,
  -- and it is why three isolation cases going missing was caught at all.
  c_expected constant integer := 18;
  v_total  integer;
  v_failed integer;
  v_detail text;
begin
  select count(*), count(*) filter (where not r.passed),
         string_agg(format('  %s — %s', r.case_name, r.detail), E'\n')
           filter (where not r.passed)
    into v_total, v_failed, v_detail
    from erp_test.provisioning_suite() r;

  if v_failed > 0 then
    raise exception E'ERPWARE_PROVISIONING_SUITE_FAILED: %/% case(s) failed\n%',
      v_failed, v_total, v_detail;
  end if;

  if v_total <> c_expected then
    raise exception
      'ERPWARE_PROVISIONING_SUITE_INCOMPLETE: expected % cases, ran %',
      c_expected, v_total
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;

  return format('provisioning: %s/%s cases passed', v_total, v_total);
end;
$$;

-- -----------------------------------------------------------------------------
-- The repair: two suites that could lose a case silently
-- -----------------------------------------------------------------------------

create or replace function erp_test.assert_stock_invariants()
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  c_expected constant integer := 20;
  v_total  integer;
  v_failed integer;
  v_detail text;
begin
  select count(*), count(*) filter (where not r.passed),
         string_agg(format('  %s — %s', r.case_name, r.detail), E'\n')
           filter (where not r.passed)
    into v_total, v_failed, v_detail
    from erp_test.stock_invariant_suite() r;

  if v_failed > 0 then
    raise exception E'ERPWARE_STOCK_INVARIANTS_FAILED: %/% case(s) failed\n%',
      v_failed, v_total, v_detail;
  end if;

  if v_total <> c_expected then
    raise exception
      'ERPWARE_STOCK_SUITE_INCOMPLETE: expected % cases, ran %', c_expected, v_total
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;

  return format('stock invariants: %s/%s cases passed', v_total, v_total);
end;
$$;

create or replace function erp_test.assert_gateway_suite()
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  c_expected constant integer := 49;
  v_total  integer;
  v_failed integer;
  v_detail text;
begin
  select count(*), count(*) filter (where not r.passed),
         string_agg(format('  %s — %s', r.case_name, r.detail), E'\n')
           filter (where not r.passed)
    into v_total, v_failed, v_detail
    from erp_test.gateway_suite() r;

  if v_failed > 0 then
    raise exception E'ERPWARE_GATEWAY_SUITE_FAILED: %/% case(s) failed\n%',
      v_failed, v_total, v_detail;
  end if;

  if v_total <> c_expected then
    raise exception
      'ERPWARE_GATEWAY_SUITE_INCOMPLETE: expected % cases, ran %', c_expected, v_total
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;

  return format('write gateway: %s/%s cases passed', v_total, v_total);
end;
$$;

select erp.assert_isolation();
