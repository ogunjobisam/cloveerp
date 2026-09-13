-- The drain serves every organisation.
--
-- The dispatch worker served only the organisations named in CLOVEERP_TENANTS,
-- each as a service principal named in CLOVEERP_PRINCIPALS. An organisation
-- nobody listed had its email queued by the minute pass and sent by nothing,
-- and on live nobody was listed. The minute pass has never needed a list:
-- erp.run_due_jobs_all_tenants() visits every active organisation from a
-- trusted session, with a tenant context and no principal, and every claim and
-- settle the worker calls asks for exactly that — a tenant, never a principal.
-- So the worker is given the same list, from the database, by the same rule.
--
-- Four things, one file:
--
--   1. erp.dispatch_bindings() — the active organisations, in code order, for a
--      trusted session only. The worker binds each with a tenant and no
--      principal, as the minute pass does. The suite proves the refusal, the
--      list, and that a tenant with no principal claims and settles an email.
--
--   2. erp.invitation_for_resend(token) — the invite function's second mode.
--      Somebody holding an invitation link whose sign-in part has expired asks
--      for a fresh one; the function looks the token up here over the database
--      connection it is given, and emails a new sign-in link to the address on
--      file, never to one the caller names. It hashes the token as
--      erp.invite_principal, erp.provision_tenant and the platform's admin
--      invitation mint it (SHA-256, hex), and answers only for an invitation
--      erp.claim_invitation would still redeem: unclaimed, unrevoked (a
--      superseded invitation is a revoked one), unexpired, for a person who does
--      not yet sign in. Anything else is no rows, never an error, so a caller
--      probing tokens learns nothing a wrong guess would not tell them.
--
--   3. The scheduled dispatch request waits 55 seconds. pg_net gives up after
--      its default of a few seconds; a drain pass over every organisation takes
--      longer than that. The schedule records the new command the next time
--      deploy.yml asks for it with a URL.
--
--   4. erp.dispatch_evidence() stops printing the last pass's report. Every
--      organisation's administrator reads that row, and a pass over every
--      organisation counts every organisation's email. The row keeps the worker
--      and the timestamps; the counts stay in erp_meta.drain_pass for the
--      platform.
--
-- Both new functions are SECURITY INVOKER on purpose. erp.session_is_trusted()
-- asks which role is running; inside a SECURITY DEFINER frame that is the owner,
-- and the test admits everybody (20260913070000 met it in propose_renewals).

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The organisations the drain serves
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.dispatch_bindings()
returns table (tenant_id uuid, tenant_code text)
language plpgsql
stable
security invoker
set search_path = ''
as $$
begin
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not list the organisations the drain serves', current_user
      using errcode = '42501',
            hint = 'The dispatch worker and the dispatch function connect as the database owner. A signed-in session never lists organisations.';
  end if;

  -- The minute pass's own predicate. Widening it (grace, restricted) changes
  -- both together or neither.
  return query
    select t.id, t.code
      from erp.tenant t
     where t.status = 'active'
     order by t.code;
end;
$$;
revoke all on function erp.dispatch_bindings() from public, anon, authenticated;

comment on function erp.dispatch_bindings() is
  'Every organisation the dispatch drain serves when no list is configured: the '
  'active ones, the set the minute pass visits, in code order. Trusted sessions '
  'only, and SECURITY INVOKER so the trust test sees the role that connected. '
  'The drain binds each with a tenant context and no principal, as the minute pass does.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. An invitation looked up by its token, for a fresh sign-in link
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.invitation_for_resend(p_token text)
returns table (email text, display_name text, tenant_name text, expires_at timestamptz)
language plpgsql
stable
security invoker
set search_path = ''
as $$
begin
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not look an invitation up by its token', current_user
      using errcode = '42501',
            hint = 'The invite function asks over its own database connection. A signed-in session redeems an invitation, it does not read one.';
  end if;

  -- The floor the claim sets. Nothing shorter was ever minted, so nothing
  -- shorter can be open.
  if p_token is null or length(p_token) < 32 then
    return;
  end if;

  -- Exactly the rows the claim would redeem: the digest matches, nobody has
  -- claimed it, it was not revoked (a superseded invitation is revoked), it has
  -- not expired, and the person it waits for does not already sign in.
  return query
    select u.email, u.display_name, t.name, i.expires_at
      from erp.invitation i
      join erp.app_user u on u.tenant_id = i.tenant_id and u.id = i.app_user_id
      join erp.tenant t on t.id = i.tenant_id
     where i.token_digest = encode(extensions.digest(p_token, 'sha256'), 'hex')
       and i.claimed_at is null
       and i.revoked_at is null
       and i.expires_at > now()
       and u.auth_user_id is null
       and u.email is not null
       and btrim(u.email) <> '';
