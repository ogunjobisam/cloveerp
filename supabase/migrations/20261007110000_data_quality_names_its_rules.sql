set lock_timeout = '30s';

-- =============================================================================
-- 20261007110000  Data quality names its rules
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-112). Reports, Business
-- partner data quality, gave each partner a score and counted its errors and
-- warnings (AIR and ROAD one error each, twenty-four partners one warning
-- each) and never said which rule a record failed, so nothing could be acted
-- on. erp.data_quality_report(text) evaluated every rule twice per record to
-- count the failures and threw away their messages.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.data_quality_report(text) answers a 'failing' column: the message
--      of every rule the record does not satisfy, errors first, then warnings,
--      by rule code, one after another; null where it satisfies them all. It
--      evaluates each record's rules once for the counts and the messages
--      together. The score is still erp.data_quality_score's, unchanged, and
--      the order is the same. public.erp_data_quality reads it through
--      to_jsonb, so the door answers 'failing' with no change of its own.
--   B. erp_test.data_quality_names_its_rules_suite.
--
-- The screen's half is in src/lib/modules.tsx: the report has a Finding
-- column.
--
-- On production: one function is dropped and created again with one more
-- column (its result type changes, so it cannot be replaced in place). No
-- table is altered and no row is changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The report names the rules a record fails
-- ─────────────────────────────────────────────────────────────────────────────

do $report$
declare
  v_sig  constant text := 'erp.data_quality_report(text)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
begin
  if strpos(v_src, '20261007110000') > 0 then
    raise notice '% already names the rules a record fails; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '7c1a5ee1d255b2e244a49ff2aa7fcb13' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261007110000 expects (md5 %)', v_sig, md5(v_src);
  end if;

  drop function erp.data_quality_report(text);

  execute $def$
create function erp.data_quality_report(p_object_type text)
returns table(object_id uuid, code text, name text, score integer, errors integer, warnings integer,
              failing text)
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_table  text;
begin
  select distinct m.table_name into v_table
    from erp_ref.maintainable_field m where m.object_type = p_object_type;

  if v_table is null then
    raise exception 'CLOVEERP_UNKNOWN_OBJECT_TYPE: % is not maintainable', p_object_type
      using errcode = '23503';
  end if;

  -- Each record's rules are evaluated once, and the ones it fails are named by
  -- their messages, errors first (20261007110000, J-112).
  return query execute format($q$
    select t.id, t.code, t.name,
           erp.data_quality_score(%L, t.id),
           f.errors, f.warnings, f.failing
      from erp.%I t
      cross join lateral (
        select (count(*) filter (where s.severity = 'error'))::integer as errors,
               (count(*) filter (where s.severity = 'warning'))::integer as warnings,
               string_agg(s.message, ' '
                          order by case s.severity when 'error' then 0 when 'warning' then 1 else 2 end,
                                   s.code) as failing
          from erp.score_master_record(%L, t.id) s
         where not s.satisfied) f
     where t.tenant_id = $1 and t.status <> 'archived'
     order by 4, t.code
  $q$, p_object_type, v_table, p_object_type) using v_tenant;
end;
$fn$
$def$;
end
$report$;

comment on function erp.data_quality_report(text) is
  'Data quality as a worklist, worst first: each record of the type in the caller''s organisation with its score, '
  'its count of failed errors and warnings, and the messages of the rules it fails, errors first (20261007110000, '
  'J-112). Reads the maintainable-field register the product role cannot read, and answers only the caller''s rows.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.data_quality_names_its_rules_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 4;
  v_cases   integer := 0;
  v_tag     text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1        uuid := gen_random_uuid();
  v_owner   text := current_user;
  v_step    text := 'provisioning';
  v_state   text;
  rb        record;
  cs        uuid;
  v_bare    uuid; v_half uuid; v_whole uuid;
  v_country text; v_tax text;
  q         record;
  v_read    jsonb;
  v_signed  jsonb;
