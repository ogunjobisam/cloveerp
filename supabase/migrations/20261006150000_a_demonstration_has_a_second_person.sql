set lock_timeout = '30s';

-- =============================================================================
-- 20261006150000  A demonstration has a second person
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-46). A visitor
-- proposed a payment run and could go no further: erp.approve_payment_run()
-- rightly refuses the person who proposed a run, and a demonstration has one
-- person who can do anything. erp.seed_demo() adds Dana Viewer, who is
-- invited, can never sign in and may only read. So no run raised by hand in a
-- demonstration was ever approved or paid, and the step that shows the
-- product keeps money on two signatures could not be shown.
--
-- The owner decided (4 October, decision 3) that the demonstration gets a
-- second person who can approve payment runs, with a way to switch to them,
-- and that segregation of duties stays. This migration is the person; the
-- next two are the refusal's hint and the switch.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.demonstration_persona: which of a demonstration's people may be
--      acted as. One row per person, by a short code.
--   B. erp.refuse_persona_outside_demonstration(): a trigger that refuses a
--      row outside a demonstration (or in one that is live), and a persona
--      who can sign in or is not a person. Registered as
--      CLOVEERP_PERSONA_OUTSIDE_DEMONSTRATION.
--   C. erp.seed_demo_personas(tenant): Priya Shah, an active person with no
--      sign-in (as Dana Viewer has none), holding the standard Finance role,
--      which may approve payments and post. Made once: a persona somebody
--      removed is not made again. Nothing outside a demonstration.
--   D. erp.ensure_demo_configuration() calls it and says "a second person".
--   E. erp.personas_report() and erp.assert_personas_only_in_demonstrations():
--      a persona outside a demonstration, or one who can sign in, is a
--      finding the build refuses.
--   F. erp_test.demonstration_persona_suite, five cases.
--   G. Every demonstration there is today gains her here, and the migration
--      says which.
--
-- She is one full seat in the demonstration's own seat count, because a seat
-- is derived from the permissions held; a demonstration has no subscription
-- and nothing is billed. Approval steps in a demonstration route to the
-- administrator role, so she changes no document's approval routing.
--
-- On production: two quiet tables are created. Each demonstration (code
-- demo-%) gains one row in erp.app_user, erp.user_role and
-- erp.demonstration_persona. No organisation that is not a demonstration is
-- touched. No hot table is altered.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. Who may be acted as
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists erp.demonstration_persona (
  tenant_id   uuid not null references erp.tenant(id) on delete cascade,
  app_user_id uuid not null,
  code        text not null,
  created_at  timestamptz not null default now(),
  created_by  uuid,
  updated_at  timestamptz not null default now(),
  updated_by  uuid,
  constraint demonstration_persona_pkey primary key (tenant_id, app_user_id),
  constraint demonstration_persona_code_once unique (tenant_id, code),
  constraint demonstration_persona_person_once unique (app_user_id),
  constraint demonstration_persona_user_fk foreign key (tenant_id, app_user_id)
    references erp.app_user(tenant_id, id) on delete cascade,
  constraint demonstration_persona_code_shape check (code ~ '^[a-z][a-z0-9_]*$')
);

comment on table erp.demonstration_persona is
  'The people of a demonstration a visitor may act as (20261006150000, J-46): an active person with no '
  'sign-in, so a step that needs a second person, such as approving a payment run somebody proposed, can '
  'be shown. Refused outside a demonstration by erp.refuse_persona_outside_demonstration().';
comment on column erp.demonstration_persona.app_user_id is
  'The person acted as: an erp.app_user of kind person with no sign-in.';
comment on column erp.demonstration_persona.code is
  'A short name for the persona within its demonstration, such as finance; the order they are offered in.';

insert into erp_meta.table_policy (schema_name, table_name, table_class, note) values
  ('erp', 'demonstration_persona', 'tenant_scoped',
   'Which of a demonstration''s people may be acted as; only in a demonstration.')
on conflict (schema_name, table_name) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- B. Only in a demonstration
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_PERSONA_OUTSIDE_DEMONSTRATION',
  'Acting as somebody else, or giving an organisation a person to act as, outside a demonstration, or as somebody who can sign in.',
  'In an organisation that trades, everybody signs in as themselves, so what the records say each person did is what they did.',
  'Sign in as yourself. To show a step that needs two people, open a demonstration and choose Act as in the account menu.');

