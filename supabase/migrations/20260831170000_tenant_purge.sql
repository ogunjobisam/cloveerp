-- A deletion that deletes.
--
-- Two things in this product offered to delete an organisation and neither removed a
-- single row.
--
--   public.erp_request_tenant_deletion suspends the organisation, destroys its
--   encryption keys irreversibly, and returns a note promising that "remaining
--   operational data is removed by the scheduled purge".
--
--   public.erp_platform_set_tenant_status(..., 'deleted') sets status and
--   deleted_at. That is a label. It removes nothing.
--
-- There is no scheduled purge. erp_ref.job_handler has never held a row, no
-- function anywhere creates an erp.job, and so erp.claim_job_runs has never
-- returned a run. erp.assert_scheduler_integrity() passes because it has
-- nothing to judge.
--
-- The result is the worst state available: the keys are destroyed, so whatever
-- was encrypted under them is already unreadable, and every row stays. An
-- organisation in that state cannot be finished by anyone using the product.
--
-- The one mechanism that does remove an organisation is the purge window in
-- erp.begin_tenant_purge, and erp.session_is_trusted() restricts it to a role
-- that bypasses RLS — which no signed-in caller ever is. So it was reachable
-- from a backend session and from no screen.
--
-- This migration gives that mechanism a door. SECURITY DEFINER is what makes
-- it legitimate rather than a loosening: inside the function current_user is
-- the owner, which is precisely what session_is_trusted() asks about, while
-- the caller remains `authenticated` throughout and is checked against the
-- platform staff list first.

-- ── The purge ────────────────────────────────────────────────────────────────

