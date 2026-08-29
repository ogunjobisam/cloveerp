-- =============================================================================
-- ERPWare — the tenant and principal context become transaction-local
-- Spec 2.2 (Enforcement), 3.8 ("Every query path, background job, export,
-- report and integration call runs inside a tenant context")
--
-- erp.set_job_tenant() and erp.set_job_principal() wrote their GUCs with
-- set_config(..., false) — session scope, not transaction scope. Everything
-- else in the codebase already got this right: the correlation id, the purge
-- window, the promotion id, the stock ledger's write flag and the isolation
-- suite's own tenant switch are all transaction-local. The two most
-- security-critical settings in the system were the exceptions.
--
-- Why it matters, concretely. A connection pooler in transaction mode hands the
-- same physical connection to unrelated requests between transactions. A
-- session-scoped tenant context set by one job is therefore still set when the
-- next request gets that connection, and row-level security will happily
-- enforce it — correctly, against the wrong tenant. The same exposure exists
-- with no pooler at all on any worker that reuses a connection across jobs and
-- forgets to clear.
--
-- This is the failure the whole build exists to prevent, and it is worth being
-- precise about its shape: not a missing policy, not a policy with a hole, but
-- a correct policy evaluating a stale context. No amount of reading the
-- policies would have found it.
--
-- The consequence of the fix is the behaviour spec 3.8 actually asks for: a
-- job declares its tenant inside the transaction that does the work, and a
-- transaction that never declared one has none. "Jobs without one cannot
-- start" stops being a slogan about startup and becomes true per transaction.
--
-- erp.assert_session_context_hygiene() then makes the rule permanent: no
-- function anywhere may write one of these GUCs session-wide.
-- =============================================================================

create or replace function erp.set_job_tenant(p_tenant_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if not erp.session_is_trusted() then
    raise exception 'ERPWARE_UNTRUSTED_CONTEXT_ASSERTION: role % may not assert a tenant context', current_user
      using errcode = '42501';
  end if;
  -- Transaction-local. The context ends when the transaction does, so it can
  -- never be inherited by whatever the pooler hands this connection to next.
  perform set_config('erp.job_tenant_id', p_tenant_id::text, true);
end;
$$;

comment on function erp.set_job_tenant(uuid) is
  'Declares the tenant scope of a trusted backend session, for the duration of '
  'the current transaction only. A job re-declares per transaction; one that '
  'does not has no tenant, which is spec 3.8 working rather than failing.';

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
    perform set_config('erp.job_principal_id', '', true);
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

  perform set_config('erp.job_principal_id', p_principal_id::text, true);
end;
$$;

comment on function erp.set_job_principal(uuid) is
  'Spec 2.4. Lets a trusted backend session act as a named service principal '
  'for the duration of the current transaction. Pass null to clear.';

-- -----------------------------------------------------------------------------
-- The rule, made permanent
-- -----------------------------------------------------------------------------

create or replace function erp.session_context_hygiene_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  select 'a context setter writes its GUC session-wide rather than '
         'transaction-locally',
         p.oid::regprocedure::text,
         'under a transaction-mode pooler the value outlives the request, and '
         'the next tenant served by this connection inherits it'
    from pg_catalog.pg_proc p
   where p.pronamespace::regnamespace::text in ('erp', 'erp_ref', 'erp_test')
     -- set_config('erp.<context guc>', <anything>, false)
     and p.prosrc ~ 'set_config\s*\(\s*''erp\.(job_tenant_id|job_principal_id|purge_tenant_id|promotion_id|correlation_id|ledger_write)''[^;]*,\s*false\s*\)'
   order by 2
$$;

comment on function erp.session_context_hygiene_report() is
  'Every GUC ERPWare uses to carry security or transaction context must be '
  'written transaction-locally. This reports any function that does not.';

create or replace function erp.assert_session_context_hygiene()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count  integer;
  v_detail text;
begin
  select count(*), string_agg(format('  %s — %s', reference, detail), E'\n')
    into v_count, v_detail
    from erp.session_context_hygiene_report();

  if v_count > 0 then
    raise exception 'ERPWARE_SESSION_CONTEXT_LEAK_RISK: % function(s)', v_count
      using errcode = 'P0001', detail = v_detail;
  end if;

  return '';
end;
$$;

-- -----------------------------------------------------------------------------
-- The runtime proof
--
-- A procedure rather than a function, because the property only exists either
-- side of a COMMIT and a function cannot commit. Run it on a connection with
-- autocommit — it is not callable from inside the test-suite functions, which
-- is the whole point: they run in one transaction and could never observe this.
-- -----------------------------------------------------------------------------

-- No `set search_path` clause, unlike every other routine here. PostgreSQL
-- refuses transaction control inside a routine that carries a SET clause, so a
-- procedure that must COMMIT cannot have one. Every identifier below is fully
-- schema-qualified instead, which is what the SET clause was buying anyway.
create or replace procedure erp_test.assert_context_not_leaked()
language plpgsql
as $$
declare
  v_tenant uuid;
  v_after  uuid;
begin
  insert into erp.tenant (code, name, status)
  values ('zz-leak-' || substr(gen_random_uuid()::text, 1, 8),
          'Context leak check', 'active')
  returning id into v_tenant;
  commit;

  perform erp.set_job_tenant(v_tenant);

  if erp.current_tenant_id() is distinct from v_tenant then
    raise exception
      'ERPWARE_CONTEXT_NOT_SET: the declaration did not take effect at all'
      using errcode = 'P0001';
  end if;

  commit;

  -- A new transaction on the same physical connection. This is exactly what a
  -- pooler hands to the next request.
  v_after := erp.current_tenant_id();

  if v_after is not null then
    raise exception
      'ERPWARE_CONTEXT_LEAKED: tenant % is still in scope after commit; the '
      'next request served by this connection would inherit it', v_after
      using errcode = '42501';
  end if;

  perform erp.begin_tenant_purge(v_tenant);
  delete from erp.tenant where id = v_tenant;
  perform erp.end_tenant_purge();
  commit;
end;
$$;

revoke all on procedure erp_test.assert_context_not_leaked()
  from public, anon, authenticated;

select erp.assert_session_context_hygiene();
select erp.assert_isolation();
