-- =============================================================================
-- 20260906148000  Every permission the screens name exists
-- -----------------------------------------------------------------------------
-- Specification v1.6 §3.1. erp.assert_authorise_codes_exist() already proves
-- that every permission code a DATABASE gate names is in the catalogue,
-- because a gate on a code that does not exist refuses everybody and a refusal
-- looks like the system working. The application's gates had no such proof.
--
-- The client gate is hasPermission(session, "module.action") and the code is a
-- bare string. Nothing compared those strings with erp_ref.permission, and the
-- failure they cause is quieter still: hasPermission() asks whether the
-- session's list contains the code, a code the catalogue does not hold is in
-- nobody's list, and so the control is withheld from everybody, in silence,
-- for ever. Not a refusal, not an empty state — a button disabled with
-- "Requires administration.approve" on it, which is what the approve and
-- reject buttons on /governance said on the day this was written, against a
-- catalogue that has master_data.approve and procurement.approve and no such
-- code at all. No suite can see it: one that asserts a role cannot press the
-- button agrees with a screen nobody can press it on.
--
-- What changes:
--
--   * erp.assert_app_permissions_exist(codes) — the build hands it every
--     permission code it extracts from src (supabase/ci/app_permissions.sh,
--     step "Every permission code the screens name exists"); a code the
--     catalogue does not hold fails the build. The same shape as
--     erp.assert_app_doors_exist(), for the same reason and against the same
--     class of typo, and the application-side half of what
--     erp.assert_authorise_codes_exist() does for the gates in the database.
--   * erp_test.app_permission_suite() — the assertion accepts the catalogue,
--     refuses a code that is not in it, and refuses an empty list, because an
--     extraction that found nothing must not read as a pass.
--   * The /governance approve and reject buttons lose the permission prop
--     they carried (committed with this file). erp.decide_approval_task()
--     gates on the task being assigned to the caller, directly or through a
--     role they hold — it asks for no permission code, so the button must not
--     either, and the panel above it lists only the caller's own tasks.
--
-- The catalogue is product content: erp_ref.permission ships with the release
-- and is identical for every tenant, so a code either is in it or is a typo.
-- This is one direction only — a catalogued permission no screen names is a
-- capability granted through a role and enforced by the database, which is
-- neither a defect nor this assertion's business.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The assertion
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.assert_app_permissions_exist(p_codes text[])
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_missing text[];
  v_n       integer := coalesce(cardinality(p_codes), 0);
begin
  if v_n = 0 then
    raise exception 'CLOVEERP_APP_NAMES_NO_PERMISSIONS: the list of permission codes is empty'
      using errcode = '22023',
            hint = 'supabase/ci/app_permissions.sh extracts every permission code from src; an empty list means the extraction found nothing, which is not a pass.';
  end if;
  select array_agg(c order by c) into v_missing
    from unnest(p_codes) as c
   where not exists (select 1 from erp_ref.permission p where p.code = c);
  if v_missing is not null then
    raise exception E'CLOVEERP_APP_PERMISSION_MISSING: % code(s) the application names are not in the permission catalogue:\n  %',
      cardinality(v_missing), array_to_string(v_missing, E'\n  ')
      using errcode = 'P0001',
            hint = 'Catalogue the permission in a migration, or name a code that exists: a code no catalogue holds is in no session''s list, so the control is hidden from everybody rather than from the wrong people.';
  end if;
  return format('app permissions: %s named, all in the catalogue', v_n);
end;
$$;
revoke all on function erp.assert_app_permissions_exist(text[]) from public, anon, authenticated;

comment on function erp.assert_app_permissions_exist(text[]) is
  'Refuses any permission code the application names that erp_ref.permission '
  'does not hold. The build extracts the codes from src and calls this; a typo '
  'in a gate hides its control from every role at once, which is a false '
  'negative no permission suite can see.';

insert into erp_meta.check_run_exemption (schema_name, function_name, driven_by, rationale) values
  ('erp', 'assert_app_permissions_exist', null,
   'Takes the permission codes supabase/ci/app_permissions.sh extracts from the application source; only the build can know what the application names, and it calls this with that list.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;
insert into erp_meta.diagnostic_exemption (schema_name, function_name, rationale) values
  ('erp', 'assert_app_permissions_exist',
   'Takes the list of permission codes the application source contains. A console button has no such list; the build extracts it and calls this.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.app_permission_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_ok  boolean;
  v_msg text;
  v_n   integer;
begin
  -- 1
  select count(*) into v_n from erp_ref.permission;
  v_msg := erp.assert_app_permissions_exist((select array_agg(p.code) from erp_ref.permission p));
  case_name := 'the catalogue is accepted whole';
  passed := v_n > 50 and v_msg like 'app permissions: % named, all in the catalogue';
  detail := format('%s codes; %s', v_n, v_msg);
  return next;

  -- 2
  case_name := 'and a code the catalogue does not hold is refused';
  begin
    perform erp.assert_app_permissions_exist(array['administration.read', 'administration.approve']);
    v_ok := false; v_msg := 'a code that is not catalogued was accepted';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_APP_PERMISSION_MISSING%' and sqlerrm like '%administration.approve%';
    v_msg := left(sqlerrm, 90);
  end;
  passed := v_ok; detail := v_msg;
  return next;

  -- 3
  case_name := 'an extraction that found nothing is not a pass';
  begin
    perform erp.assert_app_permissions_exist(array[]::text[]);
    v_ok := false; v_msg := 'an empty list was accepted';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_APP_NAMES_NO_PERMISSIONS%'; v_msg := left(sqlerrm, 90);
  end;
  passed := v_ok; detail := v_msg;
  return next;
end;
$$;
revoke all on function erp_test.app_permission_suite() from public, anon, authenticated;

create or replace function erp_test.assert_app_permission_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 3;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _app_permission on commit drop as
    select * from erp_test.app_permission_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _app_permission;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_APP_PERMISSION_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_APP_PERMISSION_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('app permissions: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_app_permission_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Prove it
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_app_permission_suite();
select erp.assert_guidance_sound();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage('de');

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp.assert_product_decisions_enforced();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_linter_clean();

do $console$
declare v_bad text;
begin
  select string_agg(c ->> 'code' || ': ' || left(c ->> 'detail', 80), '; ')
    into v_bad
    from jsonb_array_elements(erp.platform_assurance()) c
   where not (c ->> 'ok')::boolean;
  if v_bad is not null then
    raise exception 'CLOVEERP_ASSURANCE_NOT_GREEN: %', v_bad;
  end if;
end
$console$;
