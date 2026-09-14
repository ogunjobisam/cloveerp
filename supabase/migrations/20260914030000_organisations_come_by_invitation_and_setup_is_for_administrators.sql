-- Organisations come by invitation, and setup is for administrators.
--
-- On 13 and 14 September the owner opened cloveerp.com on a phone as somebody
-- freshly invited, and asked for two things:
--
--   "User was invited to a tenant and so should only see the company he's
--    been invited to. I need to protect against random users creating an
--    organisation or seeding data."
--
--   "Only Admins should see this setup."
--
-- and, the next morning, that the platform owner should be able to reopen
-- self-service organisation creation later.
--
-- Until this file anybody who signed up could make an organisation through
-- public.erp_onboard_tenant(), or a demonstration organisation through
-- public.erp_seed_demo(), and every organisation can send invitation emails.
-- The desk offered both to everybody signed in with no organisation. So:
--
--   1. A platform-wide switch, self-service sign-up. erp_meta.platform_setting
--      holds it, one row keyed self_service.organisations, closed. Only a
--      platform owner changes it, through
--      public.erp_platform_set_self_service_organisations(open, reason), which
--      refuses a change with no reason and writes the platform audit on every
--      change. erp.self_service_organisations_open() reads it, and so does
--      public.erp_self_service_organisations_open() for the gate, which needs
--      to know which screen to draw for somebody with no organisation.
--
--   2. While it is closed, the doors that make an organisation or demonstration
--      data refuse anybody who is not a platform operator or owner:
--        public.erp_onboard_tenant         CLOVEERP_ORGANISATION_BY_INVITATION_ONLY
--        public.erp_seed_demo              CLOVEERP_DEMO_FOR_PLATFORM_STAFF_ONLY
--        public.erp_seed_demo_history      CLOVEERP_DEMO_FOR_PLATFORM_STAFF_ONLY
--        public.erp_seed_demo_operations   CLOVEERP_DEMO_FOR_PLATFORM_STAFF_ONLY
--      The last is here because it calls erp.seed_demo_master_data for its
--      caller. public.erp_seed_demo_configuration is not: it writes sample
--      classification axes into the caller's own organisation under
--      administration.configure and makes no organisation and no trading.
--      Organisations otherwise come from the platform console's "Onboard a
--      company" (public.erp_platform_onboard_company, unchanged) or by
--      invitation into an existing one. While the switch is open every door
--      behaves as it did before this file, and erp.onboard_tenant() still
--      applies the per-sign-in limit 20260913120000 gave it.
--
--   3. Trusted sessions are unaffected: migrations, suites, the build's seed
--      and the platform's own jobs. erp.session_is_trusted() asks which role is
--      running, and inside a SECURITY DEFINER frame that is the owner, so the
--      test admits everybody (20260913070000 met it in propose_renewals,
--      20260913120000 wrote it down). The refusal therefore lives in two
--      SECURITY INVOKER erp functions every door calls on its first line,
--      erp.require_organisation_by_invitation() and
--      erp.require_demo_for_platform_staff(), where the trust test sees the
--      role that connected. Neither names anything in erp_meta, which a
--      signed-in caller cannot use (20260913090000): what they ask of the
--      platform they ask through erp.caller_may_create_organisations(), which
--      runs as its owner, reads the switch, and for a platform operator or
--      owner calls erp_meta.require_platform('operator'), the console's own
--      gate, which binds the sign-in to its staff row the first time.
--
--      public.erp_seed_demo_history and public.erp_seed_demo_operations were
--      SECURITY DEFINER wrappers, so their trust test would have admitted
--      everybody too. Both now run as the caller. What they wrap still runs as
--      its owner: erp.seed_demo_operations() already did, and
--      erp.seed_demo_history() becomes SECURITY DEFINER here, which is exactly
--      how it ran when reached through its door ("definer so the tables the
--      bridges write are reachable", 20260905010000). Its gate is unchanged:
--      erp.authorise('master_data.write') in its own body, refused in a live
--      environment, confined to the organisation in context.
--
--   4. The write register says what the doors now reach. erp_onboard_tenant
--      was registered as needing no gate because it is the bootstrap; it now
--      reaches erp_meta.require_platform(), so its ungated_because is cleared
--      (erp.public_api_report() refuses a door that says it needs no gate and
--      reaches one) and every row's rationale names the switch.
--
--   5. public.erp_setup_progress() and public.erp_setup_walkthrough() authorise
--      administration.configure first, and are VOLATILE because authorising
--      writes an access-decision row (erp.assert_authorising_doors_are_volatile).
--      The desk shows the Settings home's setup order and each screen's
--      walkthrough button only to the same people; the database refuses
--      regardless.
--
--   6. erp_test.grant_suite drives the history door as an authenticated
--      administrator, to prove the spine runs on grants. It still does: its
--      administrator is now also a platform operator, which grants nothing in
--      an organisation (only an owner is overridden in erp.authorise), and is
--      undone with the rest of the case. No other suite or build script calls
--      these doors as a signed-in role: erp_test.nordwind_fixture calls
--      erp_onboard_tenant from the migration role with claims set, which is a
--      trusted session, and supabase/ci/seed_demo.sql calls the erp functions
--      directly as the build role.
--
--   7. erp_test.invitation_only_suite proves the switch, the refusals, who may
--      pass them, the setup doors, and that every such door asks first.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The switch
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists erp_meta.platform_setting (
  key        text primary key check (key ~ '^[a-z][a-z0-9_.]*$'),
  value      jsonb not null,
  reason     text not null,
  updated_at timestamptz not null default now(),
  updated_by uuid
);

comment on table erp_meta.platform_setting is
  'Platform-wide settings a platform owner changes from the console, each with '
  'the reason it was last changed, when, and by which staff member '
  '(erp_meta.platform_staff.id; null for the row a migration wrote). Every change '
  'is also written to erp_meta.platform_audit. No organisation owns a row.';

comment on column erp_meta.platform_setting.updated_by is
  'The erp_meta.platform_staff id of the owner who last changed the setting, or '
  'null when a migration wrote it.';

select erp_meta.register_table('erp_meta', 'platform_setting', 'platform_internal',
  'Platform-wide settings, such as whether self-service sign-up is open. Reachable '
  'only through SECURITY DEFINER functions; changed only by a platform owner.');

revoke all on table erp_meta.platform_setting from public, anon, authenticated;

insert into erp_meta.platform_setting (key, value, reason)
values ('self_service.organisations', 'false'::jsonb,
        'Closed when the switch was introduced: organisations come from the platform '
        'console or by invitation into an existing organisation.')
on conflict (key) do nothing;

create or replace function erp.self_service_organisations_open()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select s.value = 'true'::jsonb
       from erp_meta.platform_setting s
      where s.key = 'self_service.organisations'),
    false)
$$;

comment on function erp.self_service_organisations_open() is
  'Whether self-service sign-up is open: anybody signed in may make an organisation '
  'or a demonstration, not only platform operators and owners. False when the '
  'setting is absent. Runs as its owner because the setting is in erp_meta.';

