set lock_timeout = '30s';

-- =============================================================================
-- 20261014600000  A supervisor is someone else
-- -----------------------------------------------------------------------------
-- A person starting work on a scanner may have a supervisor authorise the
-- session. The override is recorded against both people (§14.6), so the
-- table has always refused one person in both places
-- (device_session_supervisor_is_not_operator). But the refusal reached the
-- screen as the bare constraint, which the app can only read as "That value
-- is not allowed.", under the reason the person had just typed, so it looked
-- as if the reason was wrong (the owner, on the demonstration, 14 October).
--
--   A. erp.open_device_session() refuses a supervisor who is the person
--      starting the session before it changes anything, with a registered
--      refusal that says what was refused and what to do instead. The scanner
--      also leaves the person out of the list it offers.
--
--   B. Every step a device task asks for has words of its own: steps whose
--      key had none showed the key itself ("site_id"). The words live in
--      src/lib/device-prompts.ts and are seeded here, so a tenant can rename
--      them like any other screen string.
--
--   C. erp_test.supervisor_is_someone_else_suite(): refused by name, the
--      session already open left as it was, and the refusal's words there.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The refusal
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_DEVICE_SUPERVISOR_IS_OPERATOR',
  'Choosing yourself as the supervisor of your own session.',
  'A supervisor vouches for somebody else, and the override is recorded against both people, so one person in both places proves nothing.',
  'Choose another person as the supervisor, or start the session without one.');

do $session$
declare
  v_sig text := 'erp.open_device_session(text,uuid,text)';
  v_src text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = 'erp.open_device_session(text,uuid,text)'::regprocedure);
  v_def text;
  v_old text := $o$  -- §14.6: "Fast user switching$o$;
  v_new text := $n$  -- §14.6: the override is recorded against both people, so the supervisor
  -- is somebody else. Refused here, before the previous session is ended,
  -- rather than by the table's constraint, which the screen can only call a
  -- value that is not allowed (20261014600000).
  if p_supervisor_user_id is not null and p_supervisor_user_id = v_user then
    raise exception
      'CLOVEERP_DEVICE_SUPERVISOR_IS_OPERATOR: a supervisor authorises somebody else''s session, not their own'
      using errcode = '23514',
            hint = 'Choose another person as the supervisor, or start the session without one.';
  end if;

  -- §14.6: "Fast user switching$n$;
begin
  if strpos(v_src, '20261014600000') > 0 then
    raise notice '% already carries 20261014600000', v_sig;
    return;
  end if;
  if md5(v_src) <> '58830e6ed59c26d5934e0415f098385d' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body this migration was written against', v_sig
      using hint = 'Write the change against the body the database holds now.';
  end if;
  v_def := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % does not hold its anchor exactly once', v_sig
      using hint = 'Write the change against the body the database holds now.';
  end if;
  execute replace(v_def, v_old, v_new);
end
$session$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The scanner's words for every step
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'Scanner wording, keyed by its own source text so a tenant can rename it: a step of a device task (20261014600000).'
  from (values
    ('Scan the site'),
    ('Scan the outer handling unit'),
    ('Scan the document'),
    ('Scan the supplier'),
    ('How many completed?'),
    ('How many scrapped?'),
    ('Code for the new handling unit'),
    ('Handling unit type'),
    ('Carriage cost, in pence or cents'),
    ('Outcome'),
    ('Instrument used'),
    ('Observed result')
  ) v(text)
on conflict (key, locale) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The suite
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.supervisor_is_someone_else_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 3;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_tenant uuid;
  v_site   text;
  v_me     uuid;
  v_first  uuid;
  v_ok     boolean;
  v_msg    text;
begin
  begin
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzsup' || v_tag, 'Supervisor Suite',
      'admin@demo-zzsup' || v_tag || '.test', 'Supervisor Suite Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzsup' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    v_tenant := rb.tenant_id;
    v_me := erp.current_principal_id();
    select s.code into v_site from erp.site s where s.tenant_id = v_tenant order by s.code limit 1;
    v_step := 'a scanner, and a session on it';
    perform erp.register_device('zzsup-hh', v_site, 'Supervisor suite scanner', 'handheld');
    v_first := (erp.open_device_session('zzsup-hh') ->> 'session_id')::uuid;

    -- ── 1. Refused by name ──────────────────────────────────────────────────
    v_step := 'the person as their own supervisor';
    begin
      perform erp.open_device_session('zzsup-hh', v_me, 'testing');
      v_ok := false; v_msg := 'a person supervised their own session';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_DEVICE_SUPERVISOR_IS_OPERATOR%'; v_msg := left(sqlerrm, 90);
    end;
    v_cases := v_cases + 1;
    case_name := 'a person who names themselves as supervisor is refused by name, not by the table''s constraint';
    passed := v_state is null and v_ok;
    detail := coalesce(v_state, v_msg);
    return next;

    -- ── 2. Nothing changed ──────────────────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'and the session already open on the device is still open';
    passed := v_state is null
          and exists (select 1 from erp.device_session ds where ds.id = v_first and ds.ended_at is null);
    detail := coalesce(v_state, (select coalesce(ds.end_reason, 'open') from erp.device_session ds where ds.id = v_first));
    return next;

    -- ── 3. The refusal has its words ────────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'the refusal is registered, so the scanner says what to do instead';
    passed := v_state is null
          and exists (select 1 from erp_ref.resource r
                       where r.key = 'refusal.cloveerp_device_supervisor_is_operator.next_action' and r.locale = 'en');
    detail := coalesce(v_state, 'refusal.cloveerp_device_supervisor_is_operator.next_action');
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_SUPERVISOR_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;
revoke all on function erp_test.supervisor_is_someone_else_suite() from public, anon, authenticated;

create or replace function erp_test.assert_supervisor_is_someone_else_suite()
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
  create temp table if not exists _supervisor_is_someone_else on commit drop as
    select * from erp_test.supervisor_is_someone_else_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _supervisor_is_someone_else;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_SUPERVISOR_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_SUPERVISOR_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('a supervisor is someone else: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_supervisor_is_someone_else_suite() from public, anon, authenticated;

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
