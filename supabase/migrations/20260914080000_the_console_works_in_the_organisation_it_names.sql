-- =============================================================================
-- The console works in the organisation it names
--
-- 20260914079000 found that a console routine which borrowed an organisation
-- by setting erp.job_tenant_id did its work in the signed-in person's own
-- organisation instead, whenever that person belonged to one: the context is
-- honoured only when nobody is signed in. It fixed every commercial routine
-- with erp_meta.act_in_tenant(). The same audit over the rest of the console
-- found three more:
--
--   public.erp_platform_run_due_jobs  walked every organisation and ran the
--       signed-in owner's own due jobs once for each of them, so Jobs and
--       queue's Run due jobs never ran a customer's jobs at all.
--   public.erp_platform_invite_admin  stamped the new administrator's row with
--       a principal from the inviting person's own organisation.
--   erp.expire_support_access         the same, on the rows it disables, when
--       Run due jobs reaches it.
--
-- Three others borrow an organisation on purpose and are left as they are,
-- because the person is, by then, inside it: erp_platform_enter_tenant makes it
-- their active organisation before it does anything there, erp.grant_support_access
-- is reached from that door after the switch, and erp_platform_leave_tenant is
-- only for a person inside the organisation. erp.record_support_action runs as
-- its caller, where a job context is ignored anyway.
--
-- A check keeps it so: a platform routine that sets erp.job_tenant_id to an
-- organisation is a finding unless it uses erp_meta.act_in_tenant() or is one
-- of those, with its reason.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The three routines act inside the organisation they name
-- ═════════════════════════════════════════════════════════════════════════════

do $acting$
declare
  r     record;
  v_def text;
  v_new text;
  v_n   integer := 0;
begin
  for r in
    select p.oid, p.oid::regprocedure::text as sig
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where (n.nspname, p.proname) in (('public', 'erp_platform_run_due_jobs'),
                                      ('public', 'erp_platform_invite_admin'),
                                      ('erp', 'expire_support_access'))
  loop
    v_def := pg_get_functiondef(r.oid);
    v_new := regexp_replace(v_def,
      $r$perform set_config\('erp\.job_tenant_id', '', true\);$r$,
      'perform erp_meta.stop_acting_in_tenant();', 'g');
    v_new := regexp_replace(v_new,
      $r$perform set_config\('erp\.job_tenant_id', ([a-z_.]+)::text, true\);$r$,
      'perform erp_meta.act_in_tenant(\1);', 'g');
    if v_new = v_def or position('erp.job_tenant_id' in v_new) > 0 then
      raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not borrow an organisation the way the audit found it', r.sig;
    end if;
    execute v_new;
    v_n := v_n + 1;
  end loop;
  if v_n <> 3 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: expected the three routines the audit named, found %', v_n;
  end if;
end
$acting$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The check
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.console_borrowed_organisation_report()
returns table(finding text, reference text, detail text)
language sql
stable
security definer
set search_path = ''
as $$
  with allowed(routine, reason) as (values
    ('public.erp_platform_enter_tenant',
     'makes the organisation the person''s active one before it does anything inside it'),
    ('erp.grant_support_access',
     'reached from erp_platform_enter_tenant after the person is inside the organisation'),
    ('public.erp_platform_leave_tenant',
     'only for a person inside the organisation'),
    ('erp.record_support_action',
     'runs as its caller, where a job context is ignored'))
  select 'a platform routine borrows an organisation without setting the signed-in person aside',
         p.oid::regprocedure::text,
         'it sets erp.job_tenant_id to an organisation, which is ignored while somebody is signed in; use erp_meta.act_in_tenant()'
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('erp', 'public')
     and (p.prosrc like '%require_platform(%' or p.prosrc like '%platform_actor(%')
     and p.prosrc ~ 'set_config\s*\(\s*''erp\.job_tenant_id''\s*,\s*[a-z_.(]'
     and n.nspname || '.' || p.proname not in (select a.routine from allowed a)
   order by 2
$$;

