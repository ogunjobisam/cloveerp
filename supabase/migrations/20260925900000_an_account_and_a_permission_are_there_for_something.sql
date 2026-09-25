set lock_timeout = '30s';

-- =============================================================================
-- 20260925900000  An account and a permission are there for something
-- -----------------------------------------------------------------------------
-- PR9, the dead configuration gate: node W5 of
-- docs/spec/simplification-review.md widens erp.assert_no_dead_configuration()
-- to the register. 20260925700000 took the reasons and 20260925800000 the
-- shipped lifecycles; this takes the accounts and the permissions. Checked
-- against the built database before it was built.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
--   * Three account purposes of the chart are named by no posting rule,
--     installer or function that reaches them: operating expenses and
--     freight variance, which a person posts to by journal (the 7000 band is
--     where operating expenses are analysed, and landed cost is outside the
--     product's scope, §11), and retained earnings, which the balance sheet
--     reads as equity and no year-end close yet posts to. Nothing said so,
--     and nothing would have noticed a purpose nothing reached at all.
--   * A permission a door or a shipped lifecycle move requires has to be one the catalogue offers, or no role
--     can ever be granted it and whatever it guards can never be done.
--     Nothing checked that.
--
-- ── WHAT CHANGES ─────────────────────────────────────────────────────────────
--
--   * erp_ref.chart_account_purpose.reached_by says, where nothing in the
--     product names a purpose, what does reach it.
--   * The dead configuration report names a purpose nothing names and
--     nothing says reaches, and a permission something requires that the
--     catalogue does not offer. Both read the product's own definitions, not
--     an organisation's, so no organisation's choices can fail a deploy.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. What reaches an account purpose nothing in the product names
-- ─────────────────────────────────────────────────────────────────────────────

alter table erp_ref.chart_account_purpose add column if not exists reached_by text;

comment on column erp_ref.chart_account_purpose.reached_by is
  'Where no posting rule, installer or function names the purpose: what reaches it, in words '
  '(20260925900000). Null where the product names it.';

do $reach$
declare
  v_n integer;
begin
  update erp_ref.chart_account_purpose
     set reached_by = 'A journal a person posts: the 7000 band is where an operating expense is analysed by dimension.'
   where purpose = 'operating_expenses';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: operating_expenses changed % row(s), expected 1', v_n;
  end if;
  update erp_ref.chart_account_purpose
     set reached_by = 'The balance sheet, which reads it as equity; the year-end close that would post to it is not built, and until it is a person posts to it by journal.'
   where purpose = 'retained_earnings';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: retained_earnings changed % row(s), expected 1', v_n;
  end if;
  update erp_ref.chart_account_purpose
     set reached_by = 'A journal a person posts: landed cost is outside the product''s scope (§11), so a freight variance is posted by hand.'
   where purpose = 'freight_variance';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: freight_variance changed % row(s), expected 1', v_n;
  end if;
end
$reach$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. The dead configuration report sees them
-- ─────────────────────────────────────────────────────────────────────────────

do $report$
declare
  v_sig constant text := 'erp.dead_configuration_report()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  -- A lifecycle the product ships, in a pack or the newest version of a module$o$;
  v_new constant text := $n$  -- An account purpose nothing reaches (20260925900000): no function, module
  -- upgrade or pack names it, the close does not ask about it, and nothing
  -- says what does reach it.
  select 'an account purpose nothing reaches',
         cp.purpose,
         format('%s (%s): no posting rule, installer or function names it; say in reached_by what reaches it, or retire it',
                cp.name, cp.default_code)
    from erp_ref.chart_account_purpose cp
   where cp.reached_by is null
     and not cp.reconciliation_required and not cp.close_blocking
     -- An assertion names a purpose to check it, not to reach it.
     and not exists (select 1 from pg_catalog.pg_proc p
                       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                      where n.nspname in ('erp', 'public') and p.proname not like 'assert\_%'
                        and strpos(p.prosrc, '''' || cp.purpose || '''') > 0)
     and not exists (select 1 from erp_ref.module_upgrade_account a where a.purpose = cp.purpose)
     -- Where a module's posting rules name it, as erp.resolve_account_purposes()
     -- reads them (found on review: the rules were not read at all).
     and not exists (select 1 from erp_ref.module_upgrade_item ui
                      cross join lateral jsonb_array_elements(coalesce(ui.payload -> 'posting_lines', '[]'::jsonb)) l
                     where ui.object_kind = 'posting_rule' and l -> 'account' ->> 'purpose' = cp.purpose)
  union all
  -- A permission the product requires and the catalogue does not offer
  -- (20260925900000): nobody can be granted it, so what it guards can never
  -- be done.
  select 'a permission is required that the catalogue does not offer',
         r.code,
         format('%s requires %s, and erp_ref.permission has no such permission to grant', r.required_by, r.code)
    from (select m[1] as code, format('%s.%s()', n.nspname, p.proname) as required_by
            from pg_catalog.pg_proc p
            join pg_catalog.pg_namespace n on n.oid = p.pronamespace
            cross join lateral regexp_matches(p.prosrc,
                   '(?:authorise|has_permission)\(\s*''([a-z_]+\.[a-z_]+)''', 'g') m
           where n.nspname in ('erp', 'public')
          union
          select t ->> 'required_permission', format('upgrade %s lifecycle %s', ui.install_code, ui.object_key)
            from erp_ref.module_upgrade_item ui
            cross join lateral jsonb_array_elements(ui.payload -> 'transitions') t
           where ui.object_kind = 'state_machine' and t ->> 'required_permission' is not null
          union
          select t ->> 'required_permission', format('pack %s lifecycle %s', pi.pack_code, pi.object_key)
            from erp_ref.pack_item pi
            cross join lateral jsonb_array_elements(pi.payload -> 'transitions') t
           where pi.object_kind = 'state_machine' and t ->> 'required_permission' is not null
          -- A document type's and a governed view's permission are held to the
          -- catalogue by a foreign key already.
          ) r
   where not exists (select 1 from erp_ref.permission pm where pm.code = r.code)
  union all
  -- A lifecycle the product ships, in a pack or the newest version of a module$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$report$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B1. The proof: erp_test.dead_register_suite
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.dead_register_suite()
 returns table(case_name text, passed boolean, detail text)
 language plpgsql
 set search_path to ''
as $function$
declare
  v_found text;
begin
  -- 1. Here, every account purpose is reached and every permission required
  --    is one the catalogue offers.
  select string_agg(d.reference, ', ' order by d.reference) into v_found
    from erp.dead_configuration_report() d
   where d.finding in ('an account purpose nothing reaches',
                       'a permission is required that the catalogue does not offer');
  return query select 'every account purpose is reached by something, and every permission required is one a role can be granted',
    v_found is null, coalesce(v_found, 'none');

  -- 2. The purposes nothing in the product names say what reaches them.
  return query select 'operating expenses, freight variance and retained earnings say what reaches them',
    (select count(*) from erp_ref.chart_account_purpose cp
      where cp.purpose in ('operating_expenses', 'freight_variance', 'retained_earnings')
        and cp.reached_by is not null) = 3,
    (select string_agg(cp.purpose || ': ' || coalesce(left(cp.reached_by, 40), 'nothing'), '; ' order by cp.purpose)
       from erp_ref.chart_account_purpose cp
      where cp.purpose in ('operating_expenses', 'freight_variance', 'retained_earnings'));

  -- 3. A purpose nothing names and nothing says reaches is named.
  begin
    insert into erp_ref.chart_account_purpose
      (purpose, name, account_type, control_kind, default_code, statutory_code,
       reconciliation_required, close_blocking, installer_creates, note, seq, reached_by)
    select 'zz_planted_purpose', 'Planted purpose', cp.account_type, cp.control_kind, '9999', cp.statutory_code,
           false, false, false, 'A purpose the suite plants and rolls back.', 99999, null
      from erp_ref.chart_account_purpose cp where cp.purpose = 'freight_variance';
    select string_agg(d.reference, ', ') into v_found
      from erp.dead_configuration_report() d
     where d.finding = 'an account purpose nothing reaches';
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_found := left(sqlerrm, 200); end if;
  end;
  return query select 'an account purpose nothing names, and nothing says reaches, is named by the dead configuration report',
    v_found = 'zz_planted_purpose', coalesce(v_found, 'nothing named');

  -- 4. A permission a shipped module move, or a door, requires and nobody can
  --    be granted is named.
  begin
    insert into erp_ref.module_upgrade_item (install_code, to_version, object_kind, object_key, payload, seq)
    select ui.install_code, ui.to_version, 'state_machine', 'zz_planted_permission',
           jsonb_build_object('code', 'zz_planted_permission', 'object_type', 'document', 'name', 'Planted',
             'states', jsonb_build_array(
               jsonb_build_object('code', 'a', 'is_initial', true),
               jsonb_build_object('code', 'z', 'is_terminal', true)),
             'transitions', jsonb_build_array(
               jsonb_build_object('code', 'go', 'from', 'a', 'to', 'z',
                                  'required_permission', 'zz_nobody.grants_this'))), 99999
      from erp_ref.module_upgrade_item ui where ui.object_kind = 'state_machine' limit 1;
    execute $planted$
      create function erp.zz_planted_door() returns void language plpgsql set search_path = '' as $body$
      begin
        perform erp.authorise('zz_nobody.opens_this', null, null, null, 'zz', null);
      end;
      $body$
    $planted$;
    select string_agg(d.reference, ', ' order by d.reference) into v_found
      from erp.dead_configuration_report() d
     where d.finding = 'a permission is required that the catalogue does not offer';
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_found := left(sqlerrm, 200); end if;
  end;
  return query select 'a permission a shipped move or a door requires, and the catalogue does not offer, is named by the dead configuration report',
    v_found = 'zz_nobody.grants_this, zz_nobody.opens_this', coalesce(v_found, 'nothing named');

  -- 5. Nothing is left behind.
  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp_ref.chart_account_purpose cp where cp.purpose = 'zz_planted_purpose')
    and not exists (select 1 from erp_ref.module_upgrade_item ui where ui.object_key = 'zz_planted_permission')
    and to_regprocedure('erp.zz_planted_door()') is null,
    'the planted purpose, lifecycle and door rolled back';
end;
$function$;

revoke all on function erp_test.dead_register_suite() from public, anon;

create or replace function erp_test.assert_dead_register_suite()
returns void
language plpgsql
security definer
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
    from erp_test.dead_register_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_DEAD_REGISTER_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'An account purpose nothing reaches, a permission nobody can be granted, or a report that no longer sees one, is the case that failed. Read it.';
  end if;
  if v_total <> 5 then
    raise exception 'CLOVEERP_DEAD_REGISTER_SUITE_SHRANK: % case(s), expected 5', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
end;
$$;

revoke all on function erp_test.assert_dead_register_suite() from public, anon;

comment on function erp_test.assert_dead_register_suite() is
  'Every account purpose is reached by something and every permission required is one a role can '
  'be granted, and the dead configuration report names either when one is planted (20260925900000).';

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
-- Every move every lifecycle declares still has something that fires it, in
-- whatever database this runs against, before it commits.
select erp.assert_every_transition_is_driven();