create or replace function erp.refuse_persona_outside_demonstration()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- Somebody to act as exists only in a demonstration (20261006150000), and
  -- is somebody who cannot sign in: acting as a person who can would put
  -- your acts in the name of somebody real.
  if not erp.tenant_is_demonstration(new.tenant_id)
     or exists (select 1 from erp.environment e
                 where e.tenant_id = new.tenant_id and e.is_self and e.is_live) then
    raise exception 'CLOVEERP_PERSONA_OUTSIDE_DEMONSTRATION: % is not a demonstration', new.tenant_id
      using errcode = '42501',
            hint = 'Sign in as yourself. To show a step that needs two people, open a demonstration and choose Act as in the account menu.';
  end if;
  if tg_table_name = 'demonstration_persona'
     and not exists (select 1 from erp.app_user u
                      where u.tenant_id = new.tenant_id and u.id = new.app_user_id
                        and u.kind = 'person'::erp.principal_kind
                        and u.auth_user_id is null) then
    raise exception 'CLOVEERP_PERSONA_OUTSIDE_DEMONSTRATION: % can sign in, or is not a person', new.app_user_id
      using errcode = '42501',
            hint = 'Only a person of the demonstration who cannot sign in may be acted as.';
  end if;
  return new;
end;
$$;

revoke all on function erp.refuse_persona_outside_demonstration() from public, anon;

comment on function erp.refuse_persona_outside_demonstration() is
  'Refuses a demonstration persona, or a choice to act as one, outside a demonstration or in one that is live, '
  'and a persona who can sign in or is not a person (20261006150000).';

drop trigger if exists t_demonstration_persona_only_in_demonstration on erp.demonstration_persona;
create trigger t_demonstration_persona_only_in_demonstration
  before insert or update on erp.demonstration_persona
  for each row execute function erp.refuse_persona_outside_demonstration();

-- ─────────────────────────────────────────────────────────────────────────────
-- C. Priya Shah, of Finance
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.seed_demo_personas(p_tenant_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_role  uuid;
  v_user  uuid;
  v_admin uuid;
begin
  -- A demonstration's second person (20261006150000, J-46): somebody a
  -- visitor can act as to approve what they proposed. Once only: a persona
  -- somebody removed belongs to the demonstration as it is now.
  if erp.current_tenant_id() is distinct from p_tenant_id then
    raise exception
      'CLOVEERP_DEMO_TENANT_MISMATCH: the session is in organisation % and this '
      'call names %', coalesce(erp.current_tenant_id()::text, 'nobody'), p_tenant_id
      using errcode = '42501',
      hint = 'Adopt the organisation first: erp.set_active_tenant() for a person, '
             'erp.set_job_tenant() for a worker.';
  end if;
  if not erp.tenant_is_demonstration(p_tenant_id)
     or exists (select 1 from erp.environment e
                 where e.tenant_id = p_tenant_id and e.is_self and e.is_live) then
    return 0;
  end if;
  if exists (select 1 from erp.demonstration_persona dp where dp.tenant_id = p_tenant_id) then
    return 0;
  end if;

  -- Her role is the standard one. A role already on file is never rewritten.
  perform erp.ensure_standard_roles(p_tenant_id);
  select r.id into v_role from erp.role r
   where r.tenant_id = p_tenant_id and r.code = 'finance' and r.status = 'active'::erp.record_status;
  if v_role is null then
    return 0;
  end if;

  insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email)
  values (p_tenant_id, null, 'person'::erp.principal_kind, 'active'::erp.principal_status,
          'Priya Shah', 'priya.shah@example.invalid')
  on conflict (tenant_id, email) do nothing;
  select u.id into v_user from erp.app_user u
   where u.tenant_id = p_tenant_id and u.email = 'priya.shah@example.invalid'
     and u.kind = 'person'::erp.principal_kind and u.auth_user_id is null;
  if v_user is null then
    return 0;
  end if;

  insert into erp.demonstration_persona (tenant_id, app_user_id, code)
  values (p_tenant_id, v_user, 'finance');

  -- Granted as erp.seed_demo() grants Dana Viewer: directly. erp.grant_role()
  -- is for people granting people, and its seat and own-roles checks are
  -- theirs; the grant names the organisation's first administrator.
  select u.id into v_admin
    from erp.app_user u
   where u.tenant_id = p_tenant_id and u.kind = 'person'::erp.principal_kind
     and u.status = 'active'::erp.principal_status and u.id <> v_user
     and erp.has_permission('administration.roles', null, null, null, u.id)
   order by u.created_at, u.id
   limit 1;
  insert into erp.user_role (tenant_id, app_user_id, role_id, valid_from, granted_by, grant_reason)
  values (p_tenant_id, v_user, v_role, current_date, v_admin, 'Demonstration persona (20261006150000)');

  return 1;