revoke all on function erp.self_service_organisations_open() from public, anon;

do $closed$
begin
  if erp.self_service_organisations_open() then
    raise exception 'CLOVEERP_SELF_SERVICE_OPEN_BY_DEFAULT: self-service sign-up is open at the end of the migration that introduces it closed'
      using hint = 'The self_service.organisations setting must say false until a platform owner opens it from the console.';
  end if;
end
$closed$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Who may make an organisation, asked where each question can be answered
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.caller_may_create_organisations()
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v erp_meta.platform_staff;
begin
  if erp.self_service_organisations_open() then
    return true;
  end if;

  v := erp_meta.platform_actor();
  if v.id is null
     or erp_meta.platform_rank(v.staff_role) < erp_meta.platform_rank('operator') then
    return false;
  end if;

  -- The gate every console door opens with, for the staff member it admits. It cannot refuse
  -- here, having found the same row; it binds the sign-in to that row the
  -- first time it is seen, as every console door does.
  perform erp_meta.require_platform('operator');
  return true;
end;
$$;

comment on function erp.caller_may_create_organisations() is
  'True when self-service sign-up is open, or the signed-in caller is a platform '
  'operator or owner. Runs as its owner because both answers are in erp_meta; it '
  'answers one yes or no about the caller. The trust test is not here: inside this '
  'frame every session would look trusted.';

revoke all on function erp.caller_may_create_organisations() from public, anon;

create or replace function erp.require_organisation_by_invitation()
returns void
language plpgsql
volatile
security invoker
set search_path = ''
as $$
begin
  -- Migrations, suites and the jobs the platform runs make organisations
  -- too. Asked here, in the frame of the caller, because only here does the
  -- answer describe the role that connected.
  if erp.session_is_trusted() then
    return;
  end if;

  if erp.caller_may_create_organisations() then
    return;
  end if;

  raise exception 'CLOVEERP_ORGANISATION_BY_INVITATION_ONLY: organisations come by invitation, and this account is not Clove ERP staff who may create one'
    using errcode = '42501',
          hint = 'Ask the organisation you work with to invite you. Clove ERP staff create new organisations from the platform console.';
end;
$$;

comment on function erp.require_organisation_by_invitation() is
  'Refuses making an organisation unless the session is trusted, self-service '
  'sign-up is open, or the caller is a platform operator or owner. SECURITY '
  'INVOKER so the trust test sees the role that connected; called on the first '
  'line of public.erp_onboard_tenant().';

revoke all on function erp.require_organisation_by_invitation() from public, anon;

create or replace function erp.require_demo_for_platform_staff()
returns void
language plpgsql
volatile
security invoker
set search_path = ''
as $$
begin
  if erp.session_is_trusted() then
    return;
  end if;

  if erp.caller_may_create_organisations() then
    return;
  end if;

  raise exception 'CLOVEERP_DEMO_FOR_PLATFORM_STAFF_ONLY: demonstration organisations and their data are made by Clove ERP staff'
    using errcode = '42501',
          hint = 'Demo organisations are created by Clove ERP staff from the platform console.';
end;
$$;

comment on function erp.require_demo_for_platform_staff() is
  'Refuses making a demonstration organisation or demonstration data unless the '
  'session is trusted, self-service sign-up is open, or the caller is a platform '
  'operator or owner. SECURITY INVOKER so the trust test sees the role that '
  'connected; called on the first line of every demo door.';

