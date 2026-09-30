-- ═════════════════════════════════════════════════════════════════════════════
-- An organisation has an address
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Every organisation is found at cloveerp.com/<its code>. erp.tenant.code has
-- been unique and address-shaped since 0001, but nobody could use it: codes
-- were typed once at onboarding as a "short code" and never seen again.
--
-- The address is a way in, never an authority. current_tenant_id() still
-- derives the organisation from the account that signs in, and nothing here
-- reads a code to decide what a session may see. What an address does:
--
--   1. Signed out, it names the organisation on the sign-in form. That needs
--      a door a signed-out visitor can call: erp_tenant_by_address, which
--      answers a code with the organisation's current code and name and
--      nothing else. It does say whether a code is held — an address that
--      names its organisation cannot avoid that — and it says no more.
--   2. An administrator can change it (erp_set_tenant_address, authorising
--      administration.configure). The old code is kept against the
--      organisation, keeps opening the new one, and no other organisation
--      may take it, so a link already sent neither breaks nor opens somebody
--      else's sign-in form.
--   3. Codes that are pages of the application, or words that would read as
--      the product's own (www, api, support), are reserved. The top-level
--      route names are reserved here, and supabase/ci/app_addresses.sh fails
--      the build when a route is added that is not.
--
-- The code stays at most 63 characters on the way in — one DNS label — so the
-- same code can become acme.cloveerp.com later without a rename. Existing
-- codes are not touched: the rule applies when a code is set.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. What may not be an address
-- ─────────────────────────────────────────────────────────────────────────────

create table erp_meta.reserved_tenant_code (
  code   text primary key,
  reason text not null
);

comment on table erp_meta.reserved_tenant_code is
  'Codes no organisation may take as its address: the application''s own '
  'top-level routes, and words that would read as the product speaking. '
  'supabase/ci/app_addresses.sh proves every route is here.';

insert into erp_meta.reserved_tenant_code (code, reason)
select v.code, 'a top-level route of the application'
  from unnest(array[
    'act', 'administration', 'api', 'commercial', 'contact', 'device',
    'documents', 'finance', 'governance', 'help', 'inventory', 'join',
    'logistics', 'master-data', 'notifications', 'operations', 'planning',
    'platform', 'procurement', 'product', 'production', 'profile', 'quality',
    'reporting', 'sales', 'settings', 'signin']) as v(code)
union all
select v.code, 'would read as the product''s own address'
  from unnest(array[
    'www', 'app', 'admin', 'administrator', 'mail', 'email', 'smtp', 'ftp',
    'static', 'assets', 'cdn', 'docs', 'status', 'support', 'blog', 'auth',
    'login', 'logout', 'signout', 'signup', 'register', 'account', 'billing',
    'dashboard', 'console', 'root', 'system', 'staging', 'dev', 'test',
    'demo', 'clove', 'cloveerp', 'erp', 'public', 'null', 'undefined',
    'favicon', 'robots', 'sitemap', 'security', 'legal', 'privacy', 'terms',
    'about', 'pricing', 'home', 'new', 'owner', 'operator']) as v(code)
on conflict (code) do nothing;

-- An address an organisation has had. Keyed on the code, because a code
-- belongs to at most one organisation for ever. The column is owner_tenant_id
-- and not tenant_id on purpose: this is not tenant data a session reads under
-- row security, it is read only by the address doors, and a tenant_id column
-- would have the isolation report expect a policy filtering by it.
create table erp_meta.retired_tenant_code (
  code            text primary key,
  owner_tenant_id uuid not null references erp.tenant(id) on delete cascade,
  retired_at      timestamptz not null default now()
);

create index retired_tenant_code_owner on erp_meta.retired_tenant_code (owner_tenant_id);

comment on table erp_meta.retired_tenant_code is
  'Addresses an organisation has renamed away from. Each keeps opening the '
  'organisation''s current address, and no other organisation may take it.';

insert into erp_meta.table_policy (schema_name, table_name, table_class, note) values
  ('erp_meta', 'reserved_tenant_code', 'platform_internal',
   'Codes no organisation may take as its address. Read by the trigger on erp.tenant and the address doors, all definers.'),
  ('erp_meta', 'retired_tenant_code', 'platform_internal',
   'Addresses organisations have renamed away from. Read by the address doors, which answer only code and name.')
on conflict (schema_name, table_name) do nothing;

