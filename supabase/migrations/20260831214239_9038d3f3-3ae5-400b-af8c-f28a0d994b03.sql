create or replace function erp.purge_due_tenants(p_grace interval default interval '7 days')
returns table(tenant_id uuid, code text, deleted_at timestamptz)
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  r record;
begin
  if p_grace < interval '0' then
    raise exception 'ERPWARE_VALIDATION: the grace period cannot be negative'
      using errcode = '22023';
  end if;

  for r in
    select t.id, t.code, t.deleted_at
      from erp.tenant t
     where t.deleted_at is not null
       and t.deleted_at < now() - p_grace
       and t.status in ('suspended'::erp.tenant_status, 'deleted'::erp.tenant_status)
     order by t.deleted_at
  loop
    insert into erp_meta.platform_audit
      (actor_email, actor_role, action, tenant_id, tenant_code, reason, detail)
    values
      ('system', 'platform', 'platform.tenant_purged', r.id, r.code,
       'grace period elapsed after a deletion request',
       jsonb_build_object('deleted_at', r.deleted_at, 'grace', p_grace::text));

    perform erp.begin_tenant_purge(r.id);
    delete from erp.tenant t where t.id = r.id;
    perform erp.end_tenant_purge();

    tenant_id := r.id; code := r.code; deleted_at := r.deleted_at;
    return next;
  end loop;
end $$;

comment on function erp.purge_due_tenants(interval) is
  'Purges every organisation whose deletion was requested longer ago than the grace '
  'period. Platform work, not tenant work: it is deliberately not an erp.job, '
  'because erp.job is tenant-scoped and a sweep scheduled that way would run '
  'under one organisation''s context while deleting others.';

create or replace function public.erp_platform_purge_due_tenants(
  p_grace_days integer default 7)
returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  v    erp_meta.platform_staff;
  v_rows jsonb;
begin
  v := erp_meta.require_platform('owner');

  if p_grace_days is null or p_grace_days < 0 then
    raise exception 'ERPWARE_VALIDATION: the grace period must be zero or more days'
      using errcode = '22023';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'tenant_id', p.tenant_id, 'code', p.code,
           'deleted_at', p.deleted_at) order by p.deleted_at), '[]'::jsonb)
    into v_rows
    from erp.purge_due_tenants(make_interval(days => p_grace_days)) p;

  return jsonb_build_object(
    'purged', jsonb_array_length(v_rows),
    'organisations', v_rows,
    'grace_days', p_grace_days);
end $$;

comment on function public.erp_platform_purge_due_tenants(integer) is
  'Runs the deletion sweep on demand. Nothing calls it on a schedule yet: no '
  'cron points at the dispatch function, which is deployment configuration '
  'outside this repository.';

revoke all on function public.erp_platform_purge_due_tenants(integer)
  from public, anon;
grant execute on function public.erp_platform_purge_due_tenants(integer)
  to authenticated;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_platform_purge_due_tenants', 'erp_meta.require_platform',
   'Runs the deletion sweep, removing every organisation whose deletion was '
   'requested longer ago than the grace period. Owner-gated on the platform '
   'staff list, because purging organisations is performed above every tenant and '
   'no tenant context could scope it.')
on conflict (function_name) do update
  set gate = excluded.gate, rationale = excluded.rationale;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('public', 'erp_platform_purge_due_tenants',
   'Definer for the same reason the single purge is: erp.begin_tenant_purge '
   'admits only a role that bypasses RLS, which is what current_user is inside '
   'a definer function owned by the schema owner. The caller stays '
   'authenticated and must clear erp_meta.require_platform(''owner'') first.'),
  ('erp', 'purge_due_tenants',
   'Opens a purge window per organisation and removes it. Reachable only through '
   'the owner-gated public door above, or by a trusted backend session.')
on conflict (schema_name, function_name) do update
  set rationale = excluded.rationale;

create or replace function erp_test.tenant_deletion_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path to ''
as $$
declare
  ra record; rb record; rc record; rd record; re record;
  ow uuid := gen_random_uuid();
  op uuid := gen_random_uuid();
  ad uuid := gen_random_uuid();
  v_ok boolean; v_msg text; res jsonb; v_audit bigint;
