set lock_timeout = '30s';

-- =============================================================================
-- 20261007122000  A record failing every rule scores nought
-- -----------------------------------------------------------------------------
-- Found building the data quality report's rule names (J-174, while making
-- 20261007110000). erp.data_quality_score weighs the rules a record satisfies
-- against all the rules that apply: round(100.0 * sum(weight) filter (where
-- satisfied) / sum(weight)). For a record that satisfies none of them the
-- filtered sum has no rows and is null, so the score was null, not 0. The
-- worst record of all showed no score, sorted after every other in the
-- worst-first report (it orders by the score, and null sorts last), and was
-- left out of the average.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.data_quality_score counts a record that satisfies no rule as 0.
--      Every other score is unchanged, and a record no rule applies to still
--      scores 100.
--   B. erp_test.data_quality_score_floor_suite.
--
-- On production: one routine is edited where it adds up. No table is altered
-- and no row is changed; the report and its door read the score as they did.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. Nothing satisfied is nought
-- ─────────────────────────────────────────────────────────────────────────────

do $score$
declare
  v_sig  constant text := 'erp.data_quality_score(text,uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$              else round(100.0 * sum(s.weight) filter (where s.satisfied)
                               / sum(s.weight))::integer end$o$;
  v_new  constant text := $n$              -- A record satisfying no rule has no satisfied weight to add up:
              -- that is 0, not null (20261007122000, J-174).
              else round(100.0 * coalesce(sum(s.weight) filter (where s.satisfied), 0)
                               / sum(s.weight))::integer end$n$;
begin
  if strpos(v_src, '20261007122000') > 0 then
    raise notice '% already scores nought for nothing satisfied; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '21b1164cfea90d195a8f7c8f07e0f9a5' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261007122000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$score$;

comment on function erp.data_quality_score(text, uuid) is
  'A record''s data quality: the weight of the active rules it satisfies as a percentage of all that apply, 100 '
  'where none applies, and 0 where it satisfies none (20261007122000, J-174).';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.data_quality_score_floor_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 3;
  v_cases   integer := 0;
  v_tag     text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1        uuid := gen_random_uuid();
  v_step    text := 'provisioning';
  v_state   text;
  rb        record;
  cs        uuid;
  v_bare    uuid; v_half uuid; v_whole uuid;
  v_first   uuid;
  v_rules   integer;
  v_bare_sc integer; v_half_sc integer; v_whole_sc integer;
begin
  begin
    -- ── The fixture ───────────────────────────────────────────────────────────
    v_step := 'an organisation with the data quality rules in force';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzdqf-' || v_tag, 'Data Quality Floor Suite',
      'admin@zzdqf-' || v_tag || '.test', 'Floor Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzdqf-' || v_tag || '.test');
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

    v_step := 'three business partners: one satisfying no rule, one some, one all';
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZDQFBARE', 'No country, no tax number', 'active') returning id into v_bare;
    insert into erp.party (tenant_id, code, name, country_code, status)
    values (rb.tenant_id, 'ZDQFHALF', 'A country, no tax number', 'GB', 'active') returning id into v_half;
    insert into erp.party (tenant_id, code, name, country_code, tax_identifier, status)
    values (rb.tenant_id, 'ZDQFWHOLE', 'Both', 'GB', 'GB123456789', 'active') returning id into v_whole;
    select count(*) into v_rules from erp.data_quality_rule q
     where q.tenant_id = rb.tenant_id and q.object_type = 'party' and q.status = 'active';

    -- ── 1. Nothing satisfied is nought ────────────────────────────────────────
    v_step := 'scoring the record that satisfies no rule';
    v_bare_sc := erp.data_quality_score('party', v_bare);
    v_cases := v_cases + 1;
    case_name := 'a record that satisfies none of the rules that apply scores 0, not nothing';
    passed := v_rules > 0
          and not exists (select 1 from erp.score_master_record('party', v_bare) s where s.satisfied)
          and v_bare_sc = 0;
    detail := coalesce(v_state, format('%s rule(s) apply; score %s', v_rules, coalesce(v_bare_sc::text, 'null')));
    return next;

    -- ── 2. The others are as they were ────────────────────────────────────────
    v_step := 'scoring the others';
    v_half_sc := erp.data_quality_score('party', v_half);
    v_whole_sc := erp.data_quality_score('party', v_whole);
    v_cases := v_cases + 1;
    case_name := 'a record satisfying some rules keeps its weighted score, and one satisfying all scores 100';
    passed := v_half_sc = (select round(100.0 * sum(s.weight) filter (where s.satisfied) / sum(s.weight))::integer
                             from erp.score_master_record('party', v_half) s)
          and v_half_sc between 1 and 99
          and v_whole_sc = 100;
    detail := coalesce(v_state, format('some %s, all %s', v_half_sc, v_whole_sc));
    return next;

    -- ── 3. Worst first means it first ─────────────────────────────────────────
    v_step := 'reading the report worst first';
    select r.object_id into v_first from erp.data_quality_report('party') r limit 1;
    v_cases := v_cases + 1;
    case_name := 'the worst-first report lists the record that satisfies no rule first, with a score of 0';
    passed := v_first = v_bare
          and (select r.score from erp.data_quality_report('party') r where r.object_id = v_bare) = 0;
    detail := coalesce(v_state, format('first is %s', coalesce((select p.code from erp.party p where p.id = v_first), 'nothing')));
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
    raise exception 'CLOVEERP_DATA_QUALITY_FLOOR_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the fixture stopped; a case that cannot run is a case that fails.';
  end if;
  if exists (select 1 from erp.tenant t where t.code = 'zzdqf-' || v_tag)
     or exists (select 1 from auth.users u where u.id = a1) then
    raise exception 'CLOVEERP_DATA_QUALITY_FLOOR_SUITE_LEAKED: the fixture was not undone'
      using hint = 'The suite must raise CLOVEERP_SUITE_UNDO inside its block so everything it made rolls back.';
  end if;
end;
$$;

revoke all on function erp_test.data_quality_score_floor_suite() from public, anon;

comment on function erp_test.data_quality_score_floor_suite() is
  'A record failing every rule scores nought (20261007122000, J-174): it scores 0, not null, and the worst-first '
  'report lists it first; a partial record keeps its weighted score and a complete one scores 100.';

create or replace function erp_test.assert_data_quality_score_floor_suite()
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
    from erp_test.data_quality_score_floor_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_DATA_QUALITY_FLOOR_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'The worst record would show no score and sort last. Read the case that failed.';
  end if;
  if v_total <> 3 then
    raise exception 'CLOVEERP_DATA_QUALITY_FLOOR_SUITE_SHRANK: % case(s), expected 3', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('data quality floor: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_data_quality_score_floor_suite() from public, anon;

comment on function erp_test.assert_data_quality_score_floor_suite() is
  'A record that satisfies no data quality rule scores 0 and comes first in the worst-first report (20261007122000).';

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