revoke all on erp_meta.reserved_tenant_code from public, anon, authenticated;
revoke all on erp_meta.retired_tenant_code from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Whether a code may be an organisation's address
-- ─────────────────────────────────────────────────────────────────────────────

-- Null when the code may be p_tenant's address; otherwise the reason it may
-- not, as a refusal code and a sentence. One function, so the trigger and the
-- door refuse in the same words.
create or replace function erp.tenant_code_refusal(p_code text, p_tenant uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when p_code is null or p_code !~ '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$' then
      'CLOVEERP_ADDRESS_SHAPE: ' || coalesce('"' || p_code || '"', 'nothing')
      || ' is not an address: use three to 63 lower-case letters, digits and hyphens, starting and ending with a letter or digit'
    when exists (select 1 from erp_meta.reserved_tenant_code r where r.code = p_code) then
      'CLOVEERP_ADDRESS_RESERVED: "' || p_code || '" is reserved and cannot be an organisation''s address'
    when exists (select 1 from erp.tenant t
                  where t.code = p_code and t.id is distinct from p_tenant) then
      'CLOVEERP_ADDRESS_TAKEN: "' || p_code || '" is another organisation''s address'
    when exists (select 1 from erp_meta.retired_tenant_code x
                  where x.code = p_code and x.owner_tenant_id is distinct from p_tenant) then
      'CLOVEERP_ADDRESS_TAKEN: "' || p_code || '" was another organisation''s address and still opens theirs'
  end
$$;

revoke all on function erp.tenant_code_refusal(text, uuid) from public, anon;

comment on function erp.tenant_code_refusal(text, uuid) is
  'Why a code may not be an organisation''s address, or null when it may (20261003100000).';

-- Holds every code set on erp.tenant to the rule, and keeps the code a rename
-- leaves behind. A code the organisation takes back is its own again.
create or replace function erp.tenant_code_is_an_address()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_refusal text;
begin
  if tg_op = 'UPDATE' and new.code is not distinct from old.code then
    return new;
  end if;

  v_refusal := erp.tenant_code_refusal(new.code, new.id);
  if v_refusal is not null then
    raise exception '%', v_refusal
      using errcode = '23514',
            hint = 'Choose another address. erp_tenant_by_address says whether a code is held.';
  end if;

  if tg_op = 'UPDATE' then
    insert into erp_meta.retired_tenant_code (code, owner_tenant_id)
    values (old.code, new.id)
    on conflict (code) do update set retired_at = now()
      where erp_meta.retired_tenant_code.owner_tenant_id = excluded.owner_tenant_id;
    delete from erp_meta.retired_tenant_code x
     where x.code = new.code and x.owner_tenant_id = new.id;
  end if;
  return new;
end;
$$;

revoke all on function erp.tenant_code_is_an_address() from public, anon, authenticated;

drop trigger if exists t_tenant_code_is_an_address on erp.tenant;
create trigger t_tenant_code_is_an_address
  before insert or update of code on erp.tenant
  for each row execute function erp.tenant_code_is_an_address();

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. The doors
-- ─────────────────────────────────────────────────────────────────────────────

-- A code, answered with the organisation's current code and its name — or
-- null. Called signed out, by the sign-in form at /<code>. An organisation
-- marked deleted has no address.
create or replace function public.erp_tenant_by_address(p_code text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with asked as (select lower(btrim(coalesce(p_code, ''))) as code)
  select jsonb_build_object('code', t.code, 'name', t.name)
    from asked a
    join erp.tenant t
      on t.code = a.code
      or t.id = (select x.owner_tenant_id from erp_meta.retired_tenant_code x where x.code = a.code)
   where t.deleted_at is null
   order by (t.code = a.code) desc
   limit 1
$$;

revoke all on function public.erp_tenant_by_address(text) from public;
grant execute on function public.erp_tenant_by_address(text) to anon, authenticated, service_role;

comment on function public.erp_tenant_by_address(text) is
  'The organisation an address names: its current code and name, or null. '
  'Callable signed out, by the sign-in form at /<code>; answers nothing else (20261003100000).';

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('public', 'erp_tenant_by_address',
   'UNGATED BY DESIGN: a signed-out visitor at /<code> has no organisation and no '
   'permission, and the sign-in form needs the organisation''s name. Runs as its '
   'owner because erp.tenant and erp_meta.retired_tenant_code are closed to anon. '
   'It answers a code with that organisation''s current code and name and nothing '
   'else, and reads no other table. Saying whether a code is held is what an '
   'address does. erp_test.tenant_address_suite proves what it answers.'),
  ('erp', 'tenant_code_refusal',
   'UNGATED BY DESIGN: says why a code may not be an address; reads the reserved '
   'and retired registers, which are closed to every session role. Returns a '
   'sentence, never a row.'),
  ('erp', 'tenant_code_is_an_address',
   'UNGATED BY DESIGN: the trigger on erp.tenant.code. Whoever may set a code has '
   'already passed their own gate; this only holds the code to the rule and '
   'writes the retired register, which no session role can reach.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

-- The organisation's own address, changed. authorise() first: the caller must
-- hold administration.configure in the organisation their session is in, and
-- only that organisation's row is touched.
create or replace function erp.set_tenant_address(p_code text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
  v_was    text;
  v_code   text := lower(btrim(coalesce(p_code, '')));
begin
  perform erp.authorise('administration.configure');
  v_tenant := erp.require_tenant_id();

  select t.code into v_was from erp.tenant t where t.id = v_tenant;
  if v_was = v_code then
    return jsonb_build_object('code', v_code, 'previous', null, 'changed', false);
  end if;

  update erp.tenant t set code = v_code where t.id = v_tenant;

  return jsonb_build_object('code', v_code, 'previous', v_was, 'changed', true);
end;
$$;

revoke all on function erp.set_tenant_address(text) from public, anon;

comment on function erp.set_tenant_address(text) is
  'Changes the caller''s organisation''s address; the old one keeps opening the new (20261003100000).';

create or replace function public.erp_set_tenant_address(p_code text)
returns jsonb
language sql
volatile
set search_path = ''
as $$ select erp.set_tenant_address(p_code) $$;

revoke all on function public.erp_set_tenant_address(text) from public, anon;
grant execute on function public.erp_set_tenant_address(text) to authenticated, service_role;

comment on function public.erp_set_tenant_address(text) is
  'Changes this organisation''s address — cloveerp.com/<code> — from the Organisation screen (20261003100000).';

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp', 'set_tenant_address',
   'Runs as its owner because erp.tenant is not writable by a session role. '
   'Gates on erp.authorise(''administration.configure'') on its first line and '
   'updates only the row of erp.require_tenant_id().')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_set_tenant_address', 'erp.set_tenant_address',
   'Changes the organisation''s address; authorises administration.configure. The old address is kept and keeps opening the new one.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/administration/organisation', array['erp_set_tenant_address']);

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. The routes are reserved, as the build proves
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.assert_route_names_reserved(p_routes text[])
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_open  text[];
  v_held  text[];
begin
  if coalesce(cardinality(p_routes), 0) = 0 then
    raise exception 'CLOVEERP_ROUTE_NAMES_EMPTY: no route names were given'
      using errcode = 'P0001',
            hint = 'supabase/ci/app_addresses.sh extracts them from src/routes; an empty list is its failure, not a pass.';
  end if;

  select array_agg(r order by r) into v_open
    from unnest(p_routes) r
   where not exists (select 1 from erp_meta.reserved_tenant_code x where x.code = r);
  select array_agg(t.code order by t.code) into v_held
    from erp.tenant t
   where t.code = any (p_routes) and t.deleted_at is null;

  if v_held is not null then
    raise exception E'CLOVEERP_ROUTE_IS_AN_ADDRESS: % route name(s) are organisations'' addresses:\n  %',
      cardinality(v_held), array_to_string(v_held, E'\n  ')
      using errcode = 'P0001',
            hint = 'The route would hide the organisation''s sign-in form. Rename the route, or agree a new address with the organisation first.';
  end if;
  if v_open is not null then
    raise exception E'CLOVEERP_ROUTE_NOT_RESERVED: % top-level route(s) could be taken as an organisation''s address:\n  %',
      cardinality(v_open), array_to_string(v_open, E'\n  ')
      using errcode = 'P0001',
            hint = 'Reserve each in erp_meta.reserved_tenant_code in the migration that ships the route.';
  end if;
  return format('route names: %s top-level, all reserved, none an address', cardinality(p_routes));
end;
$$;

revoke all on function erp.assert_route_names_reserved(text[]) from public, anon, authenticated;

insert into erp_meta.check_run_exemption (schema_name, function_name, driven_by, rationale) values
  ('erp', 'assert_route_names_reserved', null,
   'Takes the top-level route names supabase/ci/app_addresses.sh extracts from src/routes; only the build can know what the routes are, and it calls this with that list.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;
insert into erp_meta.diagnostic_exemption (schema_name, function_name, rationale) values
  ('erp', 'assert_route_names_reserved',
   'Takes the list of route names the application source contains. A console button has no such list; the build extracts it and calls this.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. The Organisation screen's words, each with the row it is renamed by
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string declared at its call site and rendered through ui(). ' || v.why
  from (values
    ('Your organisation''s address',
     'The heading of the address card on the Organisation screen.'),
    ('Where your people sign in. It puts this organisation''s name on the sign-in form; what each person can open is still decided by their own account.',
     'What the organisation''s address does, under its heading.'),
    ('Copy', 'The button that copies the organisation''s address.'),
    ('Copied', 'Said on the copy button once the address is copied.'),
    ('Change the address', 'The action that changes the organisation''s address.'),
    ('The address changes at once. The old one keeps working and opens the new one, and no other organisation can take it.',
     'What changing the organisation''s address does.'),
    ('New address', 'The field on the form that changes the organisation''s address.'),
    ('Letters, digits and hyphens, three to 63 characters.',
     'The hint under the new address field.')
  ) as v(text, why)
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. The suite
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.tenant_address_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 9;
  v_cases integer := 0;
  v_tag   text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1      uuid := gen_random_uuid();
  a2      uuid := gen_random_uuid();
  v_step  text := 'provisioning';
  v_state text;
  v_owner text := current_user;
  ra record; rb record;
  v_answer jsonb;
  v_err text;
begin
  begin
    v_step := 'two organisations, each with its administrator signed in';
    perform set_config('request.jwt.claims', '', true);
    select * into ra from erp.provision_tenant(
      'zzta-' || v_tag, 'Address Suite A', 'a@zzta-' || v_tag || '.test', 'A Admin');
    select * into rb from erp.provision_tenant(
      'zztb-' || v_tag, 'Address Suite B', 'b@zzta-' || v_tag || '.test', 'B Admin');
    insert into auth.users (id, email) values
      (a1, 'a@zzta-' || v_tag || '.test'), (a2, 'b@zzta-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(ra.admin_token);
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(rb.admin_token);

    -- 1. Signed out, the door answers a code with the name, as anon calls it.
    v_step := 'looking up an address signed out';
    perform set_config('request.jwt.claims', '', true);
    execute 'set local role anon';
    v_answer := public.erp_tenant_by_address('ZZTA-' || v_tag || ' ');
    execute format('set local role %I', v_owner);
    v_cases := v_cases + 1;
    case_name := 'a signed-out visitor is told the organisation''s code and name, and nothing else';
    passed := v_answer = jsonb_build_object('code', 'zzta-' || v_tag, 'name', 'Address Suite A');
    detail := coalesce(v_answer::text, 'no answer');
    return next;

    -- 2. A code nobody holds is null.
    v_cases := v_cases + 1;
    case_name := 'a code nobody holds answers nothing';
    passed := public.erp_tenant_by_address('zzta-none-' || v_tag) is null;
    detail := 'null for an unheld code';
    return next;

    -- 3. The administrator renames through the door, as the data API calls it.
    v_step := 'renaming as the administrator';
    perform set_config('request.jwt.claims',
      json_build_object('sub', a1, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_answer := public.erp_set_tenant_address('zztc-' || v_tag);
    execute format('set local role %I', v_owner);
    v_cases := v_cases + 1;
    case_name := 'an administrator changes the address, and the old one opens the new';
    passed := (select t.code from erp.tenant t where t.id = ra.tenant_id) = 'zztc-' || v_tag
          and (public.erp_tenant_by_address('zzta-' || v_tag) ->> 'code') = 'zztc-' || v_tag;
    detail := coalesce(v_answer::text, 'no answer');
    return next;

    -- 4. Another organisation may not take the retired address.
    v_err := null;
    perform set_config('request.jwt.claims',
      json_build_object('sub', a2, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    begin
      perform public.erp_set_tenant_address('zzta-' || v_tag);
    exception when others then v_err := left(sqlerrm, 200); end;
    execute format('set local role %I', v_owner);
    v_cases := v_cases + 1;
    case_name := 'another organisation cannot take an address somebody renamed away from';
    passed := v_err like 'CLOVEERP_ADDRESS_TAKEN:%';
    detail := coalesce(v_err, 'it was taken');
    return next;

    -- 5. Nor a held one.
    v_err := null;
    execute 'set local role authenticated';
    begin
      perform public.erp_set_tenant_address('zztc-' || v_tag);
    exception when others then v_err := left(sqlerrm, 200); end;
    execute format('set local role %I', v_owner);
    v_cases := v_cases + 1;
    case_name := 'an organisation cannot take another''s current address';
    passed := v_err like 'CLOVEERP_ADDRESS_TAKEN:%';
    detail := coalesce(v_err, 'it was taken');
    return next;

    -- 6. Nor a reserved one, nor one of the wrong shape.
    v_err := null;
    execute 'set local role authenticated';
    begin
      perform public.erp_set_tenant_address('settings');
    exception when others then v_err := left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := 'a route name is refused as an address';
    passed := v_err like 'CLOVEERP_ADDRESS_RESERVED:%';
    detail := coalesce(v_err, 'it was taken');
    return next;

    v_err := null;
    begin
      perform public.erp_set_tenant_address(repeat('a', 64));
    exception when others then v_err := left(sqlerrm, 200); end;
    execute format('set local role %I', v_owner);
    v_cases := v_cases + 1;
    case_name := 'a code longer than one DNS label is refused';
    passed := v_err like 'CLOVEERP_ADDRESS_SHAPE:%';
    detail := coalesce(v_err, 'it was taken');
    return next;

    -- 7. The organisation takes its own old address back.
    perform set_config('request.jwt.claims',
      json_build_object('sub', a1, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_answer := public.erp_set_tenant_address('zzta-' || v_tag);
    execute format('set local role %I', v_owner);
    v_cases := v_cases + 1;
    case_name := 'an organisation may take back an address it had';
    passed := (select t.code from erp.tenant t where t.id = ra.tenant_id) = 'zzta-' || v_tag
          and not exists (select 1 from erp_meta.retired_tenant_code x where x.code = 'zzta-' || v_tag)
          and exists (select 1 from erp_meta.retired_tenant_code x
                       where x.code = 'zztc-' || v_tag and x.owner_tenant_id = ra.tenant_id);
    detail := coalesce(v_answer::text, 'no answer');
    return next;

    -- 8. Nobody signed out reaches the write door.
    v_step := 'renaming signed out';
    v_err := null;
    perform set_config('request.jwt.claims', '', true);
    execute 'set local role anon';
    begin
      perform public.erp_set_tenant_address('zztd-' || v_tag);
    exception when others then v_err := left(sqlerrm, 200); end;
    execute format('set local role %I', v_owner);
    v_cases := v_cases + 1;
    case_name := 'a signed-out caller cannot change an address';
    passed := v_err is not null
          and not exists (select 1 from erp.tenant t where t.code = 'zztd-' || v_tag);
    detail := coalesce(v_err, 'it was changed');
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  execute format('set local role %I', v_owner);
  perform set_config('request.jwt.claims', '', true);

  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_TENANT_ADDRESS_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the fixture stopped; a case that cannot run is a case that fails.';
  end if;
  if exists (select 1 from erp.tenant t where t.code in ('zzta-' || v_tag, 'zztb-' || v_tag, 'zztc-' || v_tag))
     or exists (select 1 from auth.users u where u.id in (a1, a2)) then
    raise exception 'CLOVEERP_TENANT_ADDRESS_SUITE_LEAKED: the fixture was not undone'
      using hint = 'The suite must raise CLOVEERP_SUITE_UNDO inside its block so everything it made rolls back.';
  end if;
end;
$$;

revoke all on function erp_test.tenant_address_suite() from public, anon, authenticated;

create or replace function erp_test.assert_tenant_address_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)),
         count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.tenant_address_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_TENANT_ADDRESS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'An address would open the wrong organisation, be taken from its owner, or be changed by somebody who may not. Read the case that failed.';
  end if;
  if v_total <> 9 then
    raise exception 'CLOVEERP_TENANT_ADDRESS_SUITE_SHRANK: % case(s), expected 9', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('tenant address: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_tenant_address_suite() from public, anon;

comment on function erp_test.assert_tenant_address_suite() is
  'An organisation has an address, and only its administrator changes it (20261003100000).';

-- The generators, which are idempotent and run at the end of every migration.
select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

-- apply_execute_grants() grants from the invoker reach, which does not name a
-- door a signed-out visitor calls. Granted again after it, so the reach report
-- and this door agree on the one thing anon may execute here.
grant execute on function public.erp_tenant_by_address(text) to anon, authenticated, service_role;

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
select erp.assert_every_transition_is_driven();
select erp.assert_parameter_budget();
