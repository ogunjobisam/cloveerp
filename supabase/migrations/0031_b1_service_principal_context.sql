-- =============================================================================
-- ERPWare — service principal context
-- Spec 2.4: "Authentication via the tenant's chosen identity provider; service
--            principals for integrations and jobs"
-- Spec 3.8: "Every query path, background job, export, report and integration
--            call runs inside a tenant context"
--
-- B1 modelled service principals and then made them unreachable. erp.app_user
-- carries kind = 'service', and a CHECK guarantees such a row has no
-- auth_user_id — which is correct, a service principal does not log in — but
-- erp.principal_context() resolves a principal only by auth_user_id. So a
-- service principal could exist and could be granted roles, and nothing could
-- ever be that principal.
--
-- The consequence surfaced in B8. A dispatch worker is a job. It runs on a
-- trusted backend role, declares its tenant with erp.set_job_tenant(), and then
-- calls erp.submit_command(), which authorises against a principal that does
-- not exist. Every write from a job was therefore either denied or, worse,
-- would have had to be granted to "no principal at all" — attributing every
-- automated action to nobody, in a system whose entire audit story rests on
-- knowing who did what.
--
-- So a trusted session may DECLARE a service principal, exactly as it declares
-- a tenant, subject to three restrictions checked at read time rather than only
-- at set time:
--
--   1. It must be kind = 'service'. A trusted session adopting a person is
--      impersonation, and the audit trail would say a named human did it.
--   2. It must be active. A disabled service account stops working immediately,
--      which is the entire point of disabling it.
--   3. It must belong to the session's declared tenant. Otherwise the job
--      context and the identity context could disagree, and the more permissive
--      of the two would win.
--
-- Checking at read time matters: erp.set_job_principal() validates and gives a
-- clear error, but a trusted role can call set_config() directly. The filter
-- inside erp.current_principal_id() is what actually enforces it.
-- =============================================================================

create or replace function erp.set_job_principal(p_principal_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid;
  u        erp.app_user%rowtype;
begin
  if not erp.session_is_trusted() then
    raise exception
      'ERPWARE_UNTRUSTED_CONTEXT_ASSERTION: role % may not assert a principal',
      current_user
      using errcode = '42501';
  end if;

  if p_principal_id is null then
    perform set_config('erp.job_principal_id', '', false);
    return;
  end if;

  v_tenant := erp.current_tenant_id();

  if v_tenant is null then
    raise exception
      'ERPWARE_NO_TENANT_CONTEXT: declare the tenant before the principal'
      using errcode = '42501';
  end if;

  select * into u from erp.app_user a where a.id = p_principal_id;

  if not found or u.tenant_id <> v_tenant then
    raise exception
      'ERPWARE_UNKNOWN_PRINCIPAL: % is not a principal of this tenant',
      p_principal_id
      using errcode = '42501';
  end if;

  if u.kind <> 'service' then
    raise exception
      'ERPWARE_NOT_A_SERVICE_PRINCIPAL: % is a %; a job may not act as a person',
      p_principal_id, u.kind
      using errcode = '42501';
  end if;

  if u.status <> 'active' then
    raise exception
      'ERPWARE_PRINCIPAL_NOT_ACTIVE: % is %', p_principal_id, u.status
      using errcode = '42501';
  end if;

  perform set_config('erp.job_principal_id', p_principal_id::text, false);
end;
$$;

comment on function erp.set_job_principal(uuid) is
  'Spec 2.4. Lets a trusted backend session act as a named service principal, '
  'so an automated action is attributed to something rather than to nobody. '
  'Pass null to clear.';

create or replace function erp.clear_job_principal()
returns void
language sql
set search_path = ''
as $$
  select erp.set_job_principal(null);
$$;

-- The read-time enforcement. An authenticated principal always wins: a real
-- session never falls through to the job declaration, so a declared principal
-- cannot shadow the person actually holding the session.
create or replace function erp.current_principal_id()
returns uuid
language sql
stable
set search_path = ''
as $$
  select coalesce(
    -- 1. An authenticated person or, in principle, any principal reachable by
    --    the JWT subject.
    (select pc.principal_id from erp.principal_context() pc),
    -- 2. A trusted backend session that has declared a service principal. The
    --    three restrictions are re-checked here because this, not
    --    erp.set_job_principal(), is what every caller actually goes through.
    case
      when erp.session_is_trusted() then (
        select a.id
          from erp.app_user a
         where a.id = nullif(current_setting('erp.job_principal_id', true), '')::uuid
           and a.kind = 'service'
           and a.status = 'active'
           and a.tenant_id = erp.current_tenant_id())
      else null
    end)
$$;

comment on function erp.current_principal_id() is
  'The acting principal: the authenticated one, or the service principal a '
  'trusted job session has declared. Never a person adopted by a job, never a '
  'principal from another tenant, never a disabled one.';