create or replace function public.erp_platform_purge_tenant(
  p_tenant_id uuid, p_confirm_code text, p_reason text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v      erp_meta.platform_staff;
  v_t    erp.tenant;
  v_gone integer;
begin
  -- Owner, not operator. This matches erp_platform_set_tenant_status, which
  -- already draws the line in the same place: an operator may suspend an
  -- organisation, only an owner may end one.
  v := erp_meta.require_platform('owner');

  select * into v_t from erp.tenant where id = p_tenant_id;
  if v_t.id is null then
    raise exception 'ERPWARE_UNKNOWN_TENANT' using errcode = '23503';
  end if;

  -- Purging is the second half of a two-step, and refusing an active organisation
  -- is what makes it one. Suspension is the reversible half; it is also the
  -- half somebody else has a chance to notice.
  if v_t.status = 'active'::erp.tenant_status then
    raise exception
      'ERPWARE_TENANT_STILL_ACTIVE: % is active; an organisation is suspended before '
      'it is purged', v_t.code
      using errcode = '42501',
            hint = 'Suspend it first, or let its administrator request '
                   'deletion, and purge it afterwards.';
  end if;

  if v_t.code is distinct from btrim(coalesce(p_confirm_code, '')) then
    raise exception
      'ERPWARE_VALIDATION: the organisation code must be typed exactly to confirm '
      'the purge'
      using errcode = '22023';
  end if;

  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'ERPWARE_REASON_REQUIRED: purging an organisation needs a reason'
      using errcode = '22023';
  end if;

  -- Recorded before the rows go, for two reasons: erp_meta.platform_log reads
  -- the code back out of erp.tenant, and there is deliberately no foreign key
  -- from erp_meta.platform_audit to erp.tenant — so this record survives the
  -- organisation it describes, which is the only version of the audit worth having.
  perform erp_meta.platform_log(
    v, 'platform.tenant_purged', p_tenant_id, v_t.code, p_reason,
    jsonb_build_object('status_before', v_t.status::text,
                       'deleted_at', v_t.deleted_at));

  -- The one window in which append-only rows may be removed. It takes the
  -- whole organisation or nothing: erp.forbid_mutation() matches the window against
  -- old.tenant_id row by row, so it can never be used to remove one
  -- inconvenient record.
  perform erp.begin_tenant_purge(p_tenant_id);
  delete from erp.tenant where id = p_tenant_id;
  get diagnostics v_gone = row_count;
  perform erp.end_tenant_purge();

  -- Belt and braces. A cascade that quietly removed nothing, or somehow more
  -- than one organisation, should not return success.
  if v_gone <> 1 then
    raise exception
      'ERPWARE_PURGE_INCOMPLETE: expected to remove one organisation, removed %',
      v_gone
      using errcode = 'P0001';
  end if;

  return jsonb_build_object(
    'tenant_id', p_tenant_id,
    'code', v_t.code,
    'purged', true,
    'note', 'Every row belonging to this organisation has been removed. The '
            'platform audit record of the purge remains, deliberately.');
end $$;

comment on function public.erp_platform_purge_tenant(uuid, text, text) is
  'Removes a suspended or ended organisation and everything belonging to it. The '
  'only door onto erp.begin_tenant_purge, owner-gated, and refused on an '
  'organisation that is still active.';

revoke all on function public.erp_platform_purge_tenant(uuid, text, text)
  from public, anon;
grant execute on function public.erp_platform_purge_tenant(uuid, text, text)
  to authenticated;

-- ── Stop the other door claiming something untrue ────────────────────────────
--
-- The body is unchanged except for the closing note. Until a scheduled purge
-- exists, saying one will happen is the part that misleads: an administrator
-- reads it, believes the organisation is on its way out, and it never is.

create or replace function public.erp_request_tenant_deletion(p_confirm_code text, p_reason text)
returns jsonb
language plpgsql
set search_path to ''
as $$
declare v_tenant uuid; v_code text; v_overrides integer; v_keys integer;
begin
  perform erp.authorise('administration.configure');
  v_tenant := erp.current_tenant_id();

  select t.code into v_code from erp.tenant t where t.id = v_tenant;
  if v_code is distinct from btrim(coalesce(p_confirm_code, '')) then
    raise exception 'ERPWARE_VALIDATION: the organisation code must be typed exactly to confirm deletion';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'ERPWARE_VALIDATION: a reason is required';
  end if;

  update erp.tenant t
     set status = 'suspended'::erp.tenant_status,
         suspended_at = now(),
         deleted_at = now(),
         retention_policy = coalesce(t.retention_policy, '{}'::jsonb)
                            || jsonb_build_object('deletion_requested_by', erp.current_principal_id(),
                                                  'deletion_requested_at', now(),
                                                  'deletion_reason', p_reason),
         updated_at = now(), updated_by = erp.current_principal_id()
   where t.id = v_tenant;

  delete from erp.resource_override o where o.tenant_id = v_tenant;
  get diagnostics v_overrides = row_count;

  v_keys := erp.destroy_tenant_keys('organisation deletion: ' || btrim(p_reason));

  return jsonb_build_object('tenant_id', v_tenant, 'status', 'suspended',
                            'overrides_destroyed', v_overrides,
                            'keys_destroyed', v_keys,
                            'note', 'This organisation is suspended and its encryption keys have been '
                                    'destroyed immediately and irreversibly, so anything encrypted '
                                    'under them is already unreadable. Its remaining rows are still '
                                    'here: removing them is a separate, deliberate step performed by '
                                    'a platform owner.');
end $$;

-- ── The registers ────────────────────────────────────────────────────────────
--
-- Both are required. erp.public_api_report() refuses a public SECURITY DEFINER
-- function that is not registered, and separately refuses a VOLATILE public
-- function that is not on the write allow-list with a gate its body actually
-- calls. erp.assert_public_api_safe() at the tail is what proves it.

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_platform_purge_tenant', 'erp_meta.require_platform',
   'Removes an organisation and everything belonging to it. Gated on the platform '
   'staff list at owner rank rather than on erp.authorise(), because it is '
   'performed above every tenant and no tenant context could scope it. Refuses '
   'an active organisation, demands its code typed exactly and a stated reason, and '
   'records the purge in erp_meta.platform_audit before the rows go.')
on conflict (function_name) do update
  set gate = excluded.gate, rationale = excluded.rationale;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('public', 'erp_platform_purge_tenant',
   'Definer is the mechanism, not a shortcut: erp.begin_tenant_purge admits '
   'only a role that bypasses RLS, and inside a definer function owned by the '
   'schema owner that is what current_user is. The caller stays authenticated '
   'and is checked against erp_meta.require_platform(''owner'') first.')
on conflict (schema_name, function_name) do update
  set rationale = excluded.rationale;

-- ── The suite ────────────────────────────────────────────────────────────────
--
-- Both halves of the two-step, and every refusal that makes it a two-step
-- rather than a button. The refusals matter more than the success: a purge
-- that an operator could reach, or that took an active organisation, would be a
-- worse product than one that deletes nothing.

