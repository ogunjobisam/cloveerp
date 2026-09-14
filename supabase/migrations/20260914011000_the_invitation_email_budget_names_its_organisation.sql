-- The invitation email budget names its organisation before it writes.
--
-- On 14 September the first invitation sent through the invite Edge Function
-- on live made its invitation and then emailed nobody. The function's log
-- said why:
--
--   invite: the email budget could not be claimed:
--   CLOVEERP_NO_TENANT_CONTEXT: operation attempted outside a tenant context
--
-- erp.claim_invitation_email() (20260913120000) is trusted-only and resolves
-- the organisation itself, from the person the door just invited. It then asks
-- erp.tenant_is_live(t.id) of that organisation and of others, and the row
-- that ends the claim is a write to erp.invitation_email_log, a tenant table
-- whose guards ask erp.require_tenant_id() which organisation is writing.
-- tenant_is_live(p) filters on coalesce(p, erp.require_tenant_id()), and the
-- planner, estimating that filter before it knows p, evaluates the stable
-- fallback: so the question is asked, and refused, on a connection that names
-- no organisation, even though p is given. The invite function calls over its
-- own database connection, which names none.
--
-- A first version of this file (20260914010000, never merged) declared the
-- organisation only before the write. Its own suite refused on the earlier
-- read, which is how the planner's part was found.
--
-- The suites never saw it: their fixtures declare the organisation with
-- erp.set_job_tenant() before they claim, so every claim they made already
-- had the context the function's never does.
--
-- So the claim declares the organisation as soon as it has resolved it and
-- found an invitation to email, before any read that could ask, with
-- erp.set_job_tenant(): transaction-local, trusted-only, the same declaration
-- the drain makes for an organisation it serves. The suite below claims the
-- way the function does, with no organisation, no principal and no signed-in
-- caller, and also asks the two reads the function makes in that same state.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The claim declares its organisation as soon as it knows it
-- ═════════════════════════════════════════════════════════════════════════════

do $claim$
declare
  v_sig    text := 'erp.claim_invitation_email(uuid,text,uuid)';
  v_def    text := pg_get_functiondef('erp.claim_invitation_email(uuid,text,uuid)'::regprocedure);
  v_needle text := E'  if v_pending is null then\n    return query select false, \'no such invitation\'::text;\n    return;\n  end if;\n';
  v_new    text;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not answer ''no such invitation'' exactly once, so it is not the 20260913120000 body', v_sig;
  end if;
  if position('set_job_tenant' in v_def) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % already declares its organisation', v_sig;
  end if;
  v_new := replace(v_def, v_needle, v_needle ||
    E'\n  -- Named before anything below reads. erp.tenant_is_live() falls back to\n'
 || E'  -- the organisation in context, the planner evaluates that fallback while\n'
 || E'  -- estimating even when an organisation is passed, and the log row is a\n'
 || E'  -- tenant table''s write. The invite function''s connection names none, so\n'
 || E'  -- the claim names this one, for this transaction only.\n'
 || E'  perform erp.set_job_tenant(v_tenant);\n');
  execute v_new;
  if position('perform erp.set_job_tenant(v_tenant);' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % was re-emitted without its organisation', v_sig;
  end if;
end
$claim$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. A suite that calls from where the invite function calls
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.invitation_email_bare_connection_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_code     text := 'zz-bare-' || substr(md5(gen_random_uuid()::text), 1, 8);
  r          record;
  v_state    text;
  v_allowed  boolean;
  v_reason   text;
  v_logged   integer;
  v_log_ok   boolean;
  v_again    boolean;
  v_again_reason text;
  v_found    integer;
  v_bound    boolean;
begin
  begin
    select * into r from erp.provision_tenant(v_code, 'Bare connection suite', 'admin@' || v_code || '.test', 'Bare Admin');

    -- The invite function's connection: no organisation, no principal, nobody
    -- signed in.
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('erp.job_principal_id', '', true);
    perform set_config('request.jwt.claims', '', true);

    select c.allowed, c.reason into v_allowed, v_reason
      from erp.claim_invitation_email(r.admin_user_id, 'invite', null) c;
    select count(*), coalesce(bool_and(l.tenant_id = r.tenant_id and l.app_user_id = r.admin_user_id
                                       and l.email_lower = 'admin@' || v_code || '.test' and l.kind = 'invite'), false)
      into v_logged, v_log_ok
      from erp.invitation_email_log l where l.app_user_id = r.admin_user_id;

    -- Straight back to the bare connection, then a second claim for the same
    -- address inside ten minutes.
    perform set_config('erp.job_tenant_id', '', true);
    select c.allowed, c.reason into v_again, v_again_reason
      from erp.claim_invitation_email(r.admin_user_id, 'resend', null) c;

    perform set_config('erp.job_tenant_id', '', true);
    select count(*) into v_found from erp.invitation_for_resend(r.admin_token);
    v_bound := erp.auth_identity_is_bound(gen_random_uuid());

    raise exception 'ZZ_BARE_CONNECTION_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'ZZ_BARE_CONNECTION_SUITE_UNDO' then v_state := left(sqlerrm, 200); end if;
  end;

  case_name := 'with no organisation, no principal and nobody signed in, a fresh invitation''s email is claimed';
  passed := v_state is null and v_allowed is true and v_reason is null;
  detail := coalesce(v_state, format('allowed %s, reason %s', coalesce(v_allowed::text, 'none'), coalesce(v_reason, 'none')));
  return next;

  case_name := 'the claim writes one log row, in the invited person''s organisation';
  passed := v_state is null and v_logged = 1 and v_log_ok;
  detail := coalesce(v_state, format('%s row(s), matching %s', v_logged, v_log_ok::text));
  return next;

  case_name := 'a second claim for the same address inside ten minutes is refused, not raised';
  passed := v_state is null and v_again is false and v_again_reason like '%ten minutes%';
  detail := coalesce(v_state, format('allowed %s, reason %s', coalesce(v_again::text, 'none'), coalesce(v_again_reason, 'none')));
  return next;

  case_name := 'the resend lookup and the account check answer from the same bare connection';
  passed := v_state is null and v_found = 1 and v_bound is false;
  detail := coalesce(v_state, format('%s invitation(s) found, unknown account bound: %s', v_found, coalesce(v_bound::text, 'none')));
  return next;
end;
$$;
revoke all on function erp_test.invitation_email_bare_connection_suite() from public, anon, authenticated;

create or replace function erp_test.assert_invitation_email_bare_connection_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 4;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _invitation_email_bare_connection on commit drop as
    select * from erp_test.invitation_email_bare_connection_suite();
  select count(*), count(*) filter (where coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _invitation_email_bare_connection;
  drop table _invitation_email_bare_connection;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_INVITATION_EMAIL_BARE_CONNECTION_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_INVITATION_EMAIL_BARE_CONNECTION_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('invitation email from a bare connection: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_invitation_email_bare_connection_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_invitation_email_bare_connection_suite();
select erp_test.assert_invitation_email_budget_suite();
select erp_test.assert_invitation_for_resend_suite();

select erp.assert_isolation();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp.assert_session_context_hygiene();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