end;
$$;
revoke all on function erp.invitation_for_resend(text) from public, anon, authenticated;

comment on function erp.invitation_for_resend(text) is
  'The address, name, organisation and expiry of an invitation that could still '
  'be redeemed, found by the SHA-256 digest of its token. No rows for a token '
  'that is unknown, claimed, revoked, superseded or expired, and never an error '
  'for one. Trusted sessions only: the invite function uses it to email a fresh '
  'sign-in link to the address on file.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The scheduled dispatch request waits for the drain
-- ═════════════════════════════════════════════════════════════════════════════

do $schedule$
declare
  v_def text := pg_get_functiondef('erp.ensure_platform_schedule(text,text)'::regprocedure);
  v_n   text := $n$body := ''{}''::jsonb)',$n$;
  v_r   text := $r$body := ''{}''::jsonb, timeout_milliseconds := 55000)',$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_SCHEDULE_UNRECOGNISED: erp.ensure_platform_schedule() is not the body this migration patches';
  end if;
  execute replace(v_def, v_n, v_r);

  if position('timeout_milliseconds := 55000' in pg_get_functiondef('erp.ensure_platform_schedule(text,text)'::regprocedure)) = 0 then
    raise exception 'CLOVEERP_SCHEDULE_UNRECOGNISED: the dispatch command did not take its timeout';
  end if;
end
$schedule$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The evidence an organisation reads stops carrying the platform's counts
-- ═════════════════════════════════════════════════════════════════════════════

do $evidence$
declare
  v_def text := pg_get_functiondef('erp.dispatch_evidence()'::regprocedure);
  v_n   text := $n$format('last pass %s ago: %s', date_trunc('second', now() - p.finished_at), p.report::text)$n$;
  v_r   text := $r$format('last pass %s ago', date_trunc('second', now() - p.finished_at))$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_EVIDENCE_UNRECOGNISED: erp.dispatch_evidence() is not the body this migration patches';
  end if;
  execute replace(v_def, v_n, v_r);

  if position('p.report' in pg_get_functiondef('erp.dispatch_evidence()'::regprocedure)) > 0 then
    raise exception 'CLOVEERP_EVIDENCE_UNRECOGNISED: erp.dispatch_evidence() still reads the pass report';
  end if;
end
$evidence$;

-- The door's allowance promised counts. It shows none now, and says why.
do $allowance$
declare v_moved integer;
begin
  update erp_meta.security_definer_allowance
     set rationale = 'Reads erp_meta.drain_pass, which is platform-internal and unreachable by a tenant session; gated on erp.authorise(administration.jobs). Of the last pass it returns only the worker and the timestamps, never the report, which counts every organisation''s work since the drain serves them all; every tenant row it reads is filtered on the caller''s tenant.'
   where schema_name = 'public' and function_name = 'erp_dispatch_evidence';
  get diagnostics v_moved = row_count;
  if v_moved <> 1 then
    raise exception 'CLOVEERP_ALLOWANCE_NOT_MOVED: % row(s) updated for public.erp_dispatch_evidence, expected 1', v_moved;
  end if;
end
$allowance$;

comment on table erp_meta.drain_pass is
  'One row per pass of the dispatch worker: who drained, when, and what it claimed '
  'and settled across every organisation it served. The console shows an '
  'organisation who and when; the counts are the platform''s and stay here.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The suites
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.dispatch_bindings_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  r          record;
  v_code     text := 'zz-drain-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
  v_parked   text := 'zz-drain-parked-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
  v_ok       boolean;
  v_msg      text;
  v_state    text;
  v_missing  integer;
  v_extra    integer;
  v_in_order boolean;
  v_parked_n integer;
  v_mail     uuid;
  v_claimed  integer;
  v_status   text;
  v_actor    uuid;
  v_worker   text;
  v_latest   text;
  v_evidence text;