end;
$$;

revoke all on function erp.seed_demo_personas(uuid) from public, anon;

comment on function erp.seed_demo_personas(uuid) is
  'A demonstration''s second person, Priya Shah of Finance, with no sign-in, whom a visitor can act as '
  '(20261006150000, J-46). Once per demonstration; nothing outside one. Called by erp.ensure_demo_configuration().';

-- ─────────────────────────────────────────────────────────────────────────────
-- D. A demonstration made, or brought up to date, has her
-- ─────────────────────────────────────────────────────────────────────────────

do $configure$
declare
  v_sig  constant text := 'erp.ensure_demo_configuration(uuid,uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  if erp.seed_demo_supplier_contacts(p_tenant_id) > 0 then
    v_did := v_did || '"supplier order addresses"'::jsonb;
  end if;
$o$;
  v_new  constant text := $n$  if erp.seed_demo_supplier_contacts(p_tenant_id) > 0 then
    v_did := v_did || '"supplier order addresses"'::jsonb;
  end if;

  -- A second person, of Finance, whom a visitor can act as to approve what
  -- they proposed (20261006150000).
  if erp.seed_demo_personas(p_tenant_id) > 0 then
    v_did := v_did || '"a second person"'::jsonb;
  end if;
$n$;
begin
  if strpos(v_src, '20261006150000') > 0 then
    raise notice '% already gives a demonstration its second person; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'e1b8a1e938f4215e1b55b195db882179' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006150000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$configure$;