comment on function erp.console_borrowed_organisation_report() is
  'Platform routines that set erp.job_tenant_id to an organisation directly. '
  'That context is ignored while a person is signed in, so the routine works in '
  'their own organisation instead; erp_meta.act_in_tenant() sets them aside. '
  'Security definer to read every routine''s source.';

create or replace function erp.assert_console_acts_in_the_organisation_it_names()
returns text
language plpgsql
set search_path = ''
as $$
declare v_count integer; v_detail text;
begin
  select count(*), string_agg(format('  %s — %s', reference, detail), E'\n')
    into v_count, v_detail from erp.console_borrowed_organisation_report();
  if v_count > 0 then
    raise exception 'CLOVEERP_CONSOLE_BORROWS_AN_ORGANISATION: % routine(s)', v_count
      using errcode = 'P0001', detail = v_detail,
            hint = 'Replace set_config(''erp.job_tenant_id'', …) with erp_meta.act_in_tenant(…) and end with erp_meta.stop_acting_in_tenant().';
  end if;
  return 'console: every platform routine works in the organisation it names';
end;
$$;

revoke all on function erp.console_borrowed_organisation_report() from public, anon, authenticated;
revoke all on function erp.assert_console_acts_in_the_organisation_it_names() from public, anon, authenticated;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp', 'console_borrowed_organisation_report',
   'Reads pg_proc source for every platform routine to report on how it borrows an organisation. Returns routine names only.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('console_acts_in_its_organisation', 'The console works in the organisation it names',
   'assertion', 'platform', 'erp', 'assert_console_acts_in_the_organisation_it_names', '',
   'console_borrowed_organisation_report', '',
   'A platform routine that borrows an organisation by setting the job context works in the signed-in person''s own organisation instead, whenever they belong to one. Every such routine sets the person aside first.',
   true, 78)
on conflict (code) do update set
  title = excluded.title, function_name = excluded.function_name,
  detail_function = excluded.detail_function, blurb = excluded.blurb, seq = excluded.seq;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.console_acts_in_its_organisation_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  rp record; rc record; ro record;
  ad uuid := gen_random_uuid(); ow uuid := gen_random_uuid(); ca uuid := gen_random_uuid();
  v_platform uuid; v_pcode text := 'zzcaip-' || substr(md5(random()::text), 1, 6);
  v_customer uuid; v_ccode text := 'zzcaic-' || substr(md5(random()::text), 1, 6);
  v_own uuid;      v_ocode text := 'zzcaio-' || substr(md5(random()::text), 1, 6);
  v_prior erp_meta.platform_organisation;
  res jsonb; v_n integer; v_by uuid; v_ok boolean; v_msg text;