revoke all on function erp.require_demo_for_platform_staff() from public, anon;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp', 'self_service_organisations_open',
   'Reads the one platform-wide self-service sign-up setting in erp_meta, which no '
   'organisation owns and a signed-in caller cannot read. Answers yes or no about '
   'the platform and nothing about any organisation or person.'),
  ('erp', 'caller_may_create_organisations',
   'Reads the self-service sign-up setting and the caller''s own platform staff row, '
   'both in erp_meta, and answers yes or no about the caller. For an operator or '
   'owner it calls erp_meta.require_platform(''operator''), which binds the sign-in '
   'to its staff row the first time. Reached from erp.require_organisation_by_invitation '
   'and erp.require_demo_for_platform_staff, which run as the caller and test trust '
   'there, because this frame would call every session trusted.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The two doors for the switch
-- ═════════════════════════════════════════════════════════════════════════════

-- Any signed-in caller may ask: the gate draws the invitation card or the
-- create card from the answer. It runs as the caller and reads through the
-- definer above, so it names nothing in erp_meta.
create or replace function public.erp_self_service_organisations_open()
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$ select erp.self_service_organisations_open() $$;

comment on function public.erp_self_service_organisations_open() is
  'Whether self-service sign-up is open, for the gate: one platform-wide yes or no, '
  'nothing about any organisation. The doors that make organisations and demos '
  'check it themselves.';

revoke all on function public.erp_self_service_organisations_open() from public, anon;
grant execute on function public.erp_self_service_organisations_open() to authenticated, service_role;

create or replace function public.erp_platform_set_self_service_organisations(p_open boolean, p_reason text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v     erp_meta.platform_staff;
  v_was boolean;
  v_row erp_meta.platform_setting;
begin
  v := erp_meta.require_platform('owner');

  if p_open is null then
    raise exception 'CLOVEERP_SELF_SERVICE_SWITCH_UNSTATED: say whether self-service sign-up is to be open or closed'
      using errcode = '22004',
            hint = 'Choose open or closed, and say why.';
  end if;

  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'CLOVEERP_SELF_SERVICE_SWITCH_NEEDS_REASON: opening or closing self-service sign-up is recorded with its reason'
      using errcode = '22023',
            hint = 'Say why sign-up is being opened or closed. The reason is kept with the setting and in the platform log.';
  end if;

  v_was := erp.self_service_organisations_open();

  insert into erp_meta.platform_setting (key, value, reason, updated_at, updated_by)
  values ('self_service.organisations', to_jsonb(p_open), btrim(p_reason), now(), v.id)
  on conflict (key) do update
     set value = excluded.value, reason = excluded.reason,
         updated_at = excluded.updated_at, updated_by = excluded.updated_by
  returning * into v_row;

  perform erp_meta.platform_log(
    v,
    case when p_open then 'platform.self_service_organisations_opened'
         else 'platform.self_service_organisations_closed' end,
    null, 'self_service.organisations', btrim(p_reason),
    jsonb_build_object('open', p_open, 'was_open', v_was));

  return jsonb_build_object('open', p_open, 'reason', v_row.reason, 'updated_at', v_row.updated_at);
end;
$$;

comment on function public.erp_platform_set_self_service_organisations(boolean, text) is
  'Opens or closes self-service sign-up. Platform owner only; a reason is required, '
  'kept with the setting and written to the platform log. Returns {open, reason, '
  'updated_at}.';

revoke all on function public.erp_platform_set_self_service_organisations(boolean, text) from public, anon;
grant execute on function public.erp_platform_set_self_service_organisations(boolean, text) to authenticated, service_role;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('public', 'erp_platform_set_self_service_organisations',
   'Platform owner door, gated by erp_meta.require_platform(''owner'') on its first line. '
   'Runs as its owner because erp_meta is sealed to a signed-in caller. Writes one '
   'platform setting and its platform audit row.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_platform_set_self_service_organisations', 'erp_meta.require_platform',
   'Opens or closes self-service sign-up for the whole platform. Platform owner, on the '
   'first line; refuses a change without a reason; writes the setting and the platform log.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The doors that make an organisation or demonstration data ask first
-- ═════════════════════════════════════════════════════════════════════════════

-- Same signature and return type as 20260829180000, so the grants stay. The
-- language changes from sql to plpgsql so the refusal can come first.
create or replace function public.erp_onboard_tenant(p_name text, p_code text)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
begin
  perform erp.require_organisation_by_invitation();
  return erp.onboard_tenant(p_name, p_code);
end;
$$;

comment on function public.erp_onboard_tenant(text, text) is
  'Creates an organisation with the signed-in caller as its first administrator. '
  'While self-service sign-up is closed only platform operators and owners may; '
  'everybody else is refused with CLOVEERP_ORGANISATION_BY_INVITATION_ONLY.';

-- The body 20260905010000 wrote, with the refusal before anything else.
do $seed_demo$
declare
  v_sig    text := 'public.erp_seed_demo()';
  v_def    text := pg_get_functiondef('public.erp_seed_demo()'::regprocedure);
  v_needle text := E'begin\n  v_base := erp.seed_demo();\n';
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not begin by calling erp.seed_demo exactly once, so it is not the 20260905010000 body', v_sig
      using hint = 'A later migration changed public.erp_seed_demo(). Read its definition and patch that body, rather than restating this one.';
  end if;
  if position('require_demo_for_platform_staff' in v_def) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % already asks whether its caller may seed a demo', v_sig
      using hint = 'The refusal is already in place; this block must not add it twice.';
  end if;
  execute replace(v_def, v_needle,
    E'begin\n'
 || E'  -- While self-service sign-up is closed a demo organisation is for platform\n'
 || E'  -- staff (20260914030000). Asked first, in the frame of the caller.\n'
 || E'  perform erp.require_demo_for_platform_staff();\n\n'
 || E'  v_base := erp.seed_demo();\n');
  if position('perform erp.require_demo_for_platform_staff();' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % was re-emitted without its refusal', v_sig
      using hint = 'The replacement did not land. Compare the needle with pg_get_functiondef() of the door.';
  end if;
end
$seed_demo$;

-- Same signature, defaults and return type as 20260905010000, so the grants
-- stay. It ran as its owner; it runs as the caller now so its trust test sees
-- who connected, and what it wraps runs as its owner instead.
alter function erp.seed_demo_history(date, date, numeric) security definer;

create or replace function public.erp_seed_demo_history(
  p_from date default null, p_to date default null, p_scale numeric default 1)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
begin
  perform erp.require_demo_for_platform_staff();
  return erp.seed_demo_history(p_from, p_to, p_scale);
end;
$$;

comment on function public.erp_seed_demo_history(date, date, numeric) is
  'Builds a few days of demonstration trading history and returns {done, next_from, '
  'built, notes}. Call again with next_from until done. Refused in a live '
  'environment, and, while self-service sign-up is closed, to anybody who is not '
  'a platform operator or owner.';

-- Same signature and return type as 20260830101002. erp.seed_demo_operations()
-- already runs as its owner.
create or replace function public.erp_seed_demo_operations()
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
begin
  perform erp.require_demo_for_platform_staff();
  return erp.seed_demo_operations();
end;
$$;

comment on function public.erp_seed_demo_operations() is
  'Builds demonstration operating history in the organisation in context. Refused '
  'in a live environment, and, while self-service sign-up is closed, to anybody who '
  'is not a platform operator or owner.';

do $allowances$
declare
  v_n integer;
begin
  -- The two wrappers no longer run as their owner, so their rows go.
  delete from erp_meta.security_definer_allowance
   where schema_name = 'public' and function_name in ('erp_seed_demo_history', 'erp_seed_demo_operations');

  insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
    ('erp', 'seed_demo_history',
     'Demonstration history builder. Gated by erp.authorise(master_data.write) in its own '
     'body, refused in a live environment, and confined to the organisation in context by '
     'erp.require_tenant_id(). Runs as its owner because the bridges it drives write tables '
     'the caller cannot reach directly; its door ran as its owner for that reason until '
     '20260914030000, and now runs as the caller so its trust test sees who connected. '
     'Signed-in callers reach it only through public.erp_seed_demo_history(), which admits '
     'platform operators and owners, or anybody while self-service sign-up is open.')
  on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

  update erp_meta.security_definer_allowance
     set rationale = 'Creates a tenant for a caller who has no principal and therefore no tenant '
                     'context, so row-level security has nothing to scope to. Writes only rows '
                     'belonging to the tenant it is creating, and binds it to auth.uid(). Before it '
                     'writes, it reads only the organisations auth.uid() is already an active member '
                     'of, when each was made and whether it is live, to refuse a caller who made one '
                     'in the last day or holds two that are not live. Signed-in callers reach it only '
                     'through public.erp_onboard_tenant(), which admits platform operators and owners, '
                     'or anybody while self-service sign-up is open.'
   where schema_name = 'erp' and function_name = 'onboard_tenant';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'CLOVEERP_ALLOWANCE_NOT_MOVED: % row(s) updated for erp.onboard_tenant, expected 1', v_n
      using hint = 'The allowance row for erp.onboard_tenant is missing or duplicated; restore it before changing its rationale.';
  end if;

  update erp_meta.security_definer_allowance
     set rationale = 'Builds a demonstration tenant for the signed-in caller, reusing one they already '
                     'hold, so there is no tenant context to run under yet. Writes only rows belonging '
                     'to the tenant it is creating, and binds it to auth.uid(). Signed-in callers reach '
                     'it only through public.erp_seed_demo(), which admits platform operators and '
                     'owners, or anybody while self-service sign-up is open.'
   where schema_name = 'erp' and function_name = 'seed_demo';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'CLOVEERP_ALLOWANCE_NOT_MOVED: % row(s) updated for erp.seed_demo, expected 1', v_n
      using hint = 'The allowance row for erp.seed_demo is missing or duplicated; restore it before changing its rationale.';
  end if;
end
$allowances$;

-- The register tells the truth about each door. erp_onboard_tenant reaches the
-- platform's gate now, so it no longer says it needs none.
do $register$
declare
  v_n integer;
begin
  with truth (function_name, rationale) as (values
    ('erp_onboard_tenant',
     'Creates a new organisation with the signed-in caller as its first administrator. '
     'erp.require_organisation_by_invitation() comes first: while self-service sign-up is '
     'closed it admits trusted sessions and platform operators and owners, through '
     'erp_meta.require_platform(''operator''), and refuses everybody else; while open, '
     'anybody signed in, within the per-sign-in onboarding limit. It refuses a subject '
     'without an email.'),
    ('erp_seed_demo',
     'Builds a demonstration organisation for the signed-in caller and configures it. '
     'erp.require_demo_for_platform_staff() comes first: while self-service sign-up is '
     'closed only trusted sessions and platform operators and owners pass.'),
    ('erp_seed_demo_history',
     'Writes a few days of demonstration documents through the spine, under '
     'master_data.write, never in a live environment. erp.require_demo_for_platform_staff() '
     'comes first: while self-service sign-up is closed only trusted sessions and platform '
     'operators and owners pass.'),
    ('erp_seed_demo_operations',
     'Builds demonstration operating history in the organisation in context, under '
     'master_data.write, never in a live environment. erp.require_demo_for_platform_staff() '
     'comes first: while self-service sign-up is closed only trusted sessions and platform '
     'operators and owners pass.')
  ), updated as (
    update erp_meta.public_write_allowance w
       set rationale = r.rationale, ungated_because = null
      from truth r
     where w.function_name = r.function_name
    returning 1
  )
  select count(*) into v_n from updated;

  if v_n <> 4 then
    raise exception 'CLOVEERP_REGISTER_INCOMPLETE: % of 4 register rows were found for the doors that make organisations and demonstrations', v_n
      using hint = 'Each of erp_onboard_tenant, erp_seed_demo, erp_seed_demo_history and erp_seed_demo_operations must have a row in erp_meta.public_write_allowance.';
  end if;
end
$register$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The setup order is for the people who configure the organisation
-- ═════════════════════════════════════════════════════════════════════════════

alter function public.erp_setup_progress() volatile;
alter function public.erp_setup_walkthrough(text) volatile;

do $setup$
declare
  v_sig    text;
  v_def    text;
  v_needle text := E'begin\n  perform erp.require_tenant_id();\n';
begin
  foreach v_sig in array array['public.erp_setup_progress()', 'public.erp_setup_walkthrough(text)'] loop
    v_def := pg_get_functiondef(v_sig::regprocedure);
    if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
      raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not begin by asking for its organisation exactly once, so it is not the 20260913020000 body', v_sig
        using hint = 'A later migration changed the setup door. Read its definition and patch that body, rather than restating this one.';
    end if;
    if position('administration.configure' in v_def) > 0 then
      raise exception 'CLOVEERP_BODY_UNRECOGNISED: % already authorises administration.configure', v_sig
        using hint = 'The gate is already in place; this block must not add it twice.';
    end if;
    execute replace(v_def, v_needle,
      E'begin\n'
   || E'  -- The setup order is for the people who configure the organisation\n'
   || E'  -- (20260914030000).\n'
   || E'  perform erp.authorise(''administration.configure'');\n'
   || E'  perform erp.require_tenant_id();\n');
    if position('perform erp.authorise(''administration.configure'');' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
      raise exception 'CLOVEERP_BODY_UNRECOGNISED: % was re-emitted without its gate', v_sig
        using hint = 'The replacement did not land. Compare the needle with pg_get_functiondef() of the door.';
    end if;
  end loop;
end
$setup$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_setup_progress', 'erp.authorise',
   'Part 22. Reads every Settings screen in setup order with its progress, under '
   'administration.configure. It writes nothing but the access-decision row authorising '
   'records, which is why it is VOLATILE and on this register.'),
  ('erp_setup_walkthrough', 'erp.authorise',
   'Part 22. Reads one Settings screen''s walkthrough, under administration.configure. It '
   'writes nothing but the access-decision row authorising records, which is why it is '
   'VOLATILE and on this register.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

comment on function public.erp_setup_progress() is
  'Part 22. Every Settings screen in setup order with how far along it is and '
  'the next step on it, for the Settings home. Under administration.configure.';

comment on function public.erp_setup_walkthrough(text) is
  'Part 22. The walkthrough for one Settings screen: its place in the setup '
  'order, and every step with the evidence, the organisation''s ticks, whether '
  'the caller may take it, and what it still waits on. Under administration.configure.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The refusals, in the register the desk reads
-- ═════════════════════════════════════════════════════════════════════════════

select erp.register_refusal('CLOVEERP_ORGANISATION_BY_INVITATION_ONLY',
  'Creating an organisation from an account that is not Clove ERP staff, while self-service sign-up is closed.',
  'Organisations come by invitation into an existing organisation, or from the platform console, so nobody can make an organisation, and send invitations from it, just by signing up.',
  'Ask the organisation you work with to invite you. Clove ERP staff create new organisations from the platform console.');

select erp.register_refusal('CLOVEERP_DEMO_FOR_PLATFORM_STAFF_ONLY',
  'Creating a demonstration organisation or demonstration data from an account that is not Clove ERP staff, while self-service sign-up is closed.',
  'A demonstration organisation is still an organisation, and demonstration data fills one with documents nobody entered, so they are made by staff unless the platform owner has opened sign-up.',
  'Demo organisations are created by Clove ERP staff from the platform console.');

select erp.register_refusal('CLOVEERP_SELF_SERVICE_SWITCH_NEEDS_REASON',
  'Opening or closing self-service sign-up without saying why.',
  'Whether anybody may make an organisation is a decision about the whole platform, and the next owner to look needs to know why it stands as it does.',
  'Say why sign-up is being opened or closed. The reason is kept with the setting and in the platform log.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The grant suite's administrator is a platform operator
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Its fifth case builds five days of history through public.erp_seed_demo_history
-- as an authenticated administrator, then walks a purchase order through the
-- invoker doors, to prove a caller holding grants and nothing else can. Demo
-- data is for platform staff while sign-up is closed, so that administrator is
-- now also a platform operator. An operator is given no permission in any
-- organisation (erp.authorise overrides only for an owner), so the spine still
-- runs on the grants alone. The staff row is undone with the rest of the case.

do $grant$
declare
  v_sig    text := 'erp_test.grant_suite()';
  v_def    text := pg_get_functiondef('erp_test.grant_suite()'::regprocedure);
  v_needle text := E'    perform erp.claim_invitation(v_token);\n\n    execute ''set local role authenticated'';\n';
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_GRANT_SUITE_UNRECOGNISED: % does not claim its invitation and then sign in as authenticated exactly once', v_sig
      using hint = 'A later migration changed erp_test.grant_suite(). Read its definition and patch that body.';
  end if;
  if position('platform_staff' in v_def) > 0 then
    raise exception 'CLOVEERP_GRANT_SUITE_UNRECOGNISED: % already makes platform staff', v_sig
      using hint = 'The operator is already in place; this block must not add it twice.';
  end if;
  execute replace(v_def, v_needle,
    E'    perform erp.claim_invitation(v_token);\n'
 || E'    -- Demonstration history is for platform staff while self-service sign-up\n'
 || E'    -- is closed (20260914030000). This case proves grants, not that rule, so\n'
 || E'    -- the administrator is also a platform operator, which grants nothing in\n'
 || E'    -- an organisation. Undone with the rest of the case.\n'
 || E'    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)\n'
 || E'    values (''admin@zz-grant.test'', ''00000000-0000-4000-8000-0000000000a1'', ''Grant Suite Operator'', ''operator'');\n'
 || E'\n'
 || E'    execute ''set local role authenticated'';\n');
  if position('Grant Suite Operator' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_GRANT_SUITE_UNRECOGNISED: % was re-emitted without its operator', v_sig
      using hint = 'The replacement did not land. Compare the needle with pg_get_functiondef() of the suite.';
  end if;
end
$grant$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. The suite, calling the doors as the data API does
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.invitation_only_call(
  p_subject uuid, p_door text, p_text text default null, p_open boolean default null, p_date date default null)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_owner   text := current_user;
  v_outcome jsonb;
  v_state   text;
  v_message text;
begin
  if p_door not in ('erp_onboard_tenant', 'erp_seed_demo', 'erp_seed_demo_history', 'erp_seed_demo_operations',
                    'erp_self_service_organisations_open', 'erp_platform_set_self_service_organisations',
                    'erp_setup_progress', 'erp_setup_walkthrough') then
    raise exception 'CLOVEERP_SUITE_HELPER_MISUSED: % is not a door erp_test.invitation_only_suite calls', p_door
      using hint = 'Call one of the doors the helper names.';
  end if;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', p_subject, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    case p_door
      when 'erp_onboard_tenant' then
        v_outcome := public.erp_onboard_tenant('Invitation Suite ' || p_text, p_text);
      when 'erp_seed_demo' then
        v_outcome := public.erp_seed_demo();
      when 'erp_seed_demo_history' then
        v_outcome := public.erp_seed_demo_history(p_date, null, 1);
      when 'erp_seed_demo_operations' then
        v_outcome := public.erp_seed_demo_operations();
      when 'erp_self_service_organisations_open' then
        v_outcome := to_jsonb(public.erp_self_service_organisations_open());
      when 'erp_platform_set_self_service_organisations' then
        v_outcome := public.erp_platform_set_self_service_organisations(p_open, p_text);
      when 'erp_setup_progress' then
        v_outcome := public.erp_setup_progress();
      when 'erp_setup_walkthrough' then
        v_outcome := public.erp_setup_walkthrough(p_text);
    end case;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_message = message_text;
  end;
  execute format('set local role %I', v_owner);

  return jsonb_build_object('outcome', v_outcome, 'state', v_state, 'message', left(v_message, 240));
end;
$$;
revoke all on function erp_test.invitation_only_call(uuid, text, text, boolean, date) from public, anon, authenticated;

comment on function erp_test.invitation_only_call(uuid, text, text, boolean, date) is
  'Suite helper: calls one door as the given sign-in, in the authenticated role, and '
  'returns {outcome, state, message}. Returns to the calling role before it returns.';

create or replace function erp_test.invitation_only_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tag       text := substr(md5(gen_random_uuid()::text), 1, 8);
  v_person    uuid := gen_random_uuid();  -- a person with no organisation
  v_later     uuid := gen_random_uuid();  -- another, who arrives once it has closed again
  v_operator  uuid := gen_random_uuid();  -- a platform operator
  v_support   uuid := gen_random_uuid();  -- platform support
  v_owner_sub uuid := gen_random_uuid();  -- a platform owner
  v_trusted   uuid := gen_random_uuid();  -- a subject a trusted session onboards for
  v_admin     uuid := gen_random_uuid();  -- the administrator of a provisioned organisation
  v_member    uuid := gen_random_uuid();  -- a member of it who holds no permission
  rx          record;
  v_state text;
  v_open_before  boolean := erp.self_service_organisations_open();
  v_audit_before bigint  := (select count(*) from erp_meta.platform_audit pa
                              where pa.action in ('platform.self_service_organisations_opened',
                                                  'platform.self_service_organisations_closed'));
  v_member_token text;
  v_screen       text;
  v_absent_closed boolean;
  v_row_closed    boolean;
  v_p_made        integer;
  v_provisioned   uuid;
  v_t_onboard     jsonb;
  v_t_msg         text;
  v_after_operator boolean;
  v_after_blank    boolean;
  v_after_open     boolean;
  v_after_close    boolean;
  v_audit          jsonb;
  v_audit_new      bigint;
  -- the answers, each {outcome, state, message}
  c_p_onboard jsonb; c_p_demo jsonb; c_p_history jsonb; c_p_operations jsonb; c_p_asks jsonb;
  c_s_onboard jsonb; c_s_demo jsonb;
  c_o_onboard jsonb; c_o_demo jsonb; c_o_history jsonb;
  c_a_progress jsonb; c_a_walk jsonb; c_m_progress jsonb; c_m_walk jsonb;
  c_o_switch jsonb; c_w_blank jsonb; c_w_null jsonb; c_w_open jsonb;
  c_p_asks_open jsonb; c_p_onboard_open jsonb; c_p_demo_open jsonb; c_p_again jsonb;
  c_w_close jsonb; c_p2_onboard jsonb; c_p_history_closed jsonb;
  v_first      boolean;
  v_first_text text;
begin
  begin
    -- Nobody signed in and no organisation declared, whatever the transaction
    -- this runs in had set.
    perform set_config('request.jwt.claims', '', true);
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('erp.job_principal_id', '', true);

    -- Absent reads closed. The fixture starts from closed, whatever the
    -- setting on this platform says.
    delete from erp_meta.platform_setting where key = 'self_service.organisations';
    v_absent_closed := not erp.self_service_organisations_open();
    insert into erp_meta.platform_setting (key, value, reason)
    values ('self_service.organisations', 'false'::jsonb, 'Invitation suite: closed to begin with');
    v_row_closed := not erp.self_service_organisations_open();

    insert into auth.users (id, email) values
      (v_person, 'person@zzinv-'   || v_tag || '.test'),
      (v_later, 'later@zzinv-'    || v_tag || '.test'),
      (v_operator, 'operator@zzinv-' || v_tag || '.test'),
      (v_support, 'support@zzinv-'  || v_tag || '.test'),
      (v_owner_sub, 'owner@zzinv-'    || v_tag || '.test'),
      (v_trusted, 'trusted@zzinv-'  || v_tag || '.test'),
      (v_admin, 'admin@zzinv-'    || v_tag || '.test'),
      (v_member, 'member@zzinv-'   || v_tag || '.test');
    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role) values
      ('operator@zzinv-' || v_tag || '.test', v_operator, 'Invitation Suite Operator', 'operator'),
      ('support@zzinv-'  || v_tag || '.test', v_support, 'Invitation Suite Support',  'support'),
      ('owner@zzinv-'    || v_tag || '.test', v_owner_sub, 'Invitation Suite Owner',    'owner');

    -- Closed. A person with no organisation.
    c_p_onboard    := erp_test.invitation_only_call(v_person, 'erp_onboard_tenant', 'zzinv-p-' || v_tag);
    select count(*) into v_p_made from erp.app_user u where u.auth_user_id = v_person;
    c_p_demo       := erp_test.invitation_only_call(v_person, 'erp_seed_demo');
    c_p_history    := erp_test.invitation_only_call(v_person, 'erp_seed_demo_history', null, null, current_date + 1);
    c_p_operations := erp_test.invitation_only_call(v_person, 'erp_seed_demo_operations');
    c_p_asks       := erp_test.invitation_only_call(v_person, 'erp_self_service_organisations_open');

    -- Support staff, then an operator.
    c_s_onboard := erp_test.invitation_only_call(v_support, 'erp_onboard_tenant', 'zzinv-s-' || v_tag);
    c_s_demo    := erp_test.invitation_only_call(v_support, 'erp_seed_demo');
    c_o_onboard := erp_test.invitation_only_call(v_operator, 'erp_onboard_tenant', 'zzinv-o-' || v_tag);
    c_o_demo    := erp_test.invitation_only_call(v_operator, 'erp_seed_demo');
    -- In the demo organisation it just made, which is active for it now. An
    -- empty range: past the gate, the permission and the live check, and
    -- nothing to build.
    c_o_history := erp_test.invitation_only_call(v_operator, 'erp_seed_demo_history', null, null, current_date + 1);

    -- Trusted sessions: provisioning, and the door for a signed-in subject.
    perform set_config('request.jwt.claims', '', true);
    select * into rx from erp.provision_tenant('zzinv-x-' || v_tag, 'Invitation Suite X',
                                               'admin@zzinv-' || v_tag || '.test', 'Invitation Suite Admin');
    v_provisioned := rx.tenant_id;
    -- erp.provision_tenant() leaves its organisation declared for the rest of
    -- the transaction. Nothing below is a job for that organisation.
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('request.jwt.claims', json_build_object('sub', v_trusted)::text, true);
    begin
      v_t_onboard := public.erp_onboard_tenant('Invitation Suite Trusted', 'zzinv-t-' || v_tag);
    exception when others then
      v_t_msg := left(sqlerrm, 200);
    end;

    -- The administrator of the provisioned organisation, and a member who holds
    -- nothing, for the setup doors.
    perform set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
    perform erp.claim_invitation(rx.admin_token);
    select i.token into v_member_token
      from erp.invite_principal('member@zzinv-' || v_tag || '.test', 'Invitation Suite Member') i;
    perform set_config('request.jwt.claims', json_build_object('sub', v_member)::text, true);
    perform erp.claim_invitation(v_member_token);
    perform set_config('request.jwt.claims', '', true);

    select sc.screen_path into v_screen from erp_ref.setup_screen sc order by sc.seq limit 1;
    c_a_progress := erp_test.invitation_only_call(v_admin, 'erp_setup_progress');
    c_a_walk     := erp_test.invitation_only_call(v_admin, 'erp_setup_walkthrough', v_screen);
    c_m_progress := erp_test.invitation_only_call(v_member, 'erp_setup_progress');
    c_m_walk     := erp_test.invitation_only_call(v_member, 'erp_setup_walkthrough', v_screen);

    -- Who may change the switch.
    c_o_switch := erp_test.invitation_only_call(v_operator, 'erp_platform_set_self_service_organisations', 'Invitation suite: an operator tries', true);
    v_after_operator := erp.self_service_organisations_open();
    c_w_blank := erp_test.invitation_only_call(v_owner_sub, 'erp_platform_set_self_service_organisations', '   ', true);
    c_w_null  := erp_test.invitation_only_call(v_owner_sub, 'erp_platform_set_self_service_organisations', null, true);
    v_after_blank := erp.self_service_organisations_open();

    -- Opened.
    c_w_open := erp_test.invitation_only_call(v_owner_sub, 'erp_platform_set_self_service_organisations', 'Invitation suite: opened for the case', true);
    v_after_open := erp.self_service_organisations_open();
    c_p_asks_open    := erp_test.invitation_only_call(v_person, 'erp_self_service_organisations_open');
    c_p_onboard_open := erp_test.invitation_only_call(v_person, 'erp_onboard_tenant', 'zzinv-p-' || v_tag);
    c_p_demo_open    := erp_test.invitation_only_call(v_person, 'erp_seed_demo');
    c_p_again        := erp_test.invitation_only_call(v_person, 'erp_onboard_tenant', 'zzinv-pp-' || v_tag);

    -- Closed again.
    c_w_close := erp_test.invitation_only_call(v_owner_sub, 'erp_platform_set_self_service_organisations', 'Invitation suite: closed again', false);
    v_after_close := erp.self_service_organisations_open();
    c_p2_onboard       := erp_test.invitation_only_call(v_later, 'erp_onboard_tenant', 'zzinv-q-' || v_tag);
    c_p_history_closed := erp_test.invitation_only_call(v_person, 'erp_seed_demo_history', null, null, current_date + 1);

    perform set_config('request.jwt.claims', '', true);
    select coalesce(jsonb_agg(jsonb_build_object('action', pa.action, 'role', pa.actor_role,
                                                 'reason', pa.reason, 'open', pa.detail -> 'open')
                              order by pa.id), '[]'::jsonb)
      into v_audit
      from erp_meta.platform_audit pa
     where pa.action in ('platform.self_service_organisations_opened', 'platform.self_service_organisations_closed')
       and pa.actor_email = 'owner@zzinv-' || v_tag || '.test';
    select count(*) - v_audit_before into v_audit_new
      from erp_meta.platform_audit pa
     where pa.action in ('platform.self_service_organisations_opened', 'platform.self_service_organisations_closed');

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_state := left(sqlerrm, 300); end if;
  end;

  -- 1
  case_name := 'with no setting on file self-service sign-up reads as closed, and so does a row saying false';
  passed := v_state is null and v_absent_closed and v_row_closed;
  detail := coalesce(v_state, format('absent closed %s, false closed %s', v_absent_closed, v_row_closed));
  return next;

  -- 2
  case_name := 'while closed, a person with no organisation is refused onboarding by name, and nothing is made';
  passed := v_state is null and c_p_onboard ->> 'state' = '42501'
        and c_p_onboard ->> 'message' like 'CLOVEERP_ORGANISATION_BY_INVITATION_ONLY%' and v_p_made = 0;
  detail := coalesce(v_state, format('%s %s; %s principal(s)', c_p_onboard ->> 'state', c_p_onboard ->> 'message', v_p_made));
  return next;

  -- 3
  case_name := 'and is refused a demo organisation by name';
  passed := v_state is null and c_p_demo ->> 'state' = '42501'
        and c_p_demo ->> 'message' like 'CLOVEERP_DEMO_FOR_PLATFORM_STAFF_ONLY%';
  detail := coalesce(v_state, format('%s %s', c_p_demo ->> 'state', coalesce(c_p_demo ->> 'message', c_p_demo ->> 'outcome')));
  return next;

  -- 4
  case_name := 'and is refused demonstration history and demonstration operations by name';
  passed := v_state is null
        and c_p_history ->> 'state' = '42501' and c_p_history ->> 'message' like 'CLOVEERP_DEMO_FOR_PLATFORM_STAFF_ONLY%'
        and c_p_operations ->> 'state' = '42501' and c_p_operations ->> 'message' like 'CLOVEERP_DEMO_FOR_PLATFORM_STAFF_ONLY%';
  detail := coalesce(v_state, format('history: %s %s; operations: %s %s',
                                     c_p_history ->> 'state', c_p_history ->> 'message',
                                     c_p_operations ->> 'state', c_p_operations ->> 'message'));
  return next;

  -- 5
  case_name := 'and may ask whether sign-up is open, and is told it is closed';
  passed := v_state is null and c_p_asks ->> 'state' is null and c_p_asks -> 'outcome' = 'false'::jsonb;
  detail := coalesce(v_state, format('answer %s, %s', c_p_asks -> 'outcome', coalesce(c_p_asks ->> 'message', 'no refusal')));
  return next;

  -- 6
  case_name := 'platform support staff are refused onboarding and a demo organisation by name';
  passed := v_state is null
        and c_s_onboard ->> 'state' = '42501' and c_s_onboard ->> 'message' like 'CLOVEERP_ORGANISATION_BY_INVITATION_ONLY%'
        and c_s_demo ->> 'state' = '42501' and c_s_demo ->> 'message' like 'CLOVEERP_DEMO_FOR_PLATFORM_STAFF_ONLY%';
  detail := coalesce(v_state, format('onboarding: %s; demo: %s', c_s_onboard ->> 'message', c_s_demo ->> 'message'));
  return next;

  -- 7
  case_name := 'a platform operator onboards an organisation while sign-up is closed';
  passed := v_state is null and c_o_onboard ->> 'state' is null
        and (c_o_onboard -> 'outcome' ->> 'tenant_id') is not null;
  detail := coalesce(v_state, c_o_onboard ->> 'message', 'organisation ' || (c_o_onboard -> 'outcome' ->> 'tenant_id'));
  return next;

  -- 8
  case_name := 'and seeds a demo organisation, configured';
  passed := v_state is null and c_o_demo ->> 'state' is null
        and (c_o_demo -> 'outcome' ->> 'tenant_id') is not null
        and (c_o_demo -> 'outcome' ->> 'already_existed') = 'false'
        and (c_o_demo -> 'outcome') ? 'configured';
  detail := coalesce(v_state, c_o_demo ->> 'message', 'demo organisation ' || (c_o_demo -> 'outcome' ->> 'tenant_id'));
  return next;

  -- 9
  case_name := 'and builds demonstration history in it';
  passed := v_state is null and c_o_history ->> 'state' is null
        and (c_o_history -> 'outcome' ->> 'done') = 'true'
        and (c_o_history -> 'outcome' ->> 'built') = '0';
  detail := coalesce(v_state, c_o_history ->> 'message', 'answered ' || (c_o_history ->> 'outcome'));
  return next;

  -- 10
  case_name := 'a trusted session still provisions an organisation while sign-up is closed';
  passed := v_state is null and v_provisioned is not null;
  detail := coalesce(v_state, 'organisation ' || v_provisioned::text);
  return next;

  -- 11
  case_name := 'and onboards through the door for a signed-in subject, as the build''s fixtures do';
  passed := v_state is null and v_t_msg is null and (v_t_onboard ->> 'tenant_id') is not null;
  detail := coalesce(v_state, v_t_msg, 'organisation ' || (v_t_onboard ->> 'tenant_id'));
  return next;

  -- 12
  case_name := 'a platform operator cannot change the switch, refused by name, and it stays closed';
  passed := v_state is null and c_o_switch ->> 'state' = '42501'
        and c_o_switch ->> 'message' like 'CLOVEERP_PLATFORM_ROLE_TOO_LOW%' and not v_after_operator;
  detail := coalesce(v_state, format('%s %s; open afterwards %s', c_o_switch ->> 'state', c_o_switch ->> 'message', v_after_operator));
  return next;

  -- 13
  case_name := 'a platform owner cannot change it without a reason, blank or missing, refused by name';
  passed := v_state is null
        and c_w_blank ->> 'message' like 'CLOVEERP_SELF_SERVICE_SWITCH_NEEDS_REASON%'
        and c_w_null ->> 'message' like 'CLOVEERP_SELF_SERVICE_SWITCH_NEEDS_REASON%'
        and not v_after_blank;
  detail := coalesce(v_state, format('blank: %s; missing: %s; open afterwards %s',
                                     c_w_blank ->> 'message', c_w_null ->> 'message', v_after_blank));
  return next;

  -- 14
  case_name := 'the owner opens it with a reason, and the door answers open, the reason and when';
  passed := v_state is null and c_w_open ->> 'state' is null and v_after_open
        and (c_w_open -> 'outcome' ->> 'open') = 'true'
        and (c_w_open -> 'outcome' ->> 'reason') = 'Invitation suite: opened for the case'
        and (c_w_open -> 'outcome' ->> 'updated_at') is not null;
  detail := coalesce(v_state, c_w_open ->> 'message', 'answered ' || (c_w_open ->> 'outcome'));
  return next;

  -- 15
  case_name := 'while open, the same person is told so and onboards';
  passed := v_state is null and c_p_asks_open -> 'outcome' = 'true'::jsonb
        and c_p_onboard_open ->> 'state' is null
        and (c_p_onboard_open -> 'outcome' ->> 'tenant_id') is not null;
  detail := coalesce(v_state, c_p_onboard_open ->> 'message',
                     format('told %s; organisation %s', c_p_asks_open -> 'outcome', c_p_onboard_open -> 'outcome' ->> 'tenant_id'));
  return next;

  -- 16
  case_name := 'and seeds a demo organisation, configured';
  passed := v_state is null and c_p_demo_open ->> 'state' is null
        and (c_p_demo_open -> 'outcome' ->> 'tenant_id') is not null
        and (c_p_demo_open -> 'outcome') ? 'configured';
  detail := coalesce(v_state, c_p_demo_open ->> 'message', 'demo organisation ' || (c_p_demo_open -> 'outcome' ->> 'tenant_id'));
  return next;

  -- 17
  case_name := 'while open, the per-sign-in onboarding limit still refuses a second organisation';
  passed := v_state is null and c_p_again ->> 'message' like 'CLOVEERP_ONBOARDING_LIMIT%';
  detail := coalesce(v_state, format('%s %s', c_p_again ->> 'state', coalesce(c_p_again ->> 'message', c_p_again ->> 'outcome')));
  return next;

  -- 18
  case_name := 'the owner closes it again, and the next person with no organisation is refused onboarding by name';
  passed := v_state is null and c_w_close ->> 'state' is null and not v_after_close
        and (c_w_close -> 'outcome' ->> 'open') = 'false'
        and c_p2_onboard ->> 'state' = '42501'
        and c_p2_onboard ->> 'message' like 'CLOVEERP_ORGANISATION_BY_INVITATION_ONLY%';
  detail := coalesce(v_state, c_w_close ->> 'message', format('closed %s; next person: %s', not v_after_close, c_p2_onboard ->> 'message'));
  return next;

  -- 19
  case_name := 'and the person let in while it was open is refused demonstration history by name';
  passed := v_state is null and c_p_history_closed ->> 'state' = '42501'
        and c_p_history_closed ->> 'message' like 'CLOVEERP_DEMO_FOR_PLATFORM_STAFF_ONLY%';
  detail := coalesce(v_state, format('%s %s', c_p_history_closed ->> 'state', coalesce(c_p_history_closed ->> 'message', c_p_history_closed ->> 'outcome')));
  return next;

  -- 20
  case_name := 'every change is in the platform log once, by the owner, with its reason, and no refused change is';
  passed := v_state is null and v_audit_new = 2
        and v_audit = jsonb_build_array(
              jsonb_build_object('action', 'platform.self_service_organisations_opened', 'role', 'owner',
                                 'reason', 'Invitation suite: opened for the case', 'open', true),
              jsonb_build_object('action', 'platform.self_service_organisations_closed', 'role', 'owner',
                                 'reason', 'Invitation suite: closed again', 'open', false));
  detail := coalesce(v_state, format('%s new row(s): %s', v_audit_new, v_audit));
  return next;

  -- 21
  case_name := 'a person holding administration.configure reads setup progress and the walkthrough';
  passed := v_state is null and c_a_progress ->> 'state' is null and c_a_walk ->> 'state' is null
        and jsonb_typeof(c_a_progress -> 'outcome') = 'array'
        and jsonb_array_length(c_a_progress -> 'outcome') > 0
        and (c_a_walk -> 'outcome' -> 'screen' ->> 'screen_path') = v_screen;
  detail := coalesce(v_state, c_a_progress ->> 'message', c_a_walk ->> 'message',
                     format('%s screen(s) in the order; walkthrough for %s', jsonb_array_length(c_a_progress -> 'outcome'), v_screen));
  return next;

  -- 22
  case_name := 'a person without it is refused both, 42501';
  passed := v_state is null
        and c_m_progress ->> 'state' = '42501' and c_m_progress ->> 'message' like 'CLOVEERP_PERMISSION_DENIED%'
        and c_m_walk ->> 'state' = '42501' and c_m_walk ->> 'message' like 'CLOVEERP_PERMISSION_DENIED%';
  detail := coalesce(v_state, format('progress: %s %s; walkthrough: %s %s',
                                     c_m_progress ->> 'state', c_m_progress ->> 'message',
                                     c_m_walk ->> 'state', c_m_walk ->> 'message'));
  return next;

  -- 23. Read from the catalogue, so a door added later without the question
  --     is named by the next one that copies this list.
  select bool_and(not p.prosecdef
                  and substr(x.code, 1, greatest(strpos(x.code, 'perform ' || x.gate || '()') - 1, 0)) ~ '^\s*(declare\s[^$]*)?\s*begin\s*$'
                  and strpos(x.code, 'perform ' || x.gate || '()') > 0
                  and strpos(x.code, 'perform ' || x.gate || '()') < strpos(x.code, x.delegate || '(')),
         string_agg(format('%s: %s, asks %s', f.door,
                           case when p.prosecdef then 'definer' else 'invoker' end,
                           strpos(x.code, 'perform ' || x.gate || '()') > 0), '; ' order by f.door)
    into v_first, v_first_text
    from (values ('erp_onboard_tenant',       'erp.require_organisation_by_invitation', 'erp.onboard_tenant'),
                 ('erp_seed_demo',            'erp.require_demo_for_platform_staff',    'erp.seed_demo'),
                 ('erp_seed_demo_history',    'erp.require_demo_for_platform_staff',    'erp.seed_demo_history'),
                 ('erp_seed_demo_operations', 'erp.require_demo_for_platform_staff',    'erp.seed_demo_operations'))
         as f(door, gate, delegate)
    join pg_catalog.pg_proc p on p.pronamespace = 'public'::regnamespace and p.proname = f.door
    cross join lateral (select erp.prosrc_code(p.prosrc) as code, f.gate, f.delegate) x;
  case_name := 'every door that makes an organisation or demonstration data runs as the caller and asks before anything else';
  passed := coalesce(v_first, false) and (select count(*) from pg_catalog.pg_proc p
                                           where p.pronamespace = 'public'::regnamespace
                                             and p.proname in ('erp_onboard_tenant', 'erp_seed_demo',
                                                               'erp_seed_demo_history', 'erp_seed_demo_operations')) = 4;
  detail := coalesce(v_first_text, 'no such doors');
  return next;

  -- 24
  case_name := 'the fixtures were undone';
  passed := erp.self_service_organisations_open() is not distinct from v_open_before
        and (select count(*) from erp_meta.platform_audit pa
              where pa.action in ('platform.self_service_organisations_opened',
                                  'platform.self_service_organisations_closed')) = v_audit_before
        and not exists (select 1 from erp_meta.platform_staff ps where ps.email like '%@zzinv-' || v_tag || '.test')
        and not exists (select 1 from erp.app_user u where u.auth_user_id in (v_person, v_later, v_operator, v_support, v_owner_sub, v_trusted, v_admin, v_member))
        and not exists (select 1 from erp.tenant tt where tt.code like 'zzinv-%' || v_tag);
  detail := 'the setting, the log, the staff, the people and their organisations rolled back';
  return next;
end;
$$;
revoke all on function erp_test.invitation_only_suite() from public, anon, authenticated;

create or replace function erp_test.assert_invitation_only_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 24;
  v_total  integer;
  v_failed integer;
  v_detail text;
begin
  select count(*), count(*) filter (where not coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n') filter (where not coalesce(s.passed, false))
    into v_total, v_failed, v_detail
    from erp_test.invitation_only_suite() s;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_INVITATION_ONLY_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.',
            hint = 'Change c_expected in the same migration that adds or removes the case.';
  end if;
  if v_failed > 0 then
    raise exception E'CLOVEERP_INVITATION_ONLY_SUITE_FAILED: %/% case(s) failed\n%', v_failed, v_total, v_detail
      using hint = 'Each failed case names what it saw; the first failure usually explains the rest.';
  end if;
  return format('organisations by invitation: %s/%s cases passed', v_total - v_failed, v_total);
end;
$$;
revoke all on function erp_test.assert_invitation_only_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 9. Generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_authorise_codes_exist();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_no_caller_reachable_internals();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_isolation();
select erp.assert_setup_walkthrough_actionable();
select erp.assert_refusals_name_next_action();
select erp.assert_session_context_hygiene();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();

select erp_test.assert_invitation_only_suite();
select erp_test.assert_write_gate_suite();
select erp_test.assert_grant_suite();
