-- =============================================================================
-- The person's own profile: names and preferences.
--
-- A principal had one name, display_name, set by whoever invited them, and
-- three locale columns and a time zone that nothing could set from the
-- product. This gives the person their own given and family names, derives the
-- display name from them unless they choose one, and opens the preferences a
-- screen follows — time zone, and the languages of screens, documents and
-- reports — to the one person entitled to change them without asking: the
-- subject.
--
-- The rule is identity, not permission. erp.update_profile() lets a person
-- change their own row with no grant at all, and lets an administrator holding
-- administration.users correct somebody else's; nothing in between. The names
-- are personal data, so they join the erasure register beside the display
-- name they derive, and an executed erasure clears them.
-- =============================================================================

alter table erp.app_user
  add column if not exists given_name  text,
  add column if not exists family_name text;

comment on column erp.app_user.given_name is
  'The person''s given (first) name, set by them. Personal data: erased with the principal.';
comment on column erp.app_user.family_name is
  'The person''s family (last) name, set by them. Personal data: erased with the principal.';

-- ── The register knows the new columns ───────────────────────────────────────

insert into erp_ref.personal_data_field
  (schema_name, table_name, column_name, subject_kind, subject_column, erasure, placeholder, note)
values
  ('erp', 'app_user', 'given_name', 'principal', 'id', 'null', null,
   'Set by the person themselves. Cleared on erasure; the display name carries the placeholder.'),
  ('erp', 'app_user', 'family_name', 'principal', 'id', 'null', null,
   'Set by the person themselves. Cleared on erasure; the display name carries the placeholder.')
on conflict (schema_name, table_name, column_name) do update set
  subject_kind = excluded.subject_kind, subject_column = excluded.subject_column,
  erasure = excluded.erasure, placeholder = excluded.placeholder, note = excluded.note;

-- ── The writer ───────────────────────────────────────────────────────────────

create or replace function erp.update_profile(
  p_app_user_id uuid,
  p_given_name text default null,
  p_family_name text default null,
  p_display_name text default null,
  p_timezone text default null,
  p_user_locale text default null,
  p_document_locale text default null,
  p_reporting_locale text default null)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_me      uuid := erp.current_principal_id();
  u         erp.app_user%rowtype;
  v_given   text := nullif(btrim(coalesce(p_given_name, '')), '');
  v_family  text := nullif(btrim(coalesce(p_family_name, '')), '');
  v_display text := nullif(btrim(coalesce(p_display_name, '')), '');
  v_derived text;
  v_locale  text;
begin
  select * into u from erp.app_user a where a.tenant_id = v_tenant and a.id = p_app_user_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_PRINCIPAL: %', p_app_user_id using errcode = '23503';
  end if;

  -- Identity is the gate for one's own row. Anybody else's needs the
  -- permission that manages people, and the check is recorded like any other.
  if u.id is distinct from v_me then
    perform erp.authorise('administration.users', null, null, null, 'app_user', p_app_user_id);
  end if;

  if u.kind <> 'person' then
    raise exception 'ERPWARE_NOT_A_PERSON: % is a % principal and has no profile', u.display_name, u.kind
      using errcode = '22023';
  end if;

  if p_timezone is not null and nullif(btrim(p_timezone), '') is not null
     and not exists (select 1 from pg_catalog.pg_timezone_names z where z.name = p_timezone) then
    raise exception 'ERPWARE_UNKNOWN_TIMEZONE: % is not a time zone the database knows', p_timezone
      using errcode = '22023',
            hint = 'Use an IANA name such as Europe/London; erp_timezones() lists them.';
  end if;

  foreach v_locale in array array[p_user_locale, p_document_locale, p_reporting_locale] loop
    if v_locale is not null and nullif(btrim(v_locale), '') is not null
       and not exists (select 1 from erp_ref.locale l where l.code = v_locale and l.is_active) then
      raise exception 'ERPWARE_UNKNOWN_LOCALE: % is not a locale the product carries', v_locale
        using errcode = '22023', hint = 'erp_locales() lists the ones it does.';
    end if;
  end loop;

  -- The display name follows the names unless the person set one. A blank
  -- everything would leave a principal with no name at all, which every
  -- screen and every audit label assumes cannot happen.
  v_derived := nullif(btrim(concat_ws(' ', v_given, v_family)), '');
  v_display := coalesce(v_display, v_derived, u.display_name);
  if v_display is null then
    raise exception 'ERPWARE_PROFILE_NEEDS_A_NAME: a principal must have a name to be shown by'
      using errcode = '22023';
  end if;

  update erp.app_user a
     set given_name       = v_given,
         family_name      = v_family,
         display_name     = v_display,
         timezone         = nullif(btrim(coalesce(p_timezone, '')), ''),
         user_locale      = nullif(btrim(coalesce(p_user_locale, '')), ''),
         document_locale  = nullif(btrim(coalesce(p_document_locale, '')), ''),
         reporting_locale = nullif(btrim(coalesce(p_reporting_locale, '')), ''),
         updated_at       = now(),
         updated_by       = v_me
   where a.tenant_id = v_tenant and a.id = p_app_user_id;

  return jsonb_build_object(
    'app_user_id', p_app_user_id, 'given_name', v_given, 'family_name', v_family,
    'display_name', v_display, 'display_name_derived', v_display = v_derived);
