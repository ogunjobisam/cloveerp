-- =============================================================================
-- A large organisation is purged whole
--
-- On 14 September the owner purged demo-30536bd8, a suspended demonstration
-- organisation with a month of documents in it, and the console answered
-- "That took too long. Try a narrower selection." Twice. The live log says why:
-- both calls were cancelled by the eight-second statement timeout every
-- signed-in request carries, once while the cascade was emptying erp.access_log
-- and once in erp.state_transition_log. Every row of an append-only stream is
-- checked by erp.forbid_mutation() on its way out, which is the guard doing its
-- job, and a month of demonstration activity is simply more rows than eight
-- seconds removes. Nothing was lost: a cancelled statement takes its
-- transaction with it, so the organisation is whole and still suspended.
--
-- Three changes, and one thing deliberately not done:
--
--   * Both purge doors get the fifty-five seconds erp_platform_assurance has
--     had since 20260902121206. PostgREST applies a function's own
--     statement_timeout to the call, and sixty seconds is the most a request
--     through the API is given.
--   * If an organisation is too large even for that, the door says so in the
--     product's words, CLOVEERP_PURGE_TOO_LARGE, instead of a timeout message
--     that suggests a narrower selection where there is no selection. Nothing
--     was removed, and the refusal says how to finish it.
--   * erp.purge_organisation() is that way: the same purge, for a direct
--     database session with no request limit, recorded in the platform log
--     with the person and reason given.
--
--   Not done: purging in slices across several calls. A half-purged
--   organisation would be an organisation whose documents have lost their
--   history, which every check that reads a stream would then report; a
--   purge that either happens or does not is worth more than one that is
--   always quick.
-- =============================================================================

-- ── The door says what happened when it runs out of time ────────────────────

do $purge$
declare
  v_sig    constant text := 'public.erp_platform_purge_tenant(uuid, text, text)';
  v_def    text := pg_get_functiondef('public.erp_platform_purge_tenant(uuid, text, text)'::regprocedure);
  v_needle constant text := $n$  perform erp.begin_tenant_purge(p_tenant_id);
  delete from erp.tenant where id = p_tenant_id;
  get diagnostics v_gone = row_count;
  perform erp.end_tenant_purge();$n$;
  v_new    constant text := $n$  -- A purge happens whole or not at all (20260914085000). Cancelled for
  -- time, the subtransaction takes every removed row back with it, and the
  -- refusal says so rather than suggesting a narrower selection.
  begin
    perform erp.begin_tenant_purge(p_tenant_id);
    delete from erp.tenant where id = p_tenant_id;
    get diagnostics v_gone = row_count;
    perform erp.end_tenant_purge();
  exception when query_canceled then
    raise exception
      'CLOVEERP_PURGE_TOO_LARGE: % has more rows than one request may remove; nothing was removed', v_t.code
      using errcode = '54000',
            hint = 'Run erp.purge_organisation(code, your email, reason) from a direct database session, '
                   'where no request limit applies. The organisation is unchanged until then.';
  end;$n$;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not open, empty and close the purge exactly once as 20260831214133 wrote it', v_sig;
  end if;
  execute replace(v_def, v_needle, v_new);
end
$purge$;

alter function public.erp_platform_purge_tenant(uuid, text, text) set statement_timeout = '55s';
alter function public.erp_platform_purge_due_tenants(integer) set statement_timeout = '55s';

select erp.register_refusal('CLOVEERP_PURGE_TOO_LARGE',
  'Purging an organisation with more rows than one request can remove in its time.',
  'A purge happens whole or not at all. A half-purged organisation would leave documents without their history, so a purge that runs out of time removes nothing.',
  'Run erp.purge_organisation(code, your email, reason) from a direct database session, where no request limit applies.');

-- ── The same purge, from a direct session ────────────────────────────────────

create or replace function erp.purge_organisation(p_code text, p_actor_email text, p_reason text)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_t    erp.tenant;
  v_gone integer;
begin
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_PURGE: role % may not purge an organisation', current_user
      using errcode = '42501',
            hint = 'Purge from the console, or from a direct database session as the owner of the schema.';
  end if;

  select * into v_t from erp.tenant t where t.code = btrim(coalesce(p_code, ''));
  if v_t.id is null then
    raise exception 'CLOVEERP_UNKNOWN_TENANT: no organisation has the code %', p_code
      using errcode = '23503',
            hint = 'Organisation codes are listed under Customers in the platform console.';
  end if;

  if v_t.status = 'active'::erp.tenant_status then
    raise exception
      'CLOVEERP_TENANT_STILL_ACTIVE: % is active; an organisation is suspended before it is purged', v_t.code
      using errcode = '42501',
            hint = 'Suspend it first, or let its administrator request deletion, and purge it afterwards.';
  end if;

  if coalesce(btrim(p_actor_email), '') = '' or coalesce(btrim(p_reason), '') = '' then
    raise exception 'CLOVEERP_REASON_REQUIRED: purging an organisation needs the name of who is doing it and why'
      using errcode = '22023',
            hint = 'Give your email address and a reason; both are kept in the platform log.';
  end if;

  insert into erp_meta.platform_audit
    (actor_email, actor_role, action, tenant_id, tenant_code, reason, detail)
  values
    (btrim(p_actor_email), 'direct session', 'platform.tenant_purged', v_t.id, v_t.code, btrim(p_reason),
     jsonb_build_object('status_before', v_t.status::text, 'deleted_at', v_t.deleted_at,
                        'route', 'erp.purge_organisation', 'database_role', current_user));

  perform erp.begin_tenant_purge(v_t.id);
  delete from erp.tenant t where t.id = v_t.id;
  get diagnostics v_gone = row_count;
  perform erp.end_tenant_purge();

  if v_gone <> 1 then
    raise exception 'CLOVEERP_PURGE_INCOMPLETE: expected to remove one organisation, removed %', v_gone
      using errcode = 'P0001',
            hint = 'Nothing was committed. Read the organisation list again before trying once more.';
  end if;

  return jsonb_build_object('tenant_id', v_t.id, 'code', v_t.code, 'purged', true);