begin
  select * into ra from erp.provision_tenant(
    'zzpurge-a', 'Purge A', 'admin-a@zzpurge.test', 'Purge A Admin');
  select * into rb from erp.provision_tenant(
    'zzpurge-b', 'Purge B', 'admin-b@zzpurge.test', 'Purge B Admin');
  select * into rc from erp.provision_tenant(
    'zzpurge-c', 'Purge C', 'admin-c@zzpurge.test', 'Purge C Admin');
  select * into rd from erp.provision_tenant(
    'zzpurge-d', 'Purge D', 'admin-d@zzpurge.test', 'Purge D Admin');
  select * into re from erp.provision_tenant(
    'zzpurge-e', 'Purge E', 'admin-e@zzpurge.test', 'Purge E Admin');

  insert into auth.users (id, email) values
    (ow, 'owner@zzpurge.test'), (op, 'operator@zzpurge.test'),
    (ad, 'admin-b@zzpurge.test');

  insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
  values ('owner@zzpurge.test', ow, 'Purge Owner', 'owner'),
         ('operator@zzpurge.test', op, 'Purge Operator', 'operator');

  perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
  begin
    perform public.erp_platform_purge_tenant(ra.tenant_id, 'zzpurge-a', 'testing');
    v_ok := false; v_msg := 'an operator purged an organisation';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_PLATFORM_ROLE_TOO_LOW%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'an operator may not purge an organisation', v_ok, v_msg;

  begin
    perform public.erp_platform_purge_due_tenants(0);
    v_ok := false; v_msg := 'an operator ran the deletion sweep';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_PLATFORM_ROLE_TOO_LOW%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'nor run the sweep', v_ok, v_msg;

  perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);

  begin
    perform public.erp_platform_purge_tenant(ra.tenant_id, 'zzpurge-a', 'testing');
    v_ok := false; v_msg := 'an active organisation was purged in one step';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_TENANT_STILL_ACTIVE%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'and an active organisation is refused even to an owner',
    v_ok, v_msg;

  update erp.tenant set status = 'suspended'::erp.tenant_status
   where id = ra.tenant_id;

  begin
    perform public.erp_platform_purge_tenant(ra.tenant_id, 'zzpurge-WRONG', 'testing');
    v_ok := false; v_msg := 'a wrong confirmation code was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_VALIDATION%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'the organisation code must be typed exactly', v_ok, v_msg;

  begin
    perform public.erp_platform_purge_tenant(ra.tenant_id, 'zzpurge-a', '   ');
    v_ok := false; v_msg := 'a purge with no reason was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_REASON_REQUIRED%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'and a reason is required', v_ok, v_msg;

  res := public.erp_platform_purge_tenant(ra.tenant_id, 'zzpurge-a',
                                          'suite: proving deletion deletes');

  return query select 'an owner purges a suspended organisation',
    (res ->> 'purged')::boolean, coalesce(res ->> 'code', '(no code returned)');

  return query select 'and the organisation is actually gone',
    not exists (select 1 from erp.tenant t where t.id = ra.tenant_id),
    'the whole point: before this migration nothing in the product removed a row';

  return query select 'and nothing tenant-scoped survives it',
    not exists (select 1 from erp.app_user u    where u.tenant_id = ra.tenant_id)
      and not exists (select 1 from erp.environment e where e.tenant_id = ra.tenant_id)
      and not exists (select 1 from erp.change_set c where c.tenant_id = ra.tenant_id)
      and not exists (select 1 from erp.role r       where r.tenant_id = ra.tenant_id),
    'app_user, environment, change_set and role all follow the organisation';

  select count(*) into v_audit from erp_meta.platform_audit a
   where a.tenant_id = ra.tenant_id and a.action = 'platform.tenant_purged';
  return query select 'while the audit record outlives it',
    v_audit = 1,
    'erp_meta.platform_audit carries no foreign key to erp.tenant precisely so '
    'that the record of a deletion is not deleted by it';

  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  perform erp.claim_invitation(rb.admin_token);

  res := public.erp_request_tenant_deletion('zzpurge-b', 'suite: the request half');

  return query select 'an administrator''s request suspends rather than deletes',
    (select t.status::text from erp.tenant t where t.id = rb.tenant_id) = 'suspended'
      and exists (select 1 from erp.tenant t where t.id = rb.tenant_id),
    'the rows are still there, which is the honest outcome';

  return query select 'and it no longer promises a purge that never happens',
    (res ->> 'note') not like '%scheduled purge%',
    'the note said data "is removed by the scheduled purge"; no such purge '
    'existed, and an administrator reading that believed the organisation was on '
    'its way out';

  perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
  res := public.erp_platform_purge_tenant(rb.tenant_id, 'zzpurge-b',
                                          'suite: finishing what the request started');

  return query select 'an owner finishes what the request started',
    (res ->> 'purged')::boolean
      and not exists (select 1 from erp.tenant t where t.id = rb.tenant_id),
    'request then purge is the two-step, and both halves now exist';

  update erp.tenant set status = 'suspended'::erp.tenant_status,
         deleted_at = now() - interval '14 days' where id = rc.tenant_id;
  update erp.tenant set status = 'suspended'::erp.tenant_status,
         deleted_at = now() - interval '1 hour'  where id = rd.tenant_id;
  update erp.tenant set status = 'suspended'::erp.tenant_status,
         suspended_at = now(), deleted_at = null where id = re.tenant_id;

  res := public.erp_platform_purge_due_tenants(7);

  return query select 'the sweep takes an organisation past its grace period',
    (res ->> 'purged')::integer = 1
      and not exists (select 1 from erp.tenant t where t.id = rc.tenant_id),
    format('purged %s', res ->> 'purged');

  return query select 'and leaves one still inside it',
    exists (select 1 from erp.tenant t where t.id = rd.tenant_id),
    'deleted an hour ago against a seven-day grace: the window is the whole '
    'reason a mistaken request can be caught';

  return query select 'a suspension that was never a deletion request is not swept',
    exists (select 1 from erp.tenant t where t.id = re.tenant_id),
    'suspension sets suspended_at and leaves deleted_at null; only a request '
    'to be deleted sets that, and only that is swept';

  return query select 'and the sweep records each purge without an actor',
    exists (select 1 from erp_meta.platform_audit a
             where a.tenant_id = rc.tenant_id
               and a.action = 'platform.tenant_purged'
               and a.actor_email = 'system'),
    'the platform acted on somebody else''s request; naming whoever triggered '
    'the sweep would be a worse record than naming nobody';

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(rd.tenant_id);
  delete from erp.tenant where id = rd.tenant_id;
  perform erp.end_tenant_purge();
  perform erp.begin_tenant_purge(re.tenant_id);
  delete from erp.tenant where id = re.tenant_id;
  perform erp.end_tenant_purge();
  delete from erp_meta.platform_staff s where s.email like '%@zzpurge.test';
  delete from erp_meta.platform_audit a where a.tenant_code like 'zzpurge-%';
  delete from auth.users u where u.id in (ow, op, ad);

  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t
                 where t.code like 'zzpurge-%')
      and not exists (select 1 from erp_meta.platform_staff s
                       where s.email like '%@zzpurge.test')
      and not exists (select 1 from auth.users u where u.id in (ow, op, ad)),
    'five organisations, both staff rows and all three fabricated subjects';
end $$;

create or replace function erp_test.assert_tenant_deletion_suite()
returns text
language plpgsql
set search_path to ''
as $$
declare
  v_pass integer; v_total integer; v_detail text;
  c_expected constant integer := 17;
begin
  create temporary table if not exists zz_purge_result
    (case_name text, passed boolean, detail text) on commit drop;
  delete from zz_purge_result;
  insert into zz_purge_result select * from erp_test.tenant_deletion_suite();

  select count(*) filter (where passed), count(*),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_pass, v_total, v_detail from zz_purge_result;

  if v_total <> c_expected then
    raise exception 'ERPWARE_TENANT_DELETION_SUITE_INCOMPLETE: % cases, expected %',
      v_total, c_expected using errcode = 'P0001';
  end if;
  if v_pass < v_total then
    raise exception E'ERPWARE_TENANT_DELETION_SUITE_FAILED: %/%\n%',
      v_pass, v_total, v_detail using errcode = 'P0001';
  end if;

  return format('tenant deletion: %s/%s', v_pass, v_total);
end $$;

select erp.assert_public_api_safe();
select erp.assert_isolation();