end;
$$;

comment on function erp.update_profile is
  'A person''s own names and preferences. Gated by identity for one''s own row '
  '(the caller is the subject), by administration.users for anybody else''s. '
  'Validates the time zone against the database and the locales against '
  'erp_ref.locale; derives the display name from the names unless one is set.';

-- ── The doors ────────────────────────────────────────────────────────────────

create or replace function public.erp_update_my_profile(
  p_given_name text default null,
  p_family_name text default null,
  p_display_name text default null,
  p_timezone text default null,
  p_user_locale text default null,
  p_document_locale text default null,
  p_reporting_locale text default null)
returns jsonb
language sql
set search_path = ''
as $$
  select erp.update_profile(erp.current_principal_id(), p_given_name, p_family_name,
                            p_display_name, p_timezone, p_user_locale,
                            p_document_locale, p_reporting_locale)
$$;

create or replace function public.erp_locales()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('code', l.code, 'name', l.name,
                                                'text_direction', l.text_direction)
                            order by l.code)
                  filter (where erp.current_tenant_id() is not null),
                  '[]'::jsonb)
    from erp_ref.locale l where l.is_active
$$;

create or replace function public.erp_timezones()
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- The database's own list, filtered to the region/city names people
  -- recognise; POSIX aliases and the legacy zones only confuse a picker.
  select coalesce(jsonb_agg(z.name order by z.name)
                  filter (where erp.current_tenant_id() is not null), '[]'::jsonb)
    from pg_catalog.pg_timezone_names z
   where z.name like '%/%' and z.name not like 'posix/%' and z.name not like 'right/%'
     and z.name not like 'Etc/%' and z.name not like 'SystemV/%' and z.name not like 'US/%'
$$;

-- The session carries the whole profile, so the shell greets by given name and
-- the profile screen starts from what is stored.
create or replace function public.erp_session()
returns jsonb
language sql
stable
set search_path = ''
as $function$
  select jsonb_strip_nulls(jsonb_build_object(
    'principal_id', erp.current_principal_id(),
    'tenant_id',    erp.current_tenant_id(),
    'principal', (
      select jsonb_build_object(
               'display_name', u.display_name,
               'given_name', u.given_name,
               'family_name', u.family_name,
               'email', u.email,
               'kind', u.kind,
               'user_locale', u.user_locale,
               'document_locale', u.document_locale,
               'reporting_locale', u.reporting_locale,
               'timezone', u.timezone)
        from erp.app_user u where u.id = erp.current_principal_id()),
    'tenant', (
      select jsonb_build_object('code', t.code, 'name', t.name, 'status', t.status)
        from erp.tenant t where t.id = erp.current_tenant_id()),
    'entities', coalesce((
      select jsonb_agg(jsonb_build_object('id', e.id, 'code', e.code, 'name', e.name)
                       order by e.code)
        from erp.entity e where e.tenant_id = erp.current_tenant_id()), '[]'::jsonb),
    'sites', coalesce((
      select jsonb_agg(jsonb_build_object('id', s.id, 'code', s.code, 'name', s.name,
                                          'entity_id', s.entity_id) order by s.code)
        from erp.site s where s.tenant_id = erp.current_tenant_id()), '[]'::jsonb),
    -- What the navigation may offer. Deriving it here rather than in the client
    -- means a screen cannot appear for someone who could not use it.
    'permissions', coalesce((
      select jsonb_agg(distinct ep.permission_code)
        from erp.effective_permission ep
       where ep.app_user_id = erp.current_principal_id()
         and ep.valid_from <= current_date
         and (ep.valid_to is null or ep.valid_to >= current_date)), '[]'::jsonb)
  ))
