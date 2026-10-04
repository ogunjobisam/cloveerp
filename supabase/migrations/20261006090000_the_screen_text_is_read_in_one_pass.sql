set lock_timeout = '30s';

-- =============================================================================
-- 20261006090000  The screen text is read in one pass
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-39). Every full page
-- load reads public.erp_resources(locale), the words of every screen, and on
-- live it took 1.5 seconds at best and 3.2 on average.
--
-- For each product string (about 6,000 in English, and English is read twice:
-- once in the locale chain and once more as the last fallback) it looked the
-- organisation's own wording up in a correlated subquery on
-- erp.resource_override. That table's row policy is
-- tenant_id = erp.current_tenant_id(), and the policy is answered again on
-- every run of the subquery, so one page load asked erp.principal_context()
-- who was signed in 12,176 times on the fixtures. The materialised tenant at
-- the top of the body, meant to stop exactly this, did not: the policy brought
-- the call back.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. public.erp_resources(locale), same signature, grants and answer: the
--      organisation's active overrides for the locales in the chain are read
--      once (one row per key and locale) and joined to the product strings,
--      and English is read once when the chain already holds it. Where both
--      the organisation and one of its companies reword the same string in
--      the same locale, the bundle carries the organisation's words; before,
--      'limit 1' took whichever row came first.
--   B. erp_test.assurance_walks_suite, which already compares the door with
--      the body that asked on every row, now also compares en-GB and de, and
--      compares every locale a second time as the administrator of an
--      organisation that has reworded a string in English and in German and
--      has a term of its own, and checks the bundle carries them. One case is
--      added: the organisation's words win over one company's. 10 cases
--      become 11.
--
-- On production: one door is replaced. No table is altered and no row is
-- changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The overrides, read once
-- ─────────────────────────────────────────────────────────────────────────────

do $guard$
declare
  v_src text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = 'public.erp_resources(text)'::regprocedure);
begin
  if strpos(v_src, '20261006090000') = 0 and md5(v_src) <> '0491bfd23c29fa9ff8cf05a3553d79c0' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: public.erp_resources(text) is not the body 20261006090000 expects (md5 %)', md5(v_src);
  end if;
end
$guard$;

create or replace function public.erp_resources(p_locale text default 'en')
returns jsonb
language sql
stable
set search_path = ''
as $$
  with recursive tenant as materialized (
      -- Once per call. Written into the lookups below it ran for every product
      -- row, and erp.current_tenant_id() runs erp.principal_context() each time.
      select erp.current_tenant_id() as id
  ),
  chain(code, parent_locale, depth) as (
      select l.code, l.parent_locale, 0
        from erp_ref.locale l
       where l.code = coalesce(p_locale, 'en')
      union all
      select l.code, l.parent_locale, chain.depth + 1
        from chain
        join erp_ref.locale l on l.code = chain.parent_locale
       where chain.depth < 4
  ),
  -- English ends every chain; read once if the chain already holds it.
  steps as (
      select code, depth from chain
      union all
      select 'en', 99 where not exists (select 1 from chain c where c.code = 'en')
  ),
  -- The organisation's own wording, read once (20261006090000, J-39): one row
  -- per key and locale, the organisation's own before any one company's.
  -- Looked up per product string, the table's row policy asked who was signed
  -- in once for every string.
  ov as materialized (
      select distinct on (o.key, o.locale) o.key, o.locale, o.value, o.entity_id
        from tenant t
        join erp.resource_override o on o.tenant_id = t.id
       where o.status = 'active'::erp.record_status
         and o.locale in (select s.code from steps s)
       order by o.key, o.locale, (o.entity_id is null) desc, o.id
  ),
  resolved as (
      select r.key, coalesce(ov.value, r.value) as value, s.depth
        from steps s
        join erp_ref.resource r on r.locale = s.code
        left join ov on ov.key = r.key and ov.locale = r.locale
      union all
      -- Tenant-defined terms: no product row to join, so they are their own
      -- source, at the depth of the locale they were written in.
      select ov.key, ov.value, s.depth
        from steps s
        join ov on ov.locale = s.code
       where ov.key like 'custom.%'
         and ov.entity_id is null
  ),
  ranked as (
      select key, value, row_number() over (partition by key order by depth) as rn
        from resolved
  )
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    from ranked where rn = 1
$$;

