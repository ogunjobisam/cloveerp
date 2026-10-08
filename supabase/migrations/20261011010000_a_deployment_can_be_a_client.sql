set lock_timeout = '30s';

-- =============================================================================
-- 20261011010000  A deployment can be a client
-- -----------------------------------------------------------------------------
-- The owner's decision of 7 October: every client gets a Supabase project of
-- its own and an address of its own, <code>.cloveerp.com, served by the same
-- application. Production stays what it is, with Clove Foods on it, and
-- becomes the control plane as well: the platform console, the contracts, the
-- enquiries, and a register of the client deployments (the next migration).
-- Releases go to the demonstration first, then to every client at once, then
-- to the control plane last, and a client that fails stops the control plane.
--
-- A database that is a client's must know it. 20261010060000 gave every
-- database one word about itself, production or demonstration, read by the
-- doors that make demonstrations and by the screens. A client is neither:
-- not production, where the control plane's doors work and Clove Foods
-- trades, and not the demonstration, where invented organisations are made.
-- And with more than two databases, "which kind" is no longer enough to tell
-- a connection string filed under the wrong name: two clients are the same
-- kind. So a database also learns which project it is, and where it is
-- served from.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. Four refusals: one re-worded, three new.
--   B. erp.deployment_kind() admits a third answer, 'client'. Absent still
--      means production.
--   C. erp_meta.mark_deployment() accepts 'client'. Everything else it does
--      stands: once said, never changed by a release; a database holding a
--      live organisation is never marked a demonstration.
--   D. erp.require_control_plane(): the gate for what only the control plane
--      does — keep the register of deployments, make contracts, take
--      enquiries. The register's doors call it on their first line; the
--      existing control-plane doors are brought to it in a later migration.
--   E. erp_meta.set_deployment_identity(ref, origin): the database's own
--      project ref, written once by the first release after this and only
--      confirmed after — a release to the wrong database is refused by the
--      database it reaches, not only by the name on the connection string —
--      and the address it is served from, which also becomes app.base_url,
--      the address every product email and in-app notice links to. Readers
--      erp.deployment_ref() and erp.app_origin().
--   F. public.erp_platform_me() answers the origin and the project ref beside
--      the kind, so the screens can say where they are.
--   G. erp_test.deployment_marker_suite grows from six cases to eight.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- No door, permission or screen string. On production and the demonstration:
-- no row is written by this migration. The first release after it writes
-- deployment.ref and deployment.app_origin on each, and app.base_url keeps
-- the value it had unless the release says otherwise. A client database does
-- not exist yet.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The refusals
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal(
  'CLOVEERP_DEPLOYMENT_KIND_UNKNOWN',
  'Marking a deployment as something other than production, a demonstration or a client.',
  'A deployment is production, the control plane, where Clove ERP itself and the organisations it hosts trade; '
  'the demonstration, where prospects are shown invented ones; or a client''s own project, where one customer '
  'trades on a database of its own. There is no fourth kind.',
  'Mark it production, demonstration or client.');

select erp.register_refusal(
  'CLOVEERP_DEPLOYMENT_REF_INVALID',
  'Telling a database its project is something that is not a Supabase project ref.',
  'A project ref is twenty lower-case letters and digits, the way every Supabase connection string names it.',
  'Pass the project ref the connection string names.');

select erp.register_refusal(
  'CLOVEERP_DEPLOYMENT_REF_IS_SET',
  'Changing which project a database says it runs in.',
  'A database says once which project it runs in, and a release only confirms it, so a connection string filed '
  'under another deployment''s name is refused by the database it reaches.',
  'Check that the release is pointed at the database you meant. If the ref really is wrong, the platform owner '
  'removes the deployment.ref setting by hand and the next release writes it again.');

select erp.register_refusal(
  'CLOVEERP_DEPLOYMENT_ORIGIN_INVALID',
  'Telling a database it is served from something that is not an https address.',
  'The address a deployment is served from is where every product email and in-app notice links to, so it is an '
  'https origin and nothing else: no path, no query, no trailing slash.',
  'Pass the origin as https://<host>, for example https://acme.cloveerp.com.');

select erp.register_refusal(
  'CLOVEERP_NOT_THE_CONTROL_PLANE',
  'Doing the control plane''s work on a demonstration or on a client''s deployment.',
  'The register of client deployments, the contracts and the enquiries live on production, the control plane. '
  'A client''s database holds one customer and knows nothing of the others; the demonstration holds invented ones.',
  'Open the platform console at cloveerp.com and do it there.');