$function$;

revoke all on function
  public.erp_update_my_profile(text, text, text, text, text, text, text),
  public.erp_locales(),
  public.erp_timezones()
  from public, anon;

grant execute on function
  public.erp_update_my_profile(text, text, text, text, text, text, text),
  public.erp_locales(),
  public.erp_timezones()
  to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_update_my_profile', 'erp.update_profile',
   'A person''s own names and preferences. Gated by identity: the door passes the caller''s own principal id, and erp.update_profile refuses anybody else''s row without administration.users.')
on conflict (function_name) do update
  set gate = excluded.gate, rationale = excluded.rationale;

-- ── Wording and guidance ─────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description) values
('nav.profile', 'en', 'My profile',
 'The account menu entry and page title for a person''s own names and preferences.')
on conflict (key, locale) do update set
  value = excluded.value, description = excluded.description;

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(t.text), 'en', t.text,
       'Screen wording, keyed by its own source text so a tenant can rename it.'
  from (values
    ('My profile'),
    ('Your names, the name the product shows for you, and the time zone and languages your screens and documents follow. Only you can change these; an administrator manages what you may do, not who you are.'),
    ('Who you are'),
    ('The greeting uses your given name. The display name is what colleagues see beside what you did; it follows your names unless you set it yourself.'),
    ('Given name'),
    ('Family name'),
    ('Display name'),
    ('Follows your given and family names.'),
    ('Set by you; clear it to follow your names again.'),
    ('Email'),
    ('Where and in what language'),
    ('Times are shown in your time zone. Each language falls back to the organisation''s default when you leave it unset.'),
    ('Time zone'),
    ('The organisation''s default'),
    ('Screen language'),
    ('The wording of every screen, including terms your organisation renamed.'),
    ('Document language'),
    ('Documents you raise: orders, invoices, delivery notes.'),
    ('Reporting language'),
    ('Reports and exports you run.'),
    ('Saving…'),
    ('Save my profile'),
    ('Saved. Your screens follow the new settings from the next load.')
  ) t(text)
on conflict (key, locale) do update set
  value = excluded.value, description = excluded.description;

insert into erp_ref.help_topic (screen_path, nav_key, module_code, summary, steps, next_action, actions) values
  ('/profile', 'nav.profile', 'administration',
   'Your own names and preferences. The display name follows your given and family names unless you set one; the time zone and languages shape what you see and what you raise.',
   '["Enter your given and family names; the display name follows them.","Set a display name only if you want colleagues to see something else.","Choose your time zone, and the languages for screens, documents and reports, or leave each on the organisation''s default."]',
   'Save; the next screen you open follows the new settings.',
   '{erp_update_my_profile}')
on conflict (screen_path) do update set
  nav_key = excluded.nav_key, module_code = excluded.module_code, summary = excluded.summary,
  steps = excluded.steps, next_action = excluded.next_action, actions = excluded.actions;

-- ── The suite ─────────────────────────────────────────────────────────────────

create or replace function erp_test.profile_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  r record;
  a1 uuid := gen_random_uuid();
  a2 uuid := gen_random_uuid();
  v_second uuid; v_admin uuid; v_tok text; res jsonb;
  v_ok boolean; v_msg text;