comment on function public.erp_resources(text) is
  'Every resource key resolved for a locale: tenant override first, then the product string, walking '
  'erp_ref.locale.parent_locale and ending at en. Before this it matched the locale exactly, so asking for en-US '
  'returned the four rows that existed there and left 687 strings to the fallback compiled into the components. '
  'The organisation''s overrides are read once and joined, its own wording before any one company''s '
  '(20261006090000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The proof: the same words, with and without an organisation's own
-- ─────────────────────────────────────────────────────────────────────────────

do $suite$
declare
  v_sig  constant text := 'erp_test.assurance_walks_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old_decl constant text := $o$  v_run           jsonb;
$o$;
  v_new_decl constant text := $n$  v_run           jsonb;
  -- An organisation with its own words (20261006090000).
  v_owner         text := current_user;
  v_tag           text := substr(md5(gen_random_uuid()::text), 1, 6);
  v_auth          uuid := gen_random_uuid();
  v_org           record;
  v_pass          integer;
  v_key           text;
  v_carried       boolean := true;
  v_company_word  text;
$n$;
  v_old_loop constant text := $o$    foreach v_locale in array array['en', 'en-US', 'de-AT'] loop
      v_bundle_new := public.erp_resources(v_locale);
$o$;
  v_new_loop constant text := $n$    -- Twice (20261006090000, J-39): with no organisation, and then as the
    -- administrator of one that has reworded a string in English and in
    -- German and has a term of its own.
    for v_pass in 1 .. 2 loop
    if v_pass = 2 then
      perform set_config('request.jwt.claims', '', true);
      select * into v_org from erp.provision_tenant(
        'zzaw-' || v_tag, 'Assurance Walks Suite', 'admin@zzaw-' || v_tag || '.test', 'Walks Admin');
      update erp.environment set is_live = false where tenant_id = v_org.tenant_id and is_self;
      insert into auth.users (id, email) values (v_auth, 'admin@zzaw-' || v_tag || '.test');
      perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
      perform erp.claim_invitation(v_org.admin_token);
      select r.key into v_key
        from erp_ref.resource r
       where r.locale = 'de'
         and exists (select 1 from erp_ref.resource e where e.locale = 'en' and e.key = r.key)
       order by r.key limit 1;
      insert into erp.resource_override (tenant_id, key, locale, value) values
        (v_org.tenant_id, v_key, 'en', 'Our own words'),
        (v_org.tenant_id, v_key, 'de', 'Unsere eigenen Worte'),
        (v_org.tenant_id, 'custom.zz_aw_term', 'en', 'Our own term');
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
    end if;
    foreach v_locale in array array['en', 'en-US', 'en-GB', 'de', 'de-AT'] loop
      v_bundle_new := public.erp_resources(v_locale);
$n$;
  v_old_tail constant text := $o$      v_bundles_same := v_bundles_same and v_bundle_new = v_bundle_old;
      v_bundles := v_bundles || format('%s %s/%s keys; ', v_locale,
        (select count(*) from jsonb_object_keys(v_bundle_new)),
        (select count(*) from jsonb_object_keys(v_bundle_old)));
    end loop;