begin
  -- 1. Refused without EXECUTE.
  begin
    execute 'set local role authenticated';
    perform 1 from erp.dispatch_bindings();
    execute 'reset role';
    v_ok := false; v_msg := 'a signed-in session listed every organisation';
  exception when others then
    execute 'reset role';
    v_ok := sqlstate = '42501'; v_msg := left(sqlerrm, 120);
  end;
  case_name := 'a signed-in session cannot list the organisations the drain serves';
  passed := v_ok; detail := v_msg;
  return next;

  -- 2. Refused by the function itself, should a grant ever reach it.
  v_ok := false; v_msg := null;
  begin
    execute 'grant execute on function erp.dispatch_bindings() to authenticated';
    execute 'set local role authenticated';
    perform 1 from erp.dispatch_bindings();
    v_msg := 'with execute granted, a signed-in session listed every organisation';
    raise exception 'ZZ_DRAIN_SUITE_UNDO';
  exception when others then
    execute 'reset role';
    if sqlerrm <> 'ZZ_DRAIN_SUITE_UNDO' then
      v_ok := sqlstate = '42501' and sqlerrm like 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION:%';
      v_msg := left(sqlerrm, 120);
    end if;
  end;
  case_name := 'granted execute by mistake, the function still refuses a signed-in session itself';
  passed := v_ok; detail := v_msg;
  return next;

  -- 3.
  select not p.prosecdef into v_ok
    from pg_catalog.pg_proc p where p.oid = 'erp.dispatch_bindings()'::regprocedure;
  case_name := 'the trust test runs in the caller''s frame';
  passed := coalesce(v_ok, false);
  detail := case when v_ok then 'security invoker' else 'security definer: the test would see the owner' end;
  return next;

  -- 4-7 build an organisation, read and drain it, and undo all of it.
  begin
    -- Inserted before any tenant context exists, as an organisation that is
    -- being suspended would already be on file.
    insert into erp.tenant (code, name, status) values (v_parked, 'Drain suite, suspended', 'suspended');

    select * into r from erp.provision_tenant(v_code, 'Drain suite', 'admin@' || v_code || '.test', 'Drain Admin');

    select count(*) into v_missing
      from erp.tenant t
     where t.status = 'active'
       and not exists (select 1 from erp.dispatch_bindings() b where b.tenant_id = t.id);
    select count(*) into v_extra
      from erp.dispatch_bindings() b
     where not exists (select 1 from erp.tenant t where t.id = b.tenant_id and t.status = 'active');
    select (select array_agg(b.tenant_code) from erp.dispatch_bindings() b)
           is not distinct from
           (select array_agg(t.code order by t.code) from erp.tenant t where t.status = 'active')
      into v_in_order;
    select count(*) into v_parked_n from erp.dispatch_bindings() b where b.tenant_code = v_parked;

    -- The binding the drain makes: this organisation, and nobody acting in it.
    perform erp.set_job_tenant(r.tenant_id);
    perform erp.set_job_principal(null);
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body, status)
    values (r.tenant_id, 'info', r.admin_user_id, 'email', 'Drain suite', 'Claimed with a tenant and no principal.', 'queued')
    returning id into v_mail;
    select count(*) filter (where c.id = v_mail) into v_claimed
      from erp.claim_email_batch(50, 'zz-drain-suite') c;
    perform erp.complete_email(v_mail, 'zz-drain-provider-1');
    select n.status into v_status from erp.notification n where n.id = v_mail;
    v_actor := erp.current_principal_id();

    -- A pass whose report counts other organisations' email.
    perform erp.record_drain_pass('zz-drain-suite', now(),
                                  jsonb_build_object('organisations', 3, 'emailClaimed', 7, 'emailSent', 7));
    -- One statement, one snapshot: the evidence and the register are read at
    -- the same moment, whatever else is draining.
    select e.worker, e.detail,
           (select p.worker from erp_meta.drain_pass p order by p.finished_at desc limit 1)
      into v_worker, v_evidence, v_latest
      from erp.dispatch_evidence() e where e.queue = 'platform';

    raise exception 'ZZ_DRAIN_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'ZZ_DRAIN_SUITE_UNDO' then v_state := left(sqlerrm, 160); end if;
  end;

  case_name := 'every active organisation is listed, once, in code order, and nothing else';
  passed := v_state is null and v_missing = 0 and v_extra = 0 and coalesce(v_in_order, false);
  detail := coalesce(v_state, format('%s active not listed, %s listed not active, in code order: %s',
                                     v_missing, v_extra, coalesce(v_in_order::text, 'unknown')));
  return next;

  case_name := 'an organisation that is not active is not served';
  passed := v_state is null and v_parked_n = 0;
  detail := coalesce(v_state, format('suspended organisation listed %s time(s)', v_parked_n));
  return next;

  case_name := 'a tenant context with no principal claims and settles an email';
  passed := v_state is null and v_claimed = 1 and v_status = 'sent' and v_actor is null;
  detail := coalesce(v_state, format('claimed %s, status %s, acting principal %s',
                                     v_claimed, v_status, coalesce(v_actor::text, 'none')));
  return next;

  case_name := 'an organisation reads who drained and when, never the pass report';
  passed := v_state is null
            and v_worker is not distinct from v_latest
            and v_evidence like 'last pass %'
            and position('{' in coalesce(v_evidence, '{')) = 0
            and position('emailSent' in coalesce(v_evidence, '')) = 0;
  detail := coalesce(v_state, format('worker %s (last pass by %s): %s',
                                     coalesce(v_worker, 'none'), coalesce(v_latest, 'none'), coalesce(v_evidence, 'no detail')));
  return next;