begin
  select * into r from erp.provision_tenant(
    'zzprof', 'Profiles', 'admin@zzprof.test', 'Profile Admin');
  insert into auth.users (id, email) values (a1, 'admin@zzprof.test'), (a2, 'viewer@zzprof.test');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);
  v_admin := erp.current_principal_id();

  -- A second person with no permissions at all: the profile needs none.
  res := public.erp_invite_principal('viewer@zzprof.test', 'Only Viewer');
  v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';

  -- ── One's own row ─────────────────────────────────────────────────────────

  res := public.erp_update_my_profile('Priya', 'Natarajan');
  return query select 'a person sets their own names and the display name follows',
    res ->> 'display_name' = 'Priya Natarajan' and (res ->> 'display_name_derived')::boolean
    and (select u.given_name from erp.app_user u where u.id = v_admin) = 'Priya',
    res ->> 'display_name';

  res := public.erp_update_my_profile('Priya', 'Natarajan', 'Pri');
  return query select 'a display name set by the person wins over the derived one',
    res ->> 'display_name' = 'Pri' and not (res ->> 'display_name_derived')::boolean,
    res ->> 'display_name';

  res := public.erp_update_my_profile(null, null, null);
  return query select 'clearing everything keeps the last display name rather than leaving no name',
    res ->> 'display_name' = 'Pri'
    and (select u.given_name from erp.app_user u where u.id = v_admin) is null,
    res ->> 'display_name';

  res := public.erp_update_my_profile('Priya', 'Natarajan', null, 'Europe/London', 'en-GB', 'fr', 'en-GB');
  return query select 'time zone and the three languages are kept, and the session carries them',
    (public.erp_session() -> 'principal' ->> 'timezone') = 'Europe/London'
    and (public.erp_session() -> 'principal' ->> 'user_locale') = 'en-GB'
    and (public.erp_session() -> 'principal' ->> 'document_locale') = 'fr'
    and (public.erp_session() -> 'principal' ->> 'given_name') = 'Priya',
    'Europe/London, en-GB, fr, en-GB';

  begin
    perform public.erp_update_my_profile('Priya', 'Natarajan', null, 'Mars/Olympus');
    v_ok := false; v_msg := 'an unknown time zone was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_UNKNOWN_TIMEZONE%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a time zone the database does not know is refused', v_ok, v_msg;

  begin
    perform public.erp_update_my_profile('Priya', 'Natarajan', null, null, 'xx-YY');
    v_ok := false; v_msg := 'an unknown locale was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_UNKNOWN_LOCALE%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a locale the product does not carry is refused', v_ok, v_msg;

  return query select 'the lists a picker reads are the database''s own',
    jsonb_array_length(public.erp_locales()) = (select count(*) from erp_ref.locale where is_active)
    and public.erp_timezones() @> '["Europe/London"]'::jsonb
    and not public.erp_timezones() @> '["posix/Europe/London"]'::jsonb,
    format('%s locales; time zones by region/city', jsonb_array_length(public.erp_locales()));

  -- ── Somebody else's row ───────────────────────────────────────────────────

  res := to_jsonb(erp.update_profile(v_second, 'Only', 'Viewer'));
  return query select 'an administrator may correct a colleague''s names',
    (select u.display_name from erp.app_user u where u.id = v_second) = 'Only Viewer'
    and (select u.given_name from erp.app_user u where u.id = v_second) = 'Only',
    'administration.users held';

  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(v_tok);
  res := public.erp_update_my_profile('Ola', 'Viewer', null, 'Africa/Lagos');
  return query select 'a person with no permissions at all still sets their own',
    res ->> 'display_name' = 'Ola Viewer'
    and (select u.timezone from erp.app_user u where u.id = v_second) = 'Africa/Lagos',
    res ->> 'display_name';

  begin
    perform erp.update_profile(v_admin, 'Not', 'Yours');
    v_ok := false; v_msg := 'a viewer renamed the administrator';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_PERMISSION_DENIED%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'but not anybody else''s', v_ok
    and (select u.display_name from erp.app_user u where u.id = v_admin) = 'Priya Natarajan',
    v_msg;

  -- ── The register ──────────────────────────────────────────────────────────

  return query select 'the names are personal data the erasure register knows',
    (select count(*) from erp_ref.personal_data_field f
      where f.table_name = 'app_user' and f.column_name in ('given_name', 'family_name')
        and f.erasure = 'null') = 2,
    'given_name and family_name cleared on erasure';

  -- ── Clean up ──────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(r.tenant_id);
  delete from erp.tenant where id = r.tenant_id;
  perform erp.end_tenant_purge();
  delete from auth.users where id in (a1, a2);
  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.id = r.tenant_id),
    'organisation gone';
end;
$$;

create or replace function erp_test.assert_profile_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _profile_result on commit drop as
    select * from erp_test.profile_suite();

  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_total, v_passed, v_detail
    from _profile_result;

  if v_passed < v_total then
    raise exception E'ERPWARE_PROFILE_SUITE_FAILED: %/%\n%', v_passed, v_total, v_detail
      using errcode = 'P0001';
  end if;
  return format('profile: %s/%s', v_passed, v_total);
end;
$$;

-- ── The generators, then the assertions ──────────────────────────────────────

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_no_dead_configuration();
select erp.assert_personal_data_register_sound();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
select erp.assert_guidance_sound();
select erp_test.assert_profile_suite();