$o$;
  v_new_tail constant text := $n$      v_bundles_same := v_bundles_same and v_bundle_new = v_bundle_old;
      v_bundles := v_bundles || format('%s%s %s/%s keys; ',
        case when v_pass = 2 then 'its own words, ' else '' end, v_locale,
        (select count(*) from jsonb_object_keys(v_bundle_new)),
        (select count(*) from jsonb_object_keys(v_bundle_old)));
      if v_pass = 2 then
        v_carried := v_carried
          and v_bundle_new ->> v_key = case when v_locale like 'de%' then 'Unsere eigenen Worte' else 'Our own words' end
          and v_bundle_new ->> 'custom.zz_aw_term' = 'Our own term';
      end if;
    end loop;
    end loop;

    -- One company of the organisation rewords the same string in the same
    -- language: the organisation's words are the bundle's (20261006090000).
    execute format('set local role %I', v_owner);
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    insert into erp.resource_override (tenant_id, key, locale, value, entity_id)
      select v_org.tenant_id, v_key, 'en', 'One company''s words', e.id
        from erp.entity e where e.tenant_id = v_org.tenant_id order by e.code limit 1;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_auth, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_company_word := public.erp_resources('en') ->> v_key;
    execute format('set local role %I', v_owner);
    perform set_config('request.jwt.claims', '', true);
$n$;
  v_old_case8 constant text := $o$  passed := v_msg is null and v_bundles_same;
$o$;
  v_new_case8 constant text := $n$  passed := v_msg is null and v_bundles_same and v_carried;
$n$;
  v_old_case10 constant text := $o$        and not exists (select 1 from erp_meta.transaction_path_function t
                         where t.function_name like 'zz\_ib\_%');
  detail := 'twenty-seven functions and three transaction-path rows rolled back';
  return next;
$o$;
  v_new_case10 constant text := $n$        and not exists (select 1 from erp_meta.transaction_path_function t
                         where t.function_name like 'zz\_ib\_%')
        and not exists (select 1 from erp.tenant t where t.code = 'zzaw-' || v_tag)
        and not exists (select 1 from auth.users u where u.id = v_auth);
  detail := 'twenty-seven functions, three transaction-path rows and the organisation with its own words rolled back';
  return next;

  -- 11 (20261006090000)
  case_name := 'where the organisation and one company both reword a string, the bundle carries the organisation''s words';
  passed := v_msg is null and v_company_word = 'Our own words';
  detail := coalesce(v_msg, format('the bundle reads %s', coalesce(v_company_word, 'nothing')));
  return next;
$n$;
  v_anchor record;
begin
  if strpos(v_src, '20261006090000') > 0 then
    raise notice '% already compares an organisation''s own words; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'd8fdbaf3151aea4cc863b4f834d8a7a0' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006090000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  for v_anchor in
    select * from (values
      ('declarations', v_old_decl, v_new_decl),
      ('locale loop', v_old_loop, v_new_loop),
      ('loop end', v_old_tail, v_new_tail),
      ('case 8', v_old_case8, v_new_case8),
      ('case 10', v_old_case10, v_new_case10)) a(name, old_text, new_text)
  loop
    if (length(v_def) - length(replace(v_def, v_anchor.old_text, ''))) / length(v_anchor.old_text) <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % % anchor found other than once', v_sig, v_anchor.name;
    end if;
    v_def := replace(v_def, v_anchor.old_text, v_anchor.new_text);
  end loop;
  execute v_def;
end
$suite$;

revoke all on function erp_test.assurance_walks_suite() from public, anon, authenticated;

comment on function erp_test.assurance_walks_suite() is
  'Assurance walks from the far end find what the old walks found (20260914090000); and the screen text, read with '
  'the overrides once, is the bundle the body that asked on every row gave, with and without an organisation''s own '
  'words, the organisation''s before one company''s (20261006090000, J-39).';

create or replace function erp_test.assert_assurance_walks_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 11;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  select count(*), count(*) filter (where coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n') filter (where not coalesce(s.passed, false))
    into v_total, v_passed, v_detail
    from erp_test.assurance_walks_suite() s;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_ASSURANCE_WALKS_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_ASSURANCE_WALKS_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('assurance walks: %s/%s cases passed', v_passed, v_total);
end;
$$;

revoke all on function erp_test.assert_assurance_walks_suite() from public, anon, authenticated;

comment on function erp_test.assert_assurance_walks_suite() is
  'The assurance walks find what the old walks found, and the screen text read in one pass is the same bundle '
  '(20261006090000).';

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
