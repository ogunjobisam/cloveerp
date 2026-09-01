-- =============================================================================
-- The superadmin console, part C — leaving actually leaves, and you can see
-- what an organisation is missing without going in
--
-- THE BUG
--
-- erp_platform_enter_tenant() is not an impersonation. It creates a real
-- erp.app_user row for the staff member's own auth.uid() and grants it the
-- tenant's administrator role — which erp.provision_tenant() seeds with every
-- permission in erp_ref.permission. That is a deliberate and audited design.
--
-- erp_platform_leave_tenant() sets the app_user to 'disabled' and deletes the
-- active-tenant preference. It does not touch the grant. So the unscoped
-- administrator role stays in erp.user_role for ever, and the next enter finds
-- it already there, flips the principal back to 'active' and skips the insert —
-- with no second audit line saying a grant was made, because none was.
--
-- Nobody has exercised this: there is no Leave button anywhere in the product.
-- The path existed and had never been walked, which is exactly the kind of code
-- that is wrong.
--
-- Revoking on the way out makes entering cost something again — the grant is
-- written each time, so the audit trail has one line per period of access
-- rather than one line for the first ever.
-- =============================================================================

create or replace function public.erp_platform_leave_tenant(p_tenant_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v        erp_meta.platform_staff;
  v_user   uuid;
  v_gone   integer := 0;
begin
  v := erp_meta.require_platform('support');

  perform set_config('erp.job_tenant_id', p_tenant_id::text, true);

  select u.id into v_user from erp.app_user u
   where u.tenant_id = p_tenant_id and u.auth_user_id = v.auth_user_id;

  if v_user is null then
    raise exception 'ERPWARE_NOT_IN_TENANT: you hold no principal in this organisation'
      using errcode = '23503';
  end if;

  update erp.app_user set status = 'disabled'
   where tenant_id = p_tenant_id and id = v_user;

  -- The half that was missing. Without it the grant outlives every departure
  -- and the next entry is free.
  delete from erp.user_role ur
   where ur.tenant_id = p_tenant_id
     and ur.app_user_id = v_user
     and ur.role_id in (select r.id from erp.role r
                         where r.tenant_id = p_tenant_id and r.code = 'administrator');
  get diagnostics v_gone = row_count;

  delete from erp_meta.principal_preference
   where auth_user_id = v.auth_user_id and active_tenant_id = p_tenant_id;

  perform erp_meta.platform_log(v, 'platform.tenant_left', p_tenant_id, null,
                                'Support access ended.',
                                jsonb_build_object('grants_revoked', v_gone));

  return jsonb_build_object('tenant_id', p_tenant_id, 'left', true,
                            'grants_revoked', v_gone);
end;
$$;

comment on function public.erp_platform_leave_tenant is
  'Ends platform support access to one organisation: disables the principal AND '
  'revokes the administrator grant, so a later entry has to make it again and be '
  'recorded doing so.';

-- ── Where am I, and what is each organisation missing ────────────────────────
--
-- Two questions the console could not answer. The first is why nobody ever
-- left: nothing showed you were in. The second is why installing a module on a
-- customer meant entering it to find out whether it needed one.

create or replace function public.erp_platform_my_tenancies()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v erp_meta.platform_staff;
begin
  v := erp_meta.require_platform('support');

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'tenant_id', t.id, 'code', t.code, 'name', t.name,
             'status', t.status::text,
             'principal_status', u.status::text,
             'is_active', u.status = 'active',
             'holds_administrator', exists (
               select 1 from erp.user_role ur
                 join erp.role r on r.id = ur.role_id
                where ur.tenant_id = t.id and ur.app_user_id = u.id
                  and r.code = 'administrator'),
             'entered_at', u.created_at,
             'is_current', exists (
               select 1 from erp_meta.principal_preference pp
                where pp.auth_user_id = v.auth_user_id
                  and pp.active_tenant_id = t.id))
           order by t.code)
      from erp.app_user u
      join erp.tenant t on t.id = u.tenant_id
     where u.auth_user_id = v.auth_user_id), '[]'::jsonb);
end;
$$;

comment on function public.erp_platform_my_tenancies is
  'Every organisation this staff member holds a principal in, active or '
  'disabled, and whether the administrator grant is still there. A disabled '
  'principal that still holds the grant is what leaving used to leave behind.';

create or replace function public.erp_platform_tenant_configuration()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v erp_meta.platform_staff;
begin
  v := erp_meta.require_platform('support');

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'tenant_id', t.id, 'code', t.code, 'name', t.name,
             'status', t.status::text,
             'is_live', coalesce((select e.is_live from erp.environment e
                                   where e.tenant_id = t.id and e.is_self), false),
             'has_self_environment', exists (
               select 1 from erp.environment e where e.tenant_id = t.id and e.is_self),
             'entities',       (select count(*) from erp.entity x where x.tenant_id = t.id and x.status = 'active'),
             'sites',          (select count(*) from erp.site x where x.tenant_id = t.id and x.status = 'active'),
             'principals',     (select count(*) from erp.app_user x where x.tenant_id = t.id and x.status = 'active'),
             'ledgers',        (select count(*) from erp.ledger x where x.tenant_id = t.id and x.status = 'active'),
             'accounts',       (select count(*) from erp.account x where x.tenant_id = t.id and x.status = 'active'),
             'document_types', (select count(*) from erp.document_type x where x.tenant_id = t.id and x.status = 'active'),
             'posting_rules',  (select count(*) from erp.posting_rule x where x.tenant_id = t.id and x.status = 'active'),
             'jobs',           (select count(*) from erp.job x where x.tenant_id = t.id),
             -- The question that would have answered "does demo-649cd12e have
             -- master data?" without entering it to look.
             'modules_installed', coalesce((
               select jsonb_agg(distinct cs.code order by cs.code)
                 from erp.change_set cs
                where cs.tenant_id = t.id and cs.status = 'promoted'), '[]'::jsonb),
             'change_sets_awaiting', (
               select count(*) from erp.change_set cs
                where cs.tenant_id = t.id and cs.status in ('ready', 'approved')),
             'determination_findings', (
               select count(*) from erp.determination_coverage_report(t.id)))
           order by t.code)
      from erp.tenant t
     where t.status <> 'deleted'), '[]'::jsonb);
end;
$$;

comment on function public.erp_platform_tenant_configuration is
  'What each organisation actually has, so the console can say which one is '
  'missing a module rather than requiring somebody to enter it and look.';

do $$
declare f text;
begin
  foreach f in array array[
    'public.erp_platform_my_tenancies()',
    'public.erp_platform_tenant_configuration()'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale)
select 'public', fn,
       'Platform-level read across every organisation. It exists precisely to '
       'act above tenants, so no tenant context can scope it; gated on '
       'erp_meta.require_platform().'
  from unnest(array['erp_platform_my_tenancies',
                    'erp_platform_tenant_configuration']) fn
on conflict do nothing;

insert into erp_meta.public_write_allowance (function_name, gate, rationale)
select fn, 'erp_meta.require_platform',
       'Platform staff read, volatile only because its gate binds the caller''s '
       'identity on first use.'
  from unnest(array['erp_platform_my_tenancies',
                    'erp_platform_tenant_configuration']) fn
on conflict (function_name) do update set gate = excluded.gate,
                                          rationale = excluded.rationale;

-- ── Prove it ─────────────────────────────────────────────────────────────────

select erp.assert_public_api_safe();
select erp.assert_isolation();
select erp.assert_diagnostics_registered();
