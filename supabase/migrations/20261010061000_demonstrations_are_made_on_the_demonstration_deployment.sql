set lock_timeout = '30s';

-- =============================================================================
-- 20261010061000  Demonstrations are made on the demonstration deployment
-- -----------------------------------------------------------------------------
-- On 5 October the demonstration's history build (erp_seed_demo_history) ran
-- on production's 0.5 GB instance at ten to twelve seconds a call, the
-- instance swapped itself into the ground, and production was down for 77
-- minutes. The owner decided on 6 October that demonstrations move to their
-- own Supabase project, served at demo.cloveerp.com, and that production
-- stops making them. 20261010060000 lets a database say which deployment it
-- is; this is what production does with the answer.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. CLOVEERP_DEMONSTRATIONS_LIVE_ELSEWHERE, registered, and
--      erp.require_demonstration_deployment(), which raises it anywhere but
--      the demonstration deployment. Its next action is the address.
--   B. Making a demonstration refuses on production: erp.seed_demo() and
--      erp.seed_demo_history(), and so their doors public.erp_seed_demo() and
--      public.erp_seed_demo_history(), which call them straight after asking
--      who is asking. The doors themselves are not changed: their first
--      statement stays the platform staff check
--      (erp_test.invitation_only_suite holds them to that), so somebody who
--      may not make a demonstration anywhere is told that, and staff on
--      production are told where demonstrations are.
--   C. erp.catch_up_demonstrations() finds nothing to do on production and
--      says so with the empty report the deploy already reads as "no
--      demonstration organisation on this database". deploy.yml runs the
--      catch-up on both deployments; on production it must neither trade a
--      demonstration forward nor fail.
--   D. erp_test.demonstrations_live_elsewhere_suite, seven cases, and its
--      assertion.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- On the demonstration deployment, and on the schema build's database, which
-- is marked a demonstration the same way, everything is as it was. Who may
-- make a demonstration there is unchanged (platform operators and owners, or
-- anybody while self-service sign-up is open). public.erp_seed_demo_configuration()
-- and public.erp_seed_demo_operations() work inside an existing demonstration
-- and make none, so they are left as they are.
--
-- On production: three functions are replaced and a suite added. No row of any
-- organisation is touched. The two demonstrations still on production
-- (demo-cbb10384 and demo-ba8b5156, both suspended) stay as they are for the
-- owner to purge; an active one would no longer be traded forward by a deploy.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The refusal
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal(
  'CLOVEERP_DEMONSTRATIONS_LIVE_ELSEWHERE',
  'Making a demonstration organisation, or building its history, on production.',
  'Demonstrations have their own deployment at demo.cloveerp.com, so that building one never competes with the '
  'organisations that trade here.',
  'Open https://demo.cloveerp.com and make the demonstration there.');

create or replace function erp.require_demonstration_deployment()
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if erp.deployment_kind() <> 'demonstration' then
    raise exception 'CLOVEERP_DEMONSTRATIONS_LIVE_ELSEWHERE: demonstrations are made at demo.cloveerp.com, not on production'
      using errcode = '42501',
            hint = 'Open https://demo.cloveerp.com and make the demonstration there.';
  end if;
end;
$$;

revoke all on function erp.require_demonstration_deployment() from public, anon;

comment on function erp.require_demonstration_deployment() is
  'Refuses with CLOVEERP_DEMONSTRATIONS_LIVE_ELSEWHERE anywhere but the demonstration deployment '
  '(erp.deployment_kind()). Asked by everything that makes a demonstration or builds its history (20261010061000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. Making a demonstration refuses on production
-- ─────────────────────────────────────────────────────────────────────────────

do $seed$
declare
  r      record;
  v_src  text;
  v_def  text;