end;
$$;

revoke all on function erp.purge_organisation(text, text, text) from public, anon, authenticated;

comment on function erp.purge_organisation(text, text, text) is
  'Removes a suspended or ended organisation and everything belonging to it, '
  'from a direct database session where no request limit applies. The route '
  'CLOVEERP_PURGE_TOO_LARGE names; recorded in erp_meta.platform_audit with the '
  'person and reason given. Refused to any role that does not bypass row security.';

-- ── The suite ────────────────────────────────────────────────────────────────

create or replace function erp_test.large_purge_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  ra record; rb record;
  v_code_a text := 'zzlpa-' || substr(md5(random()::text), 1, 6);
  v_code_b text := 'zzlpb-' || substr(md5(random()::text), 1, 6);
  v_ok boolean; v_msg text; res jsonb;
begin
  return query select 'both purge doors have the time an API request may be given',
    (select 'statement_timeout=55s' = any(coalesce(p.proconfig, '{}'))
       from pg_catalog.pg_proc p where p.oid = 'public.erp_platform_purge_tenant(uuid,text,text)'::regprocedure)
    and (select 'statement_timeout=55s' = any(coalesce(p.proconfig, '{}'))
           from pg_catalog.pg_proc p where p.oid = 'public.erp_platform_purge_due_tenants(integer)'::regprocedure),
    'statement_timeout=55s on erp_platform_purge_tenant and erp_platform_purge_due_tenants';

  return query select 'a purge cancelled for time is refused in the product''s words',
    (select p.prosrc ~ 'exception\s+when\s+query_canceled\s+then\s+raise\s+exception\s+''CLOVEERP_PURGE_TOO_LARGE'
       from pg_catalog.pg_proc p where p.oid = 'public.erp_platform_purge_tenant(uuid,text,text)'::regprocedure),
    'query_canceled becomes CLOVEERP_PURGE_TOO_LARGE inside its own subtransaction';

  select * into ra from erp.provision_tenant(v_code_a, 'Large Purge A', 'admin@zzlpa.test', 'Purge Admin');
  select * into rb from erp.provision_tenant(v_code_b, 'Large Purge B', 'admin@zzlpb.test', 'Purge Admin');

  begin
    perform erp.purge_organisation(v_code_a, 'owner@zzlp.test', 'suite: an active organisation');
    v_ok := false; v_msg := 'an active organisation was purged from a direct session';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_TENANT_STILL_ACTIVE%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a direct session may not purge an active organisation either', v_ok, v_msg;

  update erp.tenant set status = 'suspended'::erp.tenant_status, suspended_at = now() where id = ra.tenant_id;

  begin
    perform erp.purge_organisation(v_code_a, 'owner@zzlp.test', '  ');
    v_ok := false; v_msg := 'a purge with no reason was accepted';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_REASON_REQUIRED%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'and says who and why', v_ok, v_msg;

  res := erp.purge_organisation(v_code_a, 'owner@zzlp.test', 'suite: a large purge finished directly');
  return query select 'a direct session purges a suspended organisation whole',
    (res ->> 'purged')::boolean
    and not exists (select 1 from erp.tenant t where t.id = ra.tenant_id)
    and not exists (select 1 from erp.app_user u where u.tenant_id = ra.tenant_id)
    and exists (select 1 from erp.tenant t where t.id = rb.tenant_id),
    'the organisation and its people gone; the one beside it untouched';

  return query select 'and the platform log names who did it, why, and by which route',
    exists (select 1 from erp_meta.platform_audit a
             where a.tenant_id = ra.tenant_id and a.action = 'platform.tenant_purged'
               and a.actor_email = 'owner@zzlp.test' and a.reason = 'suite: a large purge finished directly'
               and a.detail ->> 'route' = 'erp.purge_organisation'),
    'platform.tenant_purged, route erp.purge_organisation';

  -- ── Clean up ─────────────────────────────────────────────────────────────

  perform erp.begin_tenant_purge(rb.tenant_id);
  delete from erp.tenant where id = rb.tenant_id;
  perform erp.end_tenant_purge();
  return query select 'the suite leaves no organisation behind',
    not exists (select 1 from erp.tenant t where t.id in (ra.tenant_id, rb.tenant_id)),
    'both organisations gone';
end;
$$;

revoke all on function erp_test.large_purge_suite() from public, anon;

create or replace function erp_test.assert_large_purge_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _large_purge_result on commit drop as
    select * from erp_test.large_purge_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_total, v_passed, v_detail
    from _large_purge_result;
  if v_total <> 7 then
    raise exception 'CLOVEERP_SUITE_SHRANK: large_purge_suite ran % cases, expected 7', v_total;
  end if;
  if v_passed < v_total then
    raise exception E'CLOVEERP_LARGE_PURGE_SUITE_FAILED: %/%\n%', v_passed, v_total, v_detail
      using errcode = 'P0001';
  end if;
  return format('large purge: %s/%s', v_passed, v_total);
end;
$$;

revoke all on function erp_test.assert_large_purge_suite() from public, anon;

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
select erp.assert_refusals_name_next_action();
select erp.assert_resource_coverage('en');
select erp_test.assert_large_purge_suite();