-- ─────────────────────────────────────────────────────────────────────────────
-- E. Never outside a demonstration
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.personas_report()
returns table(finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  -- Somebody to act as, where nobody may be acted as (20261006150000).
  select 'a persona is held by an organisation that is not a demonstration, or is live',
         t.code, u.display_name
    from erp.demonstration_persona dp
    join erp.tenant t on t.id = dp.tenant_id
    join erp.app_user u on u.tenant_id = dp.tenant_id and u.id = dp.app_user_id
   where not erp.tenant_is_demonstration(dp.tenant_id)
      or exists (select 1 from erp.environment e
                  where e.tenant_id = dp.tenant_id and e.is_self and e.is_live)
  union all
  select 'a persona can sign in, or is not a person',
         t.code, u.display_name
    from erp.demonstration_persona dp
    join erp.tenant t on t.id = dp.tenant_id
    join erp.app_user u on u.tenant_id = dp.tenant_id and u.id = dp.app_user_id
   where u.auth_user_id is not null or u.kind <> 'person'::erp.principal_kind
   order by 1, 2, 3
$$;

revoke all on function erp.personas_report() from public, anon;

comment on function erp.personas_report() is
  'Demonstration personas where none may be: outside a demonstration, in one that is live, or a persona '
  'who can sign in (20261006150000).';

create or replace function erp.assert_personas_only_in_demonstrations()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count  integer;
  v_detail text;
begin
  select count(*), string_agg(format('  %s: %s (%s)', r.finding, r.reference, r.detail), E'\n')
    into v_count, v_detail
    from erp.personas_report() r;
  if v_count > 0 then
    raise exception E'CLOVEERP_PERSONA_OUTSIDE_DEMONSTRATION: % finding(s)\n%', v_count, v_detail
      using errcode = '23514',
            hint = 'Remove the persona: in an organisation that trades everybody acts as themselves.';
  end if;
  return 'personas: only in demonstrations, and none can sign in';
end;
$$;

revoke all on function erp.assert_personas_only_in_demonstrations() from public, anon;

comment on function erp.assert_personas_only_in_demonstrations() is
  'Nobody may be acted as outside a demonstration, nor anybody who can sign in (20261006150000).';

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('personas_only_in_demonstrations', 'Nobody is acted as outside a demonstration', 'assertion', 'platform', 'erp',
   'assert_personas_only_in_demonstrations', '', 'personas_report', '',
   'A demonstration has a second person a visitor may act as, so a step that needs two people can be shown. '
   'In an organisation that trades nobody may be acted as, and nobody who can sign in ever is.',
   true, 915)
on conflict (code) do update set
  title = excluded.title, kind = excluded.kind, scope = excluded.scope,
  schema_name = excluded.schema_name, function_name = excluded.function_name,
  arguments = excluded.arguments, detail_function = excluded.detail_function,
  detail_arguments = excluded.detail_arguments, blurb = excluded.blurb,
  runs_in_ci = excluded.runs_in_ci, seq = excluded.seq;

-- ─────────────────────────────────────────────────────────────────────────────
-- F. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.demonstration_persona_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 5;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  a2       uuid := gen_random_uuid();
  rb       record;
  rc       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_conf   jsonb;
  v_again  jsonb;
  v_people jsonb;
  v_user   uuid;
  v_n      integer;
  v_seat   text;
  v_roles  text;
  v_err    text; v_err2 text;
begin
  begin
    -- ── The fixture: a demonstration ────────────────────────────────────────
    v_step := 'a demonstration configured from nothing';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzpe' || v_tag, 'Demo Persona Suite',
      'admin@demo-zzpe' || v_tag || '.test', 'Persona Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzpe' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    v_conf := erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);

    select count(*), min(dp.app_user_id::text)::uuid into v_n, v_user
      from erp.demonstration_persona dp where dp.tenant_id = rb.tenant_id;
    select string_agg(r.code, ',' order by r.code) into v_roles
      from erp.user_role ur join erp.role r on r.tenant_id = ur.tenant_id and r.id = ur.role_id
     where ur.tenant_id = rb.tenant_id and ur.app_user_id = v_user;

    -- ── 1. Configured, she is there ─────────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'a demonstration configured from nothing has one persona, active, who cannot sign in and holds Finance, and says it added a second person';
    passed := v_state is null and v_n = 1
          and exists (select 1 from erp.app_user u
                       where u.tenant_id = rb.tenant_id and u.id = v_user
                         and u.kind = 'person' and u.status = 'active' and u.auth_user_id is null
                         and u.display_name = 'Priya Shah')
          and v_roles = 'finance'
          and erp.has_permission('finance.approve_payment', null, null, null, v_user)
          and (v_conf -> 'installed') ? 'a second person';
    detail := coalesce(v_state, format('%s persona(s), roles %s, installed %s', v_n, v_roles, v_conf -> 'installed'));
    return next;

    -- ── 2. She is a person of the demonstration ─────────────────────────────
    v_step := 'reading the seats and the people';
    select ps.seat into v_seat from erp.person_seats(rb.tenant_id, v_user) ps;
    v_people := public.erp_principals();
    v_cases := v_cases + 1;
    case_name := 'the persona is a full seat in the demonstration''s own count and is listed among its people';
    passed := v_state is null and v_seat = 'full'
          and exists (select 1 from jsonb_array_elements(v_people) p where (p ->> 'id')::uuid = v_user);
    detail := coalesce(v_state, format('seat %s, %s people listed', v_seat, jsonb_array_length(v_people)));
    return next;

    -- ── 3. Asked again, nothing more; removed, not made again ───────────────
    v_step := 'configuring again, then once more after her access is removed';
    v_again := erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    update erp.app_user set status = 'disabled' where tenant_id = rb.tenant_id and id = v_user;
    v_n := erp.seed_demo_personas(rb.tenant_id);
    v_cases := v_cases + 1;
    case_name := 'configured again nothing is added, and a persona whose access was removed is not made again';
    passed := v_state is null
          and not ((v_again -> 'installed') ? 'a second person')
          and v_n = 0
          and (select count(*) from erp.demonstration_persona dp where dp.tenant_id = rb.tenant_id) = 1
          and (select count(*) from erp.app_user u
                where u.tenant_id = rb.tenant_id and u.email = 'priya.shah@example.invalid') = 1;
    detail := coalesce(v_state, (v_again -> 'installed')::text);
    return next;

    -- ── 4. Never somebody who can sign in ───────────────────────────────────
    v_step := 'making the administrator, who signs in, a persona';
    begin
      insert into erp.demonstration_persona (tenant_id, app_user_id, code)
      values (rb.tenant_id, rb.admin_user_id, 'admin');
      v_err := 'made';
    exception when others then v_err := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'a persona naming somebody who can sign in is refused';
    passed := v_state is null and v_err like 'CLOVEERP_PERSONA_OUTSIDE_DEMONSTRATION%';
    detail := coalesce(v_state, v_err);
    return next;

    -- ── 5. Not in an ordinary organisation ──────────────────────────────────
    v_step := 'an organisation that is not a demonstration';
    perform set_config('request.jwt.claims', '', true);
    select * into rc from erp.provision_tenant(
      'zzpe-' || v_tag, 'Not A Demo Persona Suite', 'admin@zzpe-' || v_tag || '.test', 'Plain Admin');
    update erp.environment set is_live = false where tenant_id = rc.tenant_id and is_self;
    insert into auth.users (id, email) values (a2, 'admin@zzpe-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(rc.admin_token);
    v_conf := erp.ensure_demo_configuration(rc.tenant_id, rc.admin_user_id);
    insert into erp.app_user (tenant_id, kind, status, display_name, email)
    values (rc.tenant_id, 'person', 'active', 'Nobody Signs In', 'nobody@zzpe-' || v_tag || '.test')
    returning id into v_user;
    begin
      insert into erp.demonstration_persona (tenant_id, app_user_id, code)
      values (rc.tenant_id, v_user, 'finance');
      v_err2 := 'made';
    exception when others then v_err2 := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'an organisation that is not a demonstration is given no persona, and one written there is refused';
    passed := v_state is null and not ((v_conf -> 'installed') ? 'a second person')
          and erp.seed_demo_personas(rc.tenant_id) = 0
          and not exists (select 1 from erp.demonstration_persona dp where dp.tenant_id = rc.tenant_id)
          and v_err2 like 'CLOVEERP_PERSONA_OUTSIDE_DEMONSTRATION%';
    detail := coalesce(v_state, concat_ws(' / ', (v_conf -> 'installed')::text, v_err2));
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
    raise exception 'CLOVEERP_DEMONSTRATION_PERSONA_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.demonstration_persona_suite() from public, anon;

comment on function erp_test.demonstration_persona_suite() is
  'A demonstration has a second person (20261006150000): Priya Shah of Finance, who cannot sign in, made '
  'once, a full seat among its people, never somebody who can sign in, and never outside a demonstration.';

create or replace function erp_test.assert_demonstration_persona_suite()
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
    from erp_test.demonstration_persona_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_DEMONSTRATION_PERSONA_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A demonstration would have nobody to approve what its visitor proposed. Read the case that failed.';
  end if;
  if v_total <> 5 then
    raise exception 'CLOVEERP_DEMONSTRATION_PERSONA_SUITE_SHRANK: % case(s), expected 5', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('demonstration persona: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_demonstration_persona_suite() from public, anon;

comment on function erp_test.assert_demonstration_persona_suite() is
  'A demonstration has a second person to act as, and only a demonstration (20261006150000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- G. Every demonstration there is today, and said
-- ─────────────────────────────────────────────────────────────────────────────

-- The new table's row security, attribution and audit first, so the rows
-- written below are kept like any other. Both are idempotent and run again
-- at the end.
select erp.apply_row_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();

do $seed$
declare
  r   record;
  v_n integer;
begin
  for r in select tn.id, tn.code from erp.tenant tn
            where tn.deleted_at is null and tn.code like 'demo-%' order by tn.code loop
    perform erp_meta.act_in_tenant(r.id);
    v_n := erp.seed_demo_personas(r.id);
    set constraints all immediate;
    if v_n > 0 then
      raise warning 'demonstration persona: Priya Shah of Finance added to %', r.code;
    end if;
  end loop;
  perform erp_meta.stop_acting_in_tenant();
end
$seed$;

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