-- ─────────────────────────────────────────────────────────────────────────────
-- B. Which deployment this is: three answers
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.deployment_kind()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  -- Absent means production (20261010060000): a database nobody marked
  -- behaves as production always has. 'client' since 20261011010000.
  select coalesce(
    (select s.value #>> '{}'
       from erp_meta.platform_setting s
      where s.key = 'deployment.kind'
        and s.value #>> '{}' in ('production', 'demonstration', 'client')),
    'production')
$$;

revoke all on function erp.deployment_kind() from public, anon;

comment on function erp.deployment_kind() is
  'Which deployment this database is: ''production'' (the control plane, cloveerp.com), ''demonstration'' (the '
  'Clove ERP Demo project at demo.cloveerp.com, and the schema build) or ''client'' (one customer''s own project, '
  '<code>.cloveerp.com). Read from the platform setting deployment.kind; absent means production '
  '(20261010060000, 20261011010000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. Saying which deployment this is
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_meta.mark_deployment(p_kind text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_kind  text := lower(btrim(coalesce(p_kind, '')));
  v_now   text;
  v_live  text;
begin
  if v_kind not in ('production', 'demonstration', 'client') then
    raise exception 'CLOVEERP_DEPLOYMENT_KIND_UNKNOWN: a deployment is production, demonstration or client, not "%"', p_kind
      using errcode = '22023',
            hint = 'Mark it production, demonstration or client.';
  end if;

  select s.value #>> '{}' into v_now
    from erp_meta.platform_setting s
   where s.key = 'deployment.kind';

  if v_now = v_kind then
    return format('deployment: %s, as it already was', v_kind);
  end if;

  if v_now is not null then
    raise exception 'CLOVEERP_DEPLOYMENT_KIND_IS_SET: this database is the % deployment and a deploy does not make it the %', v_now, v_kind
      using errcode = '55000',
            hint = 'Check that the deploy is pointed at the database you meant. If the kind really is wrong, the '
                   'platform owner removes the deployment.kind setting by hand and the next deploy writes it again.';
  end if;

  if v_kind = 'demonstration' then
    select string_agg(t.code, ', ' order by t.code) into v_live
      from erp.tenant t
     where t.status not in ('deleting', 'deleted')
       and exists (select 1 from erp.environment e
                    where e.tenant_id = t.id and e.is_self and e.is_live);
    if v_live is not null then
      raise exception 'CLOVEERP_DEPLOYMENT_HOLDS_LIVE_ORGANISATIONS: % is live here, so this database is not a demonstration', v_live
        using errcode = '55000',
              hint = 'Check that the deploy is pointed at the demonstration''s database, not production''s.';
    end if;
  end if;

  insert into erp_meta.platform_setting (key, value, reason, updated_at)
  values ('deployment.kind', to_jsonb(v_kind),
          'Written by the trusted build role (deploy.yml, a build from empty, or the schema build) '
          'to say which deployment this database is (20261010060000, 20261011010000).',
          now());

  return format('deployment: %s, marked', v_kind);
end;
$$;

revoke all on function erp_meta.mark_deployment(text) from public, anon, authenticated, service_role;

comment on function erp_meta.mark_deployment(text) is
  'Says once which deployment this database is, production, demonstration or client, for the trusted build role '
  'only (deploy.yml per target, a build from empty, the schema build). Repeating the same kind changes nothing; '
  'changing it is refused, and a database holding a live organisation is never marked a demonstration '
  '(20261010060000, 20261011010000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- D. What only the control plane does
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.require_control_plane()
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if erp.deployment_kind() <> 'production' then
    raise exception 'CLOVEERP_NOT_THE_CONTROL_PLANE: this is a % deployment; the register of deployments, contracts and enquiries live on the control plane', erp.deployment_kind()
      using errcode = '42501',
            hint = 'Open the platform console at cloveerp.com and do it there.';
  end if;
end;
$$;

revoke all on function erp.require_control_plane() from public, anon;

comment on function erp.require_control_plane() is
  'Refuses with CLOVEERP_NOT_THE_CONTROL_PLANE anywhere but production, the control plane (erp.deployment_kind()). '
  'Asked by the doors that keep the register of client deployments, and by nothing a client''s own console needs '
  '(20261011010000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- E. Which project this is, and where it is served from
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.deployment_ref()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  -- The Supabase project this database runs in, as the first release after
  -- 20261011010000 wrote it; null on a database no release has told yet.
  select s.value #>> '{}'
    from erp_meta.platform_setting s
   where s.key = 'deployment.ref'
$$;

revoke all on function erp.deployment_ref() from public, anon;

comment on function erp.deployment_ref() is
  'The Supabase project ref this database runs in, as erp_meta.set_deployment_identity() wrote it, or null before '
  'any release said (20261011010000).';

create or replace function erp.app_origin()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  -- Where this deployment is served from: the setting a release wrote, else
  -- the product string every email has always linked to, else the apex.
  select coalesce(
    (select s.value #>> '{}' from erp_meta.platform_setting s where s.key = 'deployment.app_origin'),
    (select r.value from erp_ref.resource r where r.key = 'app.base_url' and r.locale = 'en'),
    'https://cloveerp.com')
$$;

revoke all on function erp.app_origin() from public, anon;

comment on function erp.app_origin() is
  'The https origin this deployment is served from (https://cloveerp.com, https://demo.cloveerp.com, '
  'https://<code>.cloveerp.com): the setting deployment.app_origin, else app.base_url, else the apex '
  '(20261011010000).';

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp', 'deployment_ref',
   'Reads the one platform-wide deployment.ref setting in erp_meta, which no organisation owns and a signed-in '
   'caller cannot read. Answers a project ref, which the application bundle already carries, and nothing about '
   'any organisation or person.'),
  ('erp', 'app_origin',
   'Reads the one platform-wide deployment.app_origin setting in erp_meta and the product string app.base_url. '
   'Answers the address this deployment is served from and nothing about any organisation or person.')
on conflict do nothing;

create or replace function erp_meta.set_deployment_identity(p_ref text, p_origin text default null)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_ref    text := lower(btrim(coalesce(p_ref, '')));
  v_origin text := nullif(btrim(coalesce(p_origin, '')), '');
  v_now    text;
  v_said   text;
begin
  if v_ref !~ '^[a-z0-9]{20}$' then
    raise exception 'CLOVEERP_DEPLOYMENT_REF_INVALID: "%" is not a Supabase project ref', p_ref
      using errcode = '22023',
            hint = 'Pass the project ref the connection string names.';
  end if;

  select s.value #>> '{}' into v_now
    from erp_meta.platform_setting s
   where s.key = 'deployment.ref';

  if v_now is not null and v_now <> v_ref then
    raise exception 'CLOVEERP_DEPLOYMENT_REF_IS_SET: this database runs in project % and a release does not make it %', v_now, v_ref
      using errcode = '55000',
            hint = 'Check that the release is pointed at the database you meant. If the ref really is wrong, the '
                   'platform owner removes the deployment.ref setting by hand and the next release writes it again.';
  end if;

  if v_now is null then
    insert into erp_meta.platform_setting (key, value, reason, updated_at)
    values ('deployment.ref', to_jsonb(v_ref),
            'Written by the trusted build role (release.yml, a build from empty) to say which Supabase project this '
            'database runs in, so a release to the wrong database is refused by the database (20261011010000).',
            now());
    v_said := format('project %s, written', v_ref);
  else
    v_said := format('project %s, as it already was', v_ref);
  end if;

  if v_origin is not null then
    if v_origin !~ '^https://[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*(:[0-9]{1,5})?$' then
      raise exception 'CLOVEERP_DEPLOYMENT_ORIGIN_INVALID: "%" is not an https origin', p_origin
        using errcode = '22023',
              hint = 'Pass the origin as https://<host>, for example https://acme.cloveerp.com.';
    end if;
    insert into erp_meta.platform_setting (key, value, reason, updated_at)
    values ('deployment.app_origin', to_jsonb(v_origin),
            'Written by the trusted build role (release.yml, a build from empty): where this deployment is served '
            'from, and so where every product email and in-app notice links to (20261011010000).',
            now())
    on conflict (key) do update
       set value = excluded.value, reason = excluded.reason, updated_at = excluded.updated_at, updated_by = null;
    -- The address every product email and in-app notice has always linked to
    -- (20260913121000, 20261007120000) follows the deployment it is sent from.
    update erp_ref.resource r
       set value = v_origin
     where r.key = 'app.base_url'
       and r.locale in ('en', 'de')
       and r.value is distinct from v_origin;
    v_said := v_said || format(', served at %s', v_origin);
  end if;

  return v_said;
end;
$$;

revoke all on function erp_meta.set_deployment_identity(text, text) from public, anon, authenticated, service_role;

comment on function erp_meta.set_deployment_identity(text, text) is
  'Says which Supabase project this database runs in (once; confirming it again changes nothing, changing it is '
  'refused) and, when given, where it is served from, which also becomes app.base_url. For the trusted build '
  'role only: release.yml after every replay, and a build from empty (20261011010000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- F. The screens are told where they are
-- ─────────────────────────────────────────────────────────────────────────────

do $me$
declare
  v_sig  constant text := 'public.erp_platform_me()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o$'claimable', false,
                              'deployment', erp.deployment_kind());$o$;
  v_new1 constant text := $n$'claimable', false,
                              'deployment', erp.deployment_kind(),
                              'origin', erp.app_origin(),
                              'project_ref', erp.deployment_ref());$n$;
  v_old2 constant text := $o$    -- screens offer a link to the demonstration instead of making one here.
    'deployment', erp.deployment_kind());$o$;
  v_new2 constant text := $n$    -- screens offer a link to the demonstration instead of making one here.
    'deployment', erp.deployment_kind(),
    -- Where this deployment is served from and which project it is
    -- (20261011010000), so a client's console can say so.
    'origin', erp.app_origin(),
    'project_ref', erp.deployment_ref());$n$;
