set lock_timeout = '30s';

-- =============================================================================
-- 20261011130000  A stuck claim lets go
-- -----------------------------------------------------------------------------
-- Three things the review of the client-deployment change found:
--
--   - A build request the sweep claimed and never settled (the sweep died
--     between starting the build and recording that it had) stayed claimed
--     for ever. Retry refused because a request was open; Start again refused
--     because the deployment was failed, not requested. Retry now cancels a
--     claim the sweep has left alone for twenty minutes, the same wait Start
--     again uses, and carries on.
--   - Start again locked the deployment's row for update, which a sweep
--     recording its dispatch step at the same moment waits on (the step's
--     foreign key takes a key-share lock). It now takes the lighter lock that
--     still keeps two restarts, or a restart and a retirement, apart.
--   - The open-invoices door named only the code on the invoice, so Today's
--     card took a client deployment's code for an organisation's. It now says
--     which deployment an invoice's contract names, when it names one.
-- =============================================================================

do $$
declare
  v_def text;
  v_src text;
  r     record;
begin
  for r in
    select * from (values
      ('public.erp_platform_retry_deployment(text,text)', '81f6b45f7c0b33333b16d51b6de71b44',
       E'  if exists (select 1 from erp_meta.fleet_request r\n              where r.kind = ''build'' and r.payload ->> ''code'' = d.code and r.status in (''requested'', ''claimed'')) then\n    raise exception ''CLOVEERP_DEPLOYMENT_NOT_RETRYABLE: % already has a build request open'', d.code',
       E'  -- The row, then its open build requests, in the order Start again takes\n'
       '  -- them. A claim the sweep left unsettled for twenty minutes is let go:\n'
       '  -- the sweep died between starting the build and saying so (20261011130000).\n'
       '  select * into d from erp_meta.deployment x where x.code = d.code for no key update;\n'
       '  perform 1 from erp_meta.fleet_request x\n'
       '   where x.kind = ''build'' and x.payload ->> ''code'' = d.code and x.status in (''requested'', ''claimed'')\n'
       '   for update;\n'
       '  update erp_meta.fleet_request x\n'
       '     set status = ''cancelled'',\n'
       '         outcome = format(''claimed by the sweep and never settled; let go by %s on retry'', v.email),\n'
       '         settled_at = now()\n'
       '   where x.kind = ''build'' and x.payload ->> ''code'' = d.code and x.status = ''claimed''\n'
       '     and coalesce(x.claimed_at, x.created_at) < now() - interval ''20 minutes'';\n'
       '  if found then\n'
       '    perform erp_meta.record_deployment_event(d.code, ''retry'', ''note'',\n'
       '      ''a build request the sweep claimed and never settled was let go'');\n'
       '  end if;\n'
       '  if exists (select 1 from erp_meta.fleet_request r\n              where r.kind = ''build'' and r.payload ->> ''code'' = d.code and r.status in (''requested'', ''claimed'')) then\n    raise exception ''CLOVEERP_DEPLOYMENT_NOT_RETRYABLE: % already has a build request open'', d.code'),
      ('public.erp_platform_restart_deployment(text,text)', '6011666cb145e565cd1e448927abde33',
       '  select * into d from erp_meta.deployment x where x.code = d.code for update;',
       E'  -- No key update, not update: the sweep recording a dispatch step for this\n'
       '  -- row at the same moment needs only a key share (20261011130000).\n'
       '  select * into d from erp_meta.deployment x where x.code = d.code for no key update;'),
      ('public.erp_platform_open_invoices()', 'f281050e87c69d433578c5934f6c6797',
       '''contract_id'', c.id, ''tenant_code'', i.tenant_code,',
       '''contract_id'', c.id, ''tenant_code'', i.tenant_code, ''deployment_code'', c.deployment_code,')
    ) as x(sig, anchor, old, new)
  loop
    v_src := (select p.prosrc from pg_proc p where p.oid = r.sig::regprocedure);
    if strpos(v_src, '20261011130000') > 0 or strpos(v_src, r.new) > 0 then
      raise notice '% already carries 20261011130000', r.sig;
      continue;
    end if;
    if md5(v_src) <> r.anchor then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body this migration was written against', r.sig;
    end if;
    v_def := pg_get_functiondef(r.sig::regprocedure);
    if (length(v_def) - length(replace(v_def, r.old, ''))) / length(r.old) <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % does not hold its anchor exactly once', r.sig;
    end if;
    execute replace(v_def, r.old, r.new);
  end loop;
end
$$;

create or replace function erp_test.abandoned_claim_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 3;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  v_code   text;
  v_uid    uuid := gen_random_uuid();
  v_owner  text;
  v_claim  jsonb;
  v_old    uuid;
  v_json   jsonb;
  v_step   text := 'standing up an owner on the control plane';
  v_state  text;
  v_got    text;
  v_got2   text;
begin
  begin
    v_code := 'zzabn-' || v_tag;
    v_owner := 'owner@' || v_code || '.test';
    insert into auth.users (id, email, email_confirmed_at) values (v_uid, v_owner, now());
    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
    values (v_owner, v_uid, 'Abandoned Claim Suite Owner', 'owner');
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    delete from erp_meta.platform_setting where key = 'deployment.kind';
    insert into erp_meta.platform_setting (key, value, reason)
    values ('deployment.kind', '"production"'::jsonb, 'abandoned_claim_suite');
    -- Older open requests would be claimed first; they wait out the suite.
    update erp_meta.fleet_request x set status = 'cancelled', settled_at = now()
     where x.status in ('requested', 'claimed');

    -- A build the sweep claimed and started, and then died before settling;
    -- the run itself began, and failed.
    v_step := 'claiming a build and never settling it';
    perform public.erp_platform_request_deployment(v_code, 'Abandoned Claim Ltd', 'admin@' || v_code || '.test',
      'A client the abandoned claim suite builds and loses.');
    v_claim := erp_meta.claim_fleet_request('run-' || v_tag);
    v_old := (v_claim ->> 'id')::uuid;
    perform erp_meta.record_deployment_event(v_code, 'create', 'started', 'making the project', 'run-' || v_tag);
    perform erp_meta.record_deployment_event(v_code, 'build', 'failed', 'a migration failed', 'run-' || v_tag);

    -- ── 1. A fresh claim still holds ────────────────────────────────────────
    v_step := 'retrying while the claim is fresh';
    begin
      perform public.erp_platform_retry_deployment(v_code, 'The suite retries while the sweep may still settle.');
      v_got := 'it was retried';
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a claim the sweep made a moment ago still holds the build back';
    passed := v_got like 'CLOVEERP_DEPLOYMENT_NOT_RETRYABLE%open%'
          and (select x.status from erp_meta.fleet_request x where x.id = v_old) = 'claimed';
    detail := left(v_got, 160);
    return next;

    -- ── 2. An abandoned claim lets go ───────────────────────────────────────
    v_step := 'retrying after the claim was abandoned';
    update erp_meta.fleet_request x
       set claimed_at = now() - interval '21 minutes', created_at = now() - interval '22 minutes'
     where x.id = v_old;
    v_json := public.erp_platform_retry_deployment(v_code, 'The suite retries after the sweep gave no word.');
    begin
      perform erp_meta.settle_fleet_request(v_old, 'success: deployment_from_empty.yml started');
      v_got2 := 'the late settle was quiet';
    exception when others then
      v_got2 := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a claim the sweep left for twenty minutes is let go on retry, and its late settle is quiet';
    passed := v_json ->> 'status' = 'requested'
          and (select x.status from erp_meta.fleet_request x where x.id = v_old) = 'cancelled'
          and exists (select 1 from erp_meta.fleet_request x
                       where x.kind = 'build' and x.payload ->> 'code' = v_code and x.status = 'requested')
          and exists (select 1 from erp_meta.deployment_event e
                       where e.code = v_code and e.phase = 'retry' and e.detail like '%never settled%')
          and v_got2 = 'the late settle was quiet';
    detail := coalesce(v_json::text, 'nothing') || ' / ' || left(v_got2, 80);
    return next;

    -- ── 3. The other two corrections are in place ───────────────────────────
    v_step := 'reading the restart door and the open-invoices door';
    v_cases := v_cases + 1;
    case_name := 'Start again takes the lighter row lock, and open invoices say which deployment a contract names';
    passed := strpos(pg_get_functiondef('public.erp_platform_restart_deployment(text,text)'::regprocedure),
                     'where x.code = d.code for no key update') > 0
          and strpos(pg_get_functiondef('public.erp_platform_open_invoices()'::regprocedure),
                     '''deployment_code'', c.deployment_code') > 0;
    detail := case when passed then 'both in place' else 'one is missing' end;
    return next;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_ABANDONED_CLAIM_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

create or replace function erp_test.assert_abandoned_claim_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)), count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.abandoned_claim_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_ABANDONED_CLAIM_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A build request the sweep abandoned holds a deployment back: read the case that failed.';
  end if;
  if v_total <> 3 then
    raise exception 'CLOVEERP_ABANDONED_CLAIM_SUITE_SHRANK: % case(s), expected 3', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('abandoned claim: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.abandoned_claim_suite() from public, anon;
revoke all on function erp_test.assert_abandoned_claim_suite() from public, anon;

comment on function erp_test.assert_abandoned_claim_suite() is
  'A build request the sweep claimed and never settled is let go by Retry after twenty minutes; Start again takes '
  'the lighter row lock; open invoices name the deployment a contract names (20261011130000).';

-- The generators, which are idempotent and run at the end of every migration.

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
select erp.assert_personal_data_register_sound();