create or replace function erp_test.tenant_deletion_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path to ''
as $$
declare
  ra record; rb record;
  ow uuid := gen_random_uuid();   -- platform owner
  op uuid := gen_random_uuid();   -- platform operator
  ad uuid := gen_random_uuid();   -- tenant administrator, organisation B
  v_ok boolean; v_msg text; res jsonb; v_audit bigint;
begin
  select * into ra from erp.provision_tenant(
    'zzpurge-a', 'Purge A', 'admin-a@zzpurge.test', 'Purge A Admin');
  select * into rb from erp.provision_tenant(
    'zzpurge-b', 'Purge B', 'admin-b@zzpurge.test', 'Purge B Admin');

  insert into auth.users (id, email) values
    (ow, 'owner@zzpurge.test'), (op, 'operator@zzpurge.test'),
    (ad, 'admin-b@zzpurge.test');

  -- Inserted rather than claimed. erp_platform_claim_ownership() is a one-time
  -- bootstrap and refuses once any staff row exists, so a suite that used it
  -- would pass or fail on what ran before it.
  insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
  values ('owner@zzpurge.test', ow, 'Purge Owner', 'owner'),
         ('operator@zzpurge.test', op, 'Purge Operator', 'operator');

  -- ---------------------------------------------------------------------
  -- The refusals
  -- ---------------------------------------------------------------------

  perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
  begin
    perform public.erp_platform_purge_tenant(ra.tenant_id, 'zzpurge-a', 'testing');
    v_ok := false; v_msg := 'an operator purged an organisation';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_PLATFORM_ROLE_TOO_LOW%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'an operator may not purge an organisation', v_ok, v_msg;

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

  -- ---------------------------------------------------------------------
  -- The purge itself
  -- ---------------------------------------------------------------------

  res := public.erp_platform_purge_tenant(ra.tenant_id, 'zzpurge-a',
                                          'suite: proving deletion deletes');

  return query select 'an owner purges a suspended organisation',
    (res ->> 'purged')::boolean, coalesce(res ->> 'code', '(no code returned)');

  return query select 'and the organisation is actually gone',
    not exists (select 1 from erp.tenant t where t.id = ra.tenant_id),
    'the whole point: before this migration nothing in the product removed a row';

  -- The tables an organisation is made of. If a cascade were missing, the delete
  -- above would have raised rather than left an orphan — but asserting it
  -- states what "purged" is supposed to mean.
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

  -- ---------------------------------------------------------------------
  -- The other half: what an administrator can start, and cannot finish
  -- ---------------------------------------------------------------------

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
    'exists, and an administrator reading that believed the organisation was on its '
    'way out';

  perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
  res := public.erp_platform_purge_tenant(rb.tenant_id, 'zzpurge-b',
                                          'suite: finishing what the request started');

  return query select 'an owner finishes what the request started',
    (res ->> 'purged')::boolean
      and not exists (select 1 from erp.tenant t where t.id = rb.tenant_id),
    'request then purge is the two-step, and both halves now exist';

  -- ---------------------------------------------------------------------

  perform set_config('request.jwt.claims', '', true);
  delete from erp_meta.platform_staff s where s.email like '%@zzpurge.test';
  delete from erp_meta.platform_audit a where a.tenant_code like 'zzpurge-%';
  delete from auth.users u where u.id in (ow, op, ad);

  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t
                 where t.id in (ra.tenant_id, rb.tenant_id))
      and not exists (select 1 from erp_meta.platform_staff s
                       where s.email like '%@zzpurge.test')
      and not exists (select 1 from auth.users u where u.id in (ow, op, ad)),
    'both organisations, both staff rows and all three fabricated subjects';
end $$;

create or replace function erp_test.assert_tenant_deletion_suite()
returns text
language plpgsql
set search_path to ''
as $$
declare
  v_pass integer; v_total integer; v_detail text;
  -- Four refusals, five on the purge itself, two on the request half, and the
  -- cleanup.
  c_expected constant integer := 12;
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

-- ── Prove it ─────────────────────────────────────────────────────────────────

select erp.assert_public_api_safe();
select erp.assert_isolation();
select erp.assert_transaction_control_routines();