begin
  for r in
    select * from (values
      ('erp.seed_demo()', '3caf8ced0ed4ce768df76d531fc55136',
       $o$  -- Idempotent: reuse the caller's existing demo tenant.$o$,
       $n$  -- Only on the demonstration deployment (20261010061000).
  perform erp.require_demonstration_deployment();

  -- Idempotent: reuse the caller's existing demo tenant.$n$),
      ('erp.seed_demo_history(date,date,numeric)', '0a9ac201902c80bec34f579c146c758d',
       $o$begin
  -- §22.3: demonstration history is refused in a live environment by the$o$,
       $n$begin
  -- Only on the demonstration deployment (20261010061000).
  perform erp.require_demonstration_deployment();

  -- §22.3: demonstration history is refused in a live environment by the$n$)
    ) as x(sig, md5, old, new)
  loop
    v_src := (select p.prosrc from pg_catalog.pg_proc p where p.oid = r.sig::regprocedure);
    v_def := pg_catalog.pg_get_functiondef(r.sig::regprocedure);
    if strpos(v_src, '20261010061000') > 0 then
      raise notice '% already asks for the demonstration deployment; left as it is', r.sig;
      continue;
    end if;
    if md5(v_src) <> r.md5 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010061000 expects (md5 %)', r.sig, md5(v_src);
    end if;
    if (length(v_def) - length(replace(v_def, r.old, ''))) / length(r.old) <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', r.sig;
    end if;
    execute replace(v_def, r.old, r.new);
  end loop;
end
$seed$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The catch-up finds nothing to do on production
-- ─────────────────────────────────────────────────────────────────────────────

do $catch$
declare
  v_sig  constant text := 'erp.catch_up_demonstrations(text)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$begin
  for t in select tn.id, tn.code from erp.tenant tn$o$;
  v_new  constant text := $n$begin
  -- Demonstrations live on the demonstration deployment (20261010061000).
  -- Anywhere else there is nothing to bring up to date, and the empty report
  -- is what deploy.yml reads as "no demonstration organisation".
  if erp.deployment_kind() <> 'demonstration' then
    return '[]'::jsonb;
  end if;

  for t in select tn.id, tn.code from erp.tenant tn$n$;
begin
  if strpos(v_src, '20261010061000') > 0 then
    raise notice '% already stays on the demonstration deployment; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'eedcf81ce1cc2dbb7c635a06c48a8fee' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010061000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$catch$;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.demonstrations_live_elsewhere_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 7;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  v_uid    uuid := gen_random_uuid();
  v_step   text := 'marking a demonstration';
  v_state  text;
  v_got    text;
  v_seeded jsonb;
  v_report jsonb;
  v_code   text;
begin
  begin
    -- ── 1. On the demonstration deployment, as before ───────────────────────
    delete from erp_meta.platform_setting where key = 'deployment.kind';
    insert into erp_meta.platform_setting (key, value, reason)
    values ('deployment.kind', '"demonstration"'::jsonb, 'demonstrations_live_elsewhere_suite');

    -- Platform staff, whom the doors admit, so what refuses below is where
    -- and not who.
    v_step := 'a person to make the demonstration';
    insert into auth.users (id, email) values (v_uid, 'demo@zzdle-' || v_tag || '.test');
    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
    values ('demo@zzdle-' || v_tag || '.test', v_uid, 'Demonstrations Suite Operator', 'operator');
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);

    v_step := 'making a demonstration on the demonstration deployment';
    v_seeded := erp.seed_demo();
    select t.code into v_code from erp.tenant t where t.id = (v_seeded ->> 'tenant_id')::uuid;
    v_cases := v_cases + 1;
    case_name := 'on the demonstration deployment a demonstration is made as before';
    passed := v_code like 'demo-%' and not (v_seeded ->> 'already_existed')::boolean;
    detail := coalesce(v_code, 'no organisation');
    return next;

    -- From here this database is production, with an active demonstration in
    -- it, as production was until the owner purges the two it still holds.
    delete from erp_meta.platform_setting where key = 'deployment.kind';

    -- ── 2. The builder refuses ──────────────────────────────────────────────
    v_step := 'making a demonstration on production';
    begin
      perform erp.seed_demo();
      v_got := 'it was made, or the old one handed back';
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'on production erp.seed_demo() refuses, even to somebody who already has a demonstration';
    passed := v_got like 'CLOVEERP_DEMONSTRATIONS_LIVE_ELSEWHERE%';
    detail := v_got;
    return next;

    -- ── 3. And its door ──────────────────────────────────────────────────────
    v_step := 'the seeding door on production';
    begin
      perform public.erp_seed_demo();
      v_got := 'it answered';
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'on production public.erp_seed_demo() tells platform staff where demonstrations are made';
    passed := v_got like 'CLOVEERP_DEMONSTRATIONS_LIVE_ELSEWHERE%';
    detail := v_got;
    return next;

    -- ── 4. The history door, inside the demonstration ───────────────────────
    v_step := 'the history door on production';
    perform erp.set_active_tenant((v_seeded ->> 'tenant_id')::uuid);
    begin
      perform public.erp_seed_demo_history(current_date - 1, current_date, 1);
      v_got := 'it answered';
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'on production public.erp_seed_demo_history() refuses';
    passed := v_got like 'CLOVEERP_DEMONSTRATIONS_LIVE_ELSEWHERE%';
    detail := v_got;
    return next;

    -- ── 5. The history builder, inside the demonstration ────────────────────
    v_step := 'the history builder on production';
    begin
      perform erp.seed_demo_history(current_date - 1, current_date, 1);
      v_got := 'it built';
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'on production erp.seed_demo_history() refuses inside a demonstration that is already there';
    passed := v_got like 'CLOVEERP_DEMONSTRATIONS_LIVE_ELSEWHERE%';
    detail := v_got;
    return next;

    -- ── 6. The deploy's catch-up finds nothing ──────────────────────────────
    v_step := 'the catch-up on production';
    perform set_config('request.jwt.claims', '', true);
    v_report := erp.catch_up_demonstrations();
    v_cases := v_cases + 1;
    case_name := 'on production the deploy''s catch-up finds nothing to do, although an active demonstration is there';
    passed := v_report = '[]'::jsonb;
    detail := left(v_report::text, 200);
    return next;

    -- ── 7. The refusal says where to go ─────────────────────────────────────
    v_step := 'the register';
    select r.next_action into v_got
      from erp_ref.refusal r where r.code = 'CLOVEERP_DEMONSTRATIONS_LIVE_ELSEWHERE';
    v_cases := v_cases + 1;
    case_name := 'the refusal''s next action is the demonstration''s address';
    passed := v_got like '%https://demo.cloveerp.com%';
    detail := coalesce(v_got, 'not registered');
    return next;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('erp.job_tenant_id', '', true);
  perform set_config('request.jwt.claims', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_DEMONSTRATIONS_LIVE_ELSEWHERE_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.demonstrations_live_elsewhere_suite() from public, anon;

comment on function erp_test.demonstrations_live_elsewhere_suite() is
  'Demonstrations are made on the demonstration deployment (20261010061000): there a demonstration is made as before; '
  'on production erp.seed_demo() and erp.seed_demo_history() refuse with CLOVEERP_DEMONSTRATIONS_LIVE_ELSEWHERE, and '
  'so do their doors to platform staff, the catch-up finds nothing to do, and the refusal names the address.';

create or replace function erp_test.assert_demonstrations_live_elsewhere_suite()
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
    from erp_test.demonstrations_live_elsewhere_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_DEMONSTRATIONS_LIVE_ELSEWHERE_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'Production makes a demonstration, or trades one forward, or the demonstration deployment no longer does. Read the case that failed.';
  end if;
  if v_total <> 7 then
    raise exception 'CLOVEERP_DEMONSTRATIONS_LIVE_ELSEWHERE_SUITE_SHRANK: % case(s), expected 7', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('demonstrations live elsewhere: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_demonstrations_live_elsewhere_suite() from public, anon;

comment on function erp_test.assert_demonstrations_live_elsewhere_suite() is
  'Production makes no demonstration and trades none forward; the demonstration deployment does as before '
  '(20261010061000).';

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