begin
  if strpos(v_src, '20261011010000') > 0 then
    raise notice '% already answers the origin; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'c4e8b58f016b39c59fccd1b6203cda12' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261011010000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1) <> 1
     or (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(replace(v_def, v_old1, v_new1), v_old2, v_new2);
end
$me$;

-- ─────────────────────────────────────────────────────────────────────────────
-- G. The proof: eight cases
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.deployment_marker_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 8;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  v_step   text := 'clearing the marker';
  v_state  text;
  v_got    text;
  v_got2   text;
  v_got3   text;
  v_me     jsonb;
  rb       record;
begin
  begin
    -- Whatever this database was marked, it is unmarked for the length of the
    -- suite and put back by the undo at the end.
    delete from erp_meta.platform_setting where key in ('deployment.kind', 'deployment.ref', 'deployment.app_origin');

    -- ── 1. Unmarked is production ───────────────────────────────────────────
    v_step := 'reading an unmarked database';
    v_got := erp.deployment_kind();
    v_cases := v_cases + 1;
    case_name := 'a database nobody marked is production';
    passed := v_got = 'production';
    detail := v_got;
    return next;

    -- ── 2. Marked a demonstration, and the screens are told ─────────────────
    v_step := 'marking a demonstration';
    perform erp_meta.mark_deployment('demonstration');
    v_me := public.erp_platform_me();
    v_cases := v_cases + 1;
    case_name := 'a database with no live organisation is marked a demonstration, and erp_platform_me says so';
    passed := erp.deployment_kind() = 'demonstration' and v_me ->> 'deployment' = 'demonstration';
    detail := erp.deployment_kind() || ' / ' || coalesce(v_me ->> 'deployment', 'no deployment in erp_platform_me');
    return next;

    -- ── 3. Saying it again changes nothing ──────────────────────────────────
    v_step := 'marking it again';
    v_got := erp_meta.mark_deployment('demonstration');
    v_cases := v_cases + 1;
    case_name := 'marking a demonstration a demonstration again changes nothing';
    passed := v_got like '%as it already was%' and erp.deployment_kind() = 'demonstration';
    detail := v_got;
    return next;

    -- ── 4. A deploy does not change the kind ────────────────────────────────
    v_step := 'marking the demonstration production';
    begin
      perform erp_meta.mark_deployment('production');
      v_got := 'it was marked production';
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a demonstration is not re-marked production by a deploy';
    passed := v_got like 'CLOVEERP_DEPLOYMENT_KIND_IS_SET%' and erp.deployment_kind() = 'demonstration';
    detail := v_got;
    return next;

    -- ── 5. No fourth kind ───────────────────────────────────────────────────
    v_step := 'marking a fourth kind';
    begin
      perform erp_meta.mark_deployment('staging');
      v_got := 'it was accepted';
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a deployment is production, a demonstration or a client and nothing else';
    passed := v_got like 'CLOVEERP_DEPLOYMENT_KIND_UNKNOWN%';
    detail := v_got;
    return next;

    -- ── 6. A client is the third kind ───────────────────────────────────────
    -- Marked a client, the screens are told, demonstrations are refused there
    -- as on production (20261010061000), and the control plane's work is
    -- refused there too.
    v_step := 'marking a client';
    delete from erp_meta.platform_setting where key = 'deployment.kind';
    perform erp_meta.mark_deployment('client');
    v_me := public.erp_platform_me();
    begin
      perform erp.require_demonstration_deployment();
      v_got := 'a demonstration could be made here';
    exception when others then
      v_got := sqlerrm;
    end;
    begin
      perform erp.require_control_plane();
      v_got2 := 'the control plane''s work could be done here';
    exception when others then
      v_got2 := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a database with no live organisation is marked a client, erp_platform_me says so, and neither a demonstration nor the control plane''s work is allowed there';
    passed := erp.deployment_kind() = 'client'
          and v_me ->> 'deployment' = 'client'
          and v_got like 'CLOVEERP_DEMONSTRATIONS_LIVE_ELSEWHERE%'
          and v_got2 like 'CLOVEERP_NOT_THE_CONTROL_PLANE%';
    detail := erp.deployment_kind() || ' / ' || coalesce(v_me ->> 'deployment', 'no deployment in erp_platform_me')
              || ' / ' || left(v_got, 60) || ' / ' || left(v_got2, 60);
    return next;

    -- ── 7. Which project, and where it is served from ───────────────────────
    -- Written once; the same ref again changes nothing; another ref is
    -- refused; the origin follows into app.base_url and erp_platform_me.
    v_step := 'saying which project this is';
    v_got := erp_meta.set_deployment_identity('abcdefghijklmnopqrst', 'https://zzdep-' || v_tag || '.example');
    v_got2 := erp_meta.set_deployment_identity('abcdefghijklmnopqrst', null);
    begin
      perform erp_meta.set_deployment_identity('zzzzzzzzzzzzzzzzzzzz', null);
      v_got3 := 'the ref was changed';
    exception when others then
      v_got3 := sqlerrm;
    end;
    v_me := public.erp_platform_me();
    v_cases := v_cases + 1;
    case_name := 'a database is told its project once and where it is served from, which every notice then links to';
    passed := erp.deployment_ref() = 'abcdefghijklmnopqrst'
          and v_got like '%written%'
          and v_got2 like '%as it already was%'
          and v_got3 like 'CLOVEERP_DEPLOYMENT_REF_IS_SET%'
          and erp.app_origin() = 'https://zzdep-' || v_tag || '.example'
          and (select r.value from erp_ref.resource r where r.key = 'app.base_url' and r.locale = 'en')
              = 'https://zzdep-' || v_tag || '.example'
          and (select r.value from erp_ref.resource r where r.key = 'app.base_url' and r.locale = 'de')
              = 'https://zzdep-' || v_tag || '.example'
          and v_me ->> 'origin' = 'https://zzdep-' || v_tag || '.example'
          and v_me ->> 'project_ref' = 'abcdefghijklmnopqrst';
    detail := coalesce(erp.deployment_ref(), 'no ref') || ' / ' || erp.app_origin() || ' / ' || left(v_got3, 60)
              || ' / ' || coalesce(v_me ->> 'origin', 'no origin in erp_platform_me');
    return next;

    -- ── 8. A live organisation means production ─────────────────────────────
    -- provision_tenant leaves the organisation live, as every real one is.
    v_step := 'a live organisation';
    delete from erp_meta.platform_setting where key = 'deployment.kind';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzdep-' || v_tag, 'Deployment Marker Suite', 'admin@zzdep-' || v_tag || '.test', 'Deployment Admin');
    begin
      perform erp_meta.mark_deployment('demonstration');
      v_got := 'it was marked a demonstration';
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a database where an organisation is live is never marked a demonstration';
    passed := v_got like 'CLOVEERP_DEPLOYMENT_HOLDS_LIVE_ORGANISATIONS%' and erp.deployment_kind() = 'production';
    detail := v_got;
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
    raise exception 'CLOVEERP_DEPLOYMENT_MARKER_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.deployment_marker_suite() from public, anon;

comment on function erp_test.deployment_marker_suite() is
  'Which deployment a database is (20261010060000, 20261011010000): unmarked is production; a database with no '
  'live organisation is marked a demonstration or a client and erp_platform_me says so; saying it again changes '
  'nothing; a deploy never changes the kind; there is no fourth kind; a client refuses demonstrations and the '
  'control plane''s work; a database is told its project once and where it is served from; a database with a '
  'live organisation is never a demonstration.';

create or replace function erp_test.assert_deployment_marker_suite()
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
    from erp_test.deployment_marker_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_DEPLOYMENT_MARKER_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'The database misreads which deployment it is, the marker can be changed by a deploy, or it misreads its own project. Read the case that failed.';
  end if;
  if v_total <> 8 then
    raise exception 'CLOVEERP_DEPLOYMENT_MARKER_SUITE_SHRANK: % case(s), expected 8', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('deployment marker: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_deployment_marker_suite() from public, anon;

comment on function erp_test.assert_deployment_marker_suite() is
  'A database knows whether it is production, the demonstration or a client, absent means production, a deploy '
  'cannot change which, and it knows its own project once told (20261010060000, 20261011010000).';

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