begin
  begin
    -- ── The fixture ───────────────────────────────────────────────────────────
    v_step := 'an organisation with the data quality rules in force';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzdqn-' || v_tag, 'Data Quality Names Suite',
      'admin@zzdqn-' || v_tag || '.test', 'Named Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzdqn-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    cs := erp.configure_master_data();
    -- An organisation not yet live has it in force at once; otherwise its
    -- administrator approves it.
    if (select c.status::text from erp.change_set c where c.id = cs) <> 'promoted' then
      perform erp.approve_change_set(cs);
    end if;
    if (select c.status::text from erp.change_set c where c.id = cs) <> 'promoted' then
      perform erp.promote_change_set(cs);
    end if;

    select q2.message into v_country from erp.data_quality_rule q2
     where q2.tenant_id = rb.tenant_id and q2.object_type = 'party' and q2.code = 'has_country';
    select q2.message into v_tax from erp.data_quality_rule q2
     where q2.tenant_id = rb.tenant_id and q2.object_type = 'party' and q2.code = 'has_tax_id';

    v_step := 'three business partners';
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZDQBARE', 'No country, no tax number', 'active') returning id into v_bare;
    insert into erp.party (tenant_id, code, name, country_code, status)
    values (rb.tenant_id, 'ZDQHALF', 'A country, no tax number', 'GB', 'active') returning id into v_half;
    insert into erp.party (tenant_id, code, name, country_code, tax_identifier, status)
    values (rb.tenant_id, 'ZDQWHOLE', 'Both', 'GB', 'GB123456789', 'active') returning id into v_whole;

    -- ── 1. A record failing two rules names both, the error first ────────────
    v_step := 'reading the record that fails both';
    select * into q from erp.data_quality_report('party') r where r.object_id = v_bare;
    v_cases := v_cases + 1;
    case_name := 'a record failing an error and a warning names both rules by their messages, the error first';
    passed := v_country is not null and v_tax is not null
          and q.errors = 1 and q.warnings = 1
          and q.failing = v_country || ' ' || v_tax;
    detail := coalesce(v_state, format('errors %s, warnings %s, failing: %s', q.errors, q.warnings, q.failing));
    return next;

    -- ── 2. A warning alone is named alone ────────────────────────────────────
    v_step := 'reading the record that fails a warning';
    select * into q from erp.data_quality_report('party') r where r.object_id = v_half;
    v_cases := v_cases + 1;
    case_name := 'a record failing only a warning names that rule and no other';
    passed := q.errors = 0 and q.warnings = 1 and q.failing = v_tax;
    detail := coalesce(v_state, format('errors %s, warnings %s, failing: %s', q.errors, q.warnings, q.failing));
    return next;

    -- ── 3. A complete record names nothing, and every score is the score ─────
    v_step := 'reading the complete record and the scores';
    select * into q from erp.data_quality_report('party') r where r.object_id = v_whole;
    v_cases := v_cases + 1;
    case_name := 'a record that satisfies every rule names nothing, and each score is still data_quality_score''s';
    passed := q.errors = 0 and q.warnings = 0 and q.failing is null and q.score = 100
          and not exists (select 1 from erp.data_quality_report('party') r
                           where r.score is distinct from erp.data_quality_score('party', r.object_id))
          and (select count(*) from erp.data_quality_report('party')) = (select count(*) from erp.party p where p.tenant_id = rb.tenant_id and p.status <> 'archived');
    detail := coalesce(v_state, format('errors %s, warnings %s, failing %s, score %s', q.errors, q.warnings,
                coalesce(q.failing, 'none'), q.score));
    return next;

    -- ── 4. The door answers it, signed in alike ──────────────────────────────
    v_step := 'reading the door';
    v_read := public.erp_data_quality('party');
    set local role authenticated;
    v_signed := public.erp_data_quality('party');
    execute format('set local role %I', v_owner);
    v_cases := v_cases + 1;
    case_name := 'the data quality door answers the failing rules for each record, read alike signed in';
    passed := jsonb_array_length(v_read) = (select count(*) from erp.party p where p.tenant_id = rb.tenant_id and p.status <> 'archived')
          and exists (select 1 from jsonb_array_elements(v_read) x
                       where x ->> 'code' = 'ZDQBARE' and x ->> 'failing' = v_country || ' ' || v_tax)
          and exists (select 1 from jsonb_array_elements(v_read) x
                       where x ->> 'code' = 'ZDQWHOLE' and x -> 'failing' = 'null'::jsonb)
          and v_signed = v_read;
    detail := coalesce(v_state, format('%s row(s): %s; signed in alike %s', jsonb_array_length(v_read),
                (select string_agg(format('%s %s', x ->> 'code', coalesce(x ->> 'failing', 'none')), '; ')
                   from jsonb_array_elements(v_read) x), v_signed = v_read));
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
    raise exception 'CLOVEERP_DATA_QUALITY_NAMES_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the fixture stopped; a case that cannot run is a case that fails.';
  end if;
  if exists (select 1 from erp.tenant t where t.code = 'zzdqn-' || v_tag)
     or exists (select 1 from auth.users u where u.id = a1) then
    raise exception 'CLOVEERP_DATA_QUALITY_NAMES_SUITE_LEAKED: the fixture was not undone'
      using hint = 'The suite must raise CLOVEERP_SUITE_UNDO inside its block so everything it made rolls back.';
  end if;
end;
$$;

revoke all on function erp_test.data_quality_names_its_rules_suite() from public, anon;

comment on function erp_test.data_quality_names_its_rules_suite() is
  'Data quality names its rules (20261007110000, J-112): a record failing an error and a warning names both by '
  'their messages, the error first; a warning alone is named alone; a complete record names nothing and every '
  'score is unchanged; the door answers it, signed in too.';

create or replace function erp_test.assert_data_quality_names_its_rules_suite()
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
    from erp_test.data_quality_names_its_rules_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_DATA_QUALITY_NAMES_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'The data quality report would count a failure without naming the rule. Read the case that failed.';
  end if;
  if v_total <> 4 then
    raise exception 'CLOVEERP_DATA_QUALITY_NAMES_SUITE_SHRANK: % case(s), expected 4', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('data quality names its rules: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_data_quality_names_its_rules_suite() from public, anon;

comment on function erp_test.assert_data_quality_names_its_rules_suite() is
  'The data quality report names the rules each record fails, not only how many (20261007110000).';

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