begin
  select po.* into v_prior from erp_meta.platform_organisation po;

  return query select 'no platform routine borrows an organisation without setting the person aside',
    not exists (select 1 from erp.console_borrowed_organisation_report()),
    coalesce((select string_agg(f.reference, ', ') from erp.console_borrowed_organisation_report() f), 'none');

  select * into rp from erp.provision_tenant(v_pcode, 'Clove Platform Jobs', 'admin@zzcaip.test', 'Platform Admin');
  v_platform := rp.tenant_id;
  select * into rc from erp.provision_tenant(v_ccode, 'A Customer', 'admin@zzcaic.test', 'Customer Admin');
  v_customer := rc.tenant_id;
  -- The owner belongs to an organisation of their own.
  select * into ro from erp.provision_tenant(v_ocode, 'Owner''s Own Company', 'owner@zzcaip.test', 'Platform Owner');
  v_own := ro.tenant_id;
  insert into auth.users (id, email) values (ad, 'admin@zzcaip.test'), (ow, 'owner@zzcaip.test'), (ca, 'admin@zzcaic.test');
  insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
  values ('owner@zzcaip.test', ow, 'Platform Owner', 'owner');
  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  perform erp.claim_invitation(rp.admin_token);
  perform set_config('request.jwt.claims', json_build_object('sub', ca)::text, true);
  perform erp.claim_invitation(rc.admin_token);
  perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
  perform erp.claim_invitation(ro.admin_token);
  perform erp.designate_platform_organisation(v_pcode, 'the console organisation suite');

  -- A due job in the platform's organisation: the commercial module installs
  -- the quote expiry sweep, and it is made due now.
  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  perform erp_test.reopen_bootstrap_window(v_platform);
  perform erp.configure_commercial(10, 'administrator');
  perform erp_test.close_bootstrap_window(v_platform);
  update erp.job j set next_run_at = now() - interval '1 minute', is_enabled = true
   where j.tenant_id = v_platform and j.handler_code = 'commercial.expire_quotes';
  get diagnostics v_n = row_count;

  perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
  begin
    res := public.erp_platform_run_due_jobs(25);
    v_msg := 'ran';
  exception when others then
    v_msg := left(sqlerrm, 120);
  end;
  return query select 'Run due jobs runs a customer''s due job for an owner who belongs to another organisation',
    v_n = 1
    and exists (select 1 from jsonb_array_elements(coalesce(res -> 'organisations', '[]'::jsonb)) x
                 where x ->> 'organisation' = v_pcode and (x ->> 'claimed')::integer >= 1)
    and erp.current_tenant_id() = v_own,
    format('%s; job made due %s; %s', v_msg, v_n, coalesce((res -> 'organisations')::text, 'no organisations'));

  begin
    perform public.erp_platform_invite_admin(v_customer, 'second@zzcaic.test', 'Second Admin');
    v_ok := true; v_msg := 'invited';
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 120);
  end;
  select u.created_by into v_by from erp.app_user u where u.tenant_id = v_customer and u.email = 'second@zzcaic.test';
  return query select 'an invited administrator is not stamped with a principal from the inviting owner''s own organisation',
    v_ok
    and (v_by is null or exists (select 1 from erp.app_user u where u.id = v_by and u.tenant_id = v_customer))
    and not exists (select 1 from erp.app_user u where u.id = v_by and u.tenant_id = v_own),
    v_msg;

  -- ── Clean up ─────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  delete from erp_meta.platform_organisation where tenant_id = v_platform;
  perform erp.begin_tenant_purge(v_platform);
  delete from erp.tenant where id = v_platform;
  perform erp.end_tenant_purge();
  perform erp.begin_tenant_purge(v_customer);
  delete from erp.tenant where id = v_customer;
  perform erp.end_tenant_purge();
  perform erp.begin_tenant_purge(v_own);
  delete from erp.tenant where id = v_own;
  perform erp.end_tenant_purge();
  delete from erp_meta.platform_staff where email like '%@zzcaip.test';
  delete from auth.users where id in (ad, ow, ca);
  if v_prior.tenant_id is not null then
    insert into erp_meta.platform_organisation (tenant_id, tenant_code, designated_at, designated_by, reason)
    values (v_prior.tenant_id, v_prior.tenant_code, v_prior.designated_at, v_prior.designated_by, v_prior.reason);
  end if;
  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant tn where tn.id in (v_platform, v_customer, v_own))
    and (v_prior.tenant_id is null
         or exists (select 1 from erp_meta.platform_organisation po where po.tenant_id = v_prior.tenant_id)),
    'organisations and staff gone, and any designation that was there before is back';
end;
$$;

create or replace function erp_test.assert_console_acts_in_its_organisation_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _console_acts_result on commit drop as
    select * from erp_test.console_acts_in_its_organisation_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_total, v_passed, v_detail
    from _console_acts_result;
  if v_passed < v_total then
    raise exception E'CLOVEERP_CONSOLE_ACTS_SUITE_FAILED: %/%\n%', v_passed, v_total, v_detail
      using errcode = 'P0001';
  end if;
  return format('console acts in its organisation: %s/%s', v_passed, v_total);
end;
$$;

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
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_session_context_hygiene();
select erp.assert_diagnostics_registered();
select erp.assert_console_acts_in_the_organisation_it_names();
select erp_test.assert_console_acts_in_its_organisation_suite();