end;
$$;
revoke all on function erp_test.dispatch_bindings_suite() from public, anon, authenticated;

create or replace function erp_test.assert_dispatch_bindings_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 7;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _dispatch_bindings on commit drop as
    select * from erp_test.dispatch_bindings_suite();
  select count(*), count(*) filter (where coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _dispatch_bindings;
  drop table _dispatch_bindings;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_DISPATCH_BINDINGS_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_DISPATCH_BINDINGS_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('dispatch bindings: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_dispatch_bindings_suite() from public, anon, authenticated;

create or replace function erp_test.invitation_for_resend_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  r            record;
  v_code       text := 'zz-resend-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
  v_subject    uuid := gen_random_uuid();
  v_expired    text := encode(extensions.gen_random_bytes(32), 'hex');
  v_ok         boolean;
  v_msg        text;
  v_state      text;
  v_fresh_n    integer;
  v_fresh_ok   boolean;
  v_fresh      text;
  v_expired_n  integer;
  v_claimed_n  integer;
  v_first      text;
  v_second     text;
  v_first_n    integer;
  v_second_n   integer;
  v_superseded boolean;
  v_garbage_n  integer;
begin
  -- 1. Refused without EXECUTE.
  begin
    execute 'set local role authenticated';
    perform 1 from erp.invitation_for_resend(repeat('a', 64));
    execute 'reset role';
    v_ok := false; v_msg := 'a signed-in session looked an invitation up by its token';
  exception when others then
    execute 'reset role';
    v_ok := sqlstate = '42501'; v_msg := left(sqlerrm, 120);
  end;
  case_name := 'a signed-in session cannot look an invitation up by its token';
  passed := v_ok; detail := v_msg;
  return next;

  -- 2. Refused by the function itself, should a grant ever reach it.
  v_ok := false; v_msg := null;
  begin
    execute 'grant execute on function erp.invitation_for_resend(text) to authenticated';
    execute 'set local role authenticated';
    perform 1 from erp.invitation_for_resend(repeat('a', 64));
    v_msg := 'with execute granted, a signed-in session was answered';
    raise exception 'ZZ_RESEND_SUITE_UNDO';
  exception when others then
    execute 'reset role';
    if sqlerrm <> 'ZZ_RESEND_SUITE_UNDO' then
      v_ok := sqlstate = '42501' and sqlerrm like 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION:%';
      v_msg := left(sqlerrm, 120);
    end if;
  end;
  case_name := 'granted execute by mistake, the lookup still refuses a signed-in session itself';
  passed := v_ok; detail := v_msg;
  return next;

  -- 3.
  select not p.prosecdef into v_ok
    from pg_catalog.pg_proc p where p.oid = 'erp.invitation_for_resend(text)'::regprocedure;
  case_name := 'the lookup''s trust test runs in the caller''s frame';
  passed := coalesce(v_ok, false);
  detail := case when v_ok then 'security invoker' else 'security definer: the test would see the owner' end;
  return next;

  -- 4-7 mint, age, claim and supersede invitations through the real doors, and
  -- undo all of it.
  begin
    select * into r from erp.provision_tenant(v_code, 'Resend suite', 'admin@' || v_code || '.test', 'Resend Admin');

    -- A fresh invitation: the one provisioning minted.
    select count(*),
           coalesce(bool_and(f.email = 'admin@' || v_code || '.test'
                             and f.display_name = 'Resend Admin'
                             and f.tenant_name = 'Resend suite'
                             and f.expires_at = (select i.expires_at from erp.invitation i
                                                  where i.tenant_id = r.tenant_id and i.app_user_id = r.admin_user_id)), false),
           max(format('%s, %s, %s, %s', f.email, f.display_name, f.tenant_name, f.expires_at))
      into v_fresh_n, v_fresh_ok, v_fresh
      from erp.invitation_for_resend(r.admin_token) f;

    -- An expired one. now() is the transaction's start, so only a row minted in
    -- the past can be expired; both timestamps go back, as the claim's own
    -- suite ages one (0044).
    insert into erp.invitation (tenant_id, app_user_id, token_digest, created_at, expires_at)
    values (r.tenant_id, r.admin_user_id, encode(extensions.digest(v_expired, 'sha256'), 'hex'),
            now() - interval '15 days', now() - interval '1 day');
    select count(*) into v_expired_n from erp.invitation_for_resend(v_expired);

    -- A claimed one: the administrator signs in and redeems it.
    perform set_config('request.jwt.claims', json_build_object('sub', v_subject)::text, true);
    perform erp.claim_invitation(r.admin_token);
    select count(*) into v_claimed_n from erp.invitation_for_resend(r.admin_token);

    -- A superseded one: the administrator invites a colleague, then invites
    -- them again, which withdraws the first token.
    select i.token into v_first from erp.invite_principal('colleague@' || v_code || '.test', 'A Colleague') i;
    select i.token into v_second from erp.invite_principal('colleague@' || v_code || '.test', 'A Colleague') i;
    select count(*) into v_first_n from erp.invitation_for_resend(v_first);
    select count(*) into v_second_n from erp.invitation_for_resend(v_second);
    select exists (select 1 from erp.invitation i
                    where i.token_digest = encode(extensions.digest(v_first, 'sha256'), 'hex')
                      and i.revoked_at is not null and i.revoked_reason like 'superseded%')
      into v_superseded;

    raise exception 'ZZ_RESEND_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'ZZ_RESEND_SUITE_UNDO' then v_state := left(sqlerrm, 160); end if;
  end;

  case_name := 'a fresh invitation is found, with the address, name, organisation and expiry it was minted with';
  passed := v_state is null and v_fresh_n = 1 and v_fresh_ok;
  detail := coalesce(v_state, format('%s row(s): %s', v_fresh_n, coalesce(v_fresh, 'none')));
  return next;

  case_name := 'an expired invitation is not found';
  passed := v_state is null and v_expired_n = 0;
  detail := coalesce(v_state, format('%s row(s) for a token that expired yesterday', v_expired_n));
  return next;

  case_name := 'a claimed invitation is not found';
  passed := v_state is null and v_claimed_n = 0;
  detail := coalesce(v_state, format('%s row(s) for a token already redeemed', v_claimed_n));
  return next;

  case_name := 'a superseded invitation is not found, and the one that replaced it is';
  passed := v_state is null and coalesce(v_superseded, false) and v_first_n = 0 and v_second_n = 1;
  detail := coalesce(v_state, format('first token %s row(s), superseded %s; second token %s row(s)',
                                     v_first_n, coalesce(v_superseded::text, 'unknown'), v_second_n));
  return next;

  -- 8. Garbage is zero rows, never an error.
  begin
    select count(*) into v_garbage_n
      from (select 1 from erp.invitation_for_resend(null)
            union all select 1 from erp.invitation_for_resend('')
            union all select 1 from erp.invitation_for_resend('not an invitation')
            union all select 1 from erp.invitation_for_resend(repeat('0', 64))
            union all select 1 from erp.invitation_for_resend(encode(extensions.gen_random_bytes(32), 'hex'))) g;
    v_ok := v_garbage_n = 0;
    v_msg := format('%s row(s) for five tokens nobody minted', v_garbage_n);
  exception when others then
    v_ok := false; v_msg := 'raised: ' || left(sqlerrm, 120);
  end;
  case_name := 'a token nobody minted returns no rows and raises nothing';
  passed := v_ok; detail := v_msg;
  return next;
end;
$$;
revoke all on function erp_test.invitation_for_resend_suite() from public, anon, authenticated;

create or replace function erp_test.assert_invitation_for_resend_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 8;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _invitation_for_resend on commit drop as
    select * from erp_test.invitation_for_resend_suite();
  select count(*), count(*) filter (where coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _invitation_for_resend;
  drop table _invitation_for_resend;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_INVITATION_RESEND_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_INVITATION_RESEND_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('invitation resend: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_invitation_for_resend_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. Generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_dispatch_bindings_suite();
select erp_test.assert_invitation_for_resend_suite();

select erp.assert_isolation();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp.assert_session_context_hygiene();
-- No public function is created here; the allowance row a public door is judged
-- by changed wording, so the judge reads it again.
select erp.assert_public_api_safe();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
