set lock_timeout = '30s';

-- =============================================================================
-- 20261001600000  Every cycle keeps to fifteen parameters
-- -----------------------------------------------------------------------------
-- docs/spec/simplification-review.md §10: "No cycle exceeds fifteen parameters,
-- and every default produces the clean path." The doctrine's rule 7
-- (docs/spec/flow-doctrine.md) says the same. Until now nothing held either
-- half: a setting could be added to any cycle, with any default, and the build
-- would not say so.
--
-- ── HOW A PARAMETER IS COUNTED ───────────────────────────────────────────────
--
-- A setting is a row of erp_ref.config_type. Its parameters are the keys of
-- its value (the properties its value_schema declares), or one where its value
-- is a single value: procurement.policy is three parameters, the production
-- issue method one.
--
-- Each setting belongs to one cycle: the cycle whose configuration it is,
-- where a customer sets it (cycle_code, a flow of erp_meta.flow_budget). The
-- three approval settings govern every cycle's approvals alike and belong to
-- none of them; they are 'shared', held to fifteen on their own. Counted so,
-- the most any cycle holds today is eleven (o2c and stock).
--
-- Counted the other way, each setting in every cycle it touches, order to cash
-- would hold 25: its own 11, the shared five, and stock's allocation,
-- reservation ageing and shelf life. That reading is not the one taken here,
-- because a customer configures stock policy with stock; it is named so it is
-- not assumed away.
--
-- ── WHAT THIS DOES ───────────────────────────────────────────────────────────
--
--   * erp_ref.config_type gains cycle_code, the cycle a setting belongs to, and
--     clean_path, what its default does and why that is the clean path. Both
--     are set here for all seventeen settings.
--   * erp.parameter_budget_report(): one row per cycle and 'shared', with its
--     parameters and its settings.
--   * erp.assert_parameter_budget(): refuses a cycle over fifteen, a setting
--     with no cycle or with one that is not a declared flow, and a setting
--     whose default says nothing of the clean path. A setting added tomorrow
--     without both is a build that fails, which is the point.
--
-- Proof: erp_test.parameter_budget_suite (6 cases).
-- =============================================================================

alter table erp_ref.config_type add column if not exists cycle_code text;
alter table erp_ref.config_type add column if not exists clean_path text;

comment on column erp_ref.config_type.cycle_code is
  'The cycle this setting is configured with: a flow_code of erp_meta.flow_budget, or ''shared'' for a '
  'setting that governs every cycle alike. Held to fifteen parameters per cycle by '
  'erp.assert_parameter_budget() (20261001600000).';
comment on column erp_ref.config_type.clean_path is
  'What the default does, and why it is the clean path: the doctrine''s rule 7, that every parameter ships '
  'with a default that produces the clean path (20261001600000).';

do $declare$
declare
  v_n integer;
begin
  update erp_ref.config_type ct
     set cycle_code = v.cycle_code, clean_path = v.clean_path
    from (values
      ('approval.administrator_override', 'shared',
       'Allowed: an administrator can always decide, so an approval nobody else may give never strands a document.'),
      ('approval.reapproval_tolerance', 'shared',
       'A child inside ten per cent and £500 of what was approved inherits the approval; only a real change asks again.'),
      ('approval.self_approval', 'shared',
       'Allowed: a small team approves its own work without inventing a second person to press a button.'),
      ('commercial.price_book', 'o2c',
       'None: the item''s own price is the price, so a quote or order needs nothing set up to be priced.'),
      ('finance.settlement_tolerance', 'money',
       'Nought: cash settles what it pays to the penny and nothing is written off unasked; an installer may widen it.'),
      ('tax.vat_return', 'vat',
       'Quarterly on the calendar quarters, standard scheme, Great Britain: the return most registered companies make.'),
      ('inventory.count_posting', 'stock',
       'A count inside its tolerance posts as it is recorded, and its counter may post it: no second press.'),
      ('stock.allocation_policy', 'stock',
       'First in, first out, and first expiring first where stock expires: the system picks, nobody chooses a batch.'),
      ('stock.reservation_ageing', 'stock',
       'Reservations left unpicked release themselves after a day, or three in marshalling, so stock is never held by nobody.'),
      ('stock.shelf_life_minimum', 'stock',
       'Stock with most of its life left moves: three quarters to receive, a half to transfer, a third to despatch.'),
      ('procurement.policy', 'p2p',
       'Three-way match with no short close: a bill that matches its order and receipt posts, and nothing closes early.'),
      ('production.issue_method', 'make',
       'Backflush: materials are issued as output is booked, so nobody records an issue by hand.'),
      ('production.policy', 'make',
       'Complete to the quantity ordered, release with no shortage, and scrap written off: the order runs as planned.'),
      ('quality.quarantine_defaults', 'quality',
       'Raw materials and finished goods quarantine on receipt and are aged, so nothing unchecked is used or sold.'),
      ('sales.backorder_policy', 'o2c',
       'Permitted: what cannot be sent today follows when it can, without the order being raised again.'),
      ('sales.credit_control', 'o2c',
       'Credit checked as the order is taken, within five per cent, and held at the limit: approved once, at the start.'),
      ('sales.policy', 'o2c',
       'Ship what was ordered and close nothing short: the order completes as it was agreed.')
    ) as v(code, cycle_code, clean_path)
   where ct.code = v.code;
  get diagnostics v_n = row_count;
  if v_n <> 17 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % of the seventeen settings found', v_n;
  end if;
end
$declare$;

-- ─────────────────────────────────────────────────────────────────────────────
-- The report and the assertion
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.config_type_parameters(p_value_schema jsonb)
returns integer
language sql
immutable
set search_path = ''
as $$
  -- A setting's parameters: the keys its value declares, or one (20261001600000).
  select case when jsonb_typeof(p_value_schema -> 'properties') = 'object'
              then (select count(*)::integer from jsonb_object_keys(p_value_schema -> 'properties'))
              else 1 end
$$;

revoke all on function erp.config_type_parameters(jsonb) from public, anon;

comment on function erp.config_type_parameters(jsonb) is
  'The parameters a setting holds: the keys its value_schema declares, or one for a single value (20261001600000).';

create or replace function erp.parameter_budget_report()
returns table(cycle_code text, parameters integer, budget integer, settings text)
language sql
stable
set search_path = ''
as $$
  -- One row per cycle and for the shared settings, with the parameters it
  -- holds against its fifteen (20261001600000). A cycle with no setting reads
  -- nought; a setting with no cycle reads under a null cycle.
  with c as (
    select b.flow_code as cycle_code from erp_meta.flow_budget b
    union select 'shared'
    union select ct.cycle_code from erp_ref.config_type ct
  )
  select c.cycle_code,
         coalesce(sum(erp.config_type_parameters(ct.value_schema)) filter (where ct.code is not null), 0)::integer,
         15,
         string_agg(ct.code || ' (' || erp.config_type_parameters(ct.value_schema) || ')', ', ' order by ct.code)
    from c
    left join erp_ref.config_type ct on ct.cycle_code is not distinct from c.cycle_code
   group by c.cycle_code
   order by c.cycle_code nulls first
$$;

revoke all on function erp.parameter_budget_report() from public, anon;

comment on function erp.parameter_budget_report() is
  'Parameters per cycle, and for the shared settings, against the doctrine''s fifteen (20261001600000).';

create or replace function erp.assert_parameter_budget()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_findings text;
  v_n        integer;
  v_most     text;
begin
  -- §10, and the doctrine's rule 7 (20261001600000).
  select count(*), string_agg(f.finding, E'\n  ' order by f.finding)
    into v_n, v_findings
    from (
      select format('%s holds %s parameters, more than its %s: %s', r.cycle_code, r.parameters, r.budget, r.settings) as finding
        from erp.parameter_budget_report() r
       where r.cycle_code is not null and r.parameters > r.budget
      union all
      select format('%s belongs to no cycle', ct.code)
        from erp_ref.config_type ct where ct.cycle_code is null
      union all
      select format('%s belongs to %s, which is not a declared cycle', ct.code, ct.cycle_code)
        from erp_ref.config_type ct
       where ct.cycle_code is not null and ct.cycle_code <> 'shared'
         and not exists (select 1 from erp_meta.flow_budget b where b.flow_code = ct.cycle_code)
      union all
      select format('%s does not say how its default is the clean path', ct.code)
        from erp_ref.config_type ct where coalesce(btrim(ct.clean_path), '') = ''
    ) f;
  if v_n > 0 then
    raise exception E'CLOVEERP_PARAMETER_BUDGET_BROKEN: % finding(s)\n  %', v_n, v_findings
      using errcode = '23514',
            hint = 'Give every setting its cycle and say how its default is the clean path, on erp_ref.config_type. A cycle over fifteen parameters takes one out before it adds one: a customer should configure a cycle in an afternoon.';
  end if;
  select string_agg(r.cycle_code || ' ' || r.parameters, ', ' order by r.parameters desc, r.cycle_code)
    into v_most from erp.parameter_budget_report() r where r.cycle_code is not null;
  return format('parameter budget: every cycle within fifteen (%s), every default the clean path', v_most);
end;
$$;

revoke all on function erp.assert_parameter_budget() from public, anon;

comment on function erp.assert_parameter_budget() is
  'No cycle holds more than fifteen parameters, every setting belongs to a declared cycle or is shared, '
  'and every default says how it is the clean path (§10, 20261001600000).';

-- CLOVEERP_PARAMETER_BUDGET_BROKEN is raised only by an assert_ routine and so
-- is not registered in erp_ref.refusal, as 20260920200000 explains; its next
-- action travels as the hint.

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('parameter_budget', 'Every cycle keeps to fifteen parameters', 'assertion', 'platform', 'erp',
   'assert_parameter_budget', '', 'parameter_budget_report', '',
   'The doctrine''s rule 7 and §10 of the simplification plan: no cycle holds more than fifteen parameters, '
   'every setting belongs to a declared cycle or is shared, and every default says how it is the clean path.',
   true, 103)
on conflict (code) do update set
  title = excluded.title, kind = excluded.kind, scope = excluded.scope,
  schema_name = excluded.schema_name, function_name = excluded.function_name,
  arguments = excluded.arguments, detail_function = excluded.detail_function,
  detail_arguments = excluded.detail_arguments, blurb = excluded.blurb,
  runs_in_ci = excluded.runs_in_ci, seq = excluded.seq;

-- ─────────────────────────────────────────────────────────────────────────────
-- The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.parameter_budget_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 6;
  v_cases integer := 0;
  v_state text;
  v_step  text := 'reading the register';
  v_ok    text;
  v_err   text;
  v_max   integer;
begin
  begin
    -- ── 1. Today ─────────────────────────────────────────────────────────────
    v_ok := erp.assert_parameter_budget();
    select max(r.parameters) into v_max from erp.parameter_budget_report() r where r.cycle_code is not null;
    v_cases := v_cases + 1;
    case_name := 'every setting belongs to a cycle and says how its default is the clean path, and no cycle holds more than fifteen parameters';
    passed := v_ok like 'parameter budget: every cycle within fifteen%'
          and not exists (select 1 from erp_ref.config_type ct
                           where ct.cycle_code is null or coalesce(btrim(ct.clean_path), '') = '')
          and v_max <= 15
          and (select r.parameters from erp.parameter_budget_report() r where r.cycle_code = 'p2p') = 3;
    detail := v_ok;
    return next;

    -- ── 2. A sixteenth parameter ─────────────────────────────────────────────
    v_step := 'a setting that takes a cycle past fifteen';
    v_err := null;
    begin
      insert into erp_ref.config_type (code, domain, module_code, name_key, description, value_schema,
                                       max_scope_level, is_singleton, default_value, consequence,
                                       cycle_code, clean_path)
      select 'zz.too_many', 'policy', 'sales', 'config.zz.too_many', 'suite',
             jsonb_build_object('type', 'object', 'properties',
               (select jsonb_object_agg('k' || g, jsonb_build_object('type', 'integer')) from generate_series(1, 5) g)),
             'tenant', true, '{}'::jsonb, 'suite', 'o2c', 'suite';
      perform erp.assert_parameter_budget();
      v_err := 'passed';
      raise exception 'CLOVEERP_CASE_UNDO';
    exception when others then
      if sqlerrm <> 'CLOVEERP_CASE_UNDO' then v_err := left(sqlerrm, 200); end if;
    end;
    v_cases := v_cases + 1;
    case_name := 'a setting that takes a cycle past fifteen parameters is refused by name';
    passed := v_err like 'CLOVEERP_PARAMETER_BUDGET_BROKEN:%o2c holds 16 parameters%';
    detail := v_err;
    return next;

    -- ── 3. No cycle ──────────────────────────────────────────────────────────
    v_step := 'a setting that belongs to no cycle';
    v_err := null;
    begin
      insert into erp_ref.config_type (code, domain, module_code, name_key, description, value_schema,
                                       max_scope_level, is_singleton, default_value, consequence, clean_path)
      values ('zz.no_cycle', 'policy', 'sales', 'config.zz.no_cycle', 'suite', '{"type":"boolean"}'::jsonb,
              'tenant', true, 'true'::jsonb, 'suite', 'suite');
      perform erp.assert_parameter_budget();
      v_err := 'passed';
      raise exception 'CLOVEERP_CASE_UNDO';
    exception when others then
      if sqlerrm <> 'CLOVEERP_CASE_UNDO' then v_err := left(sqlerrm, 200); end if;
    end;
    v_cases := v_cases + 1;
    case_name := 'a setting added with no cycle is refused by name';
    passed := v_err like 'CLOVEERP_PARAMETER_BUDGET_BROKEN:%zz.no_cycle belongs to no cycle%';
    detail := v_err;
    return next;

    -- ── 4. A cycle that is not one ───────────────────────────────────────────
    v_step := 'a setting that names a cycle nobody declared';
    v_err := null;
    begin
      insert into erp_ref.config_type (code, domain, module_code, name_key, description, value_schema,
                                       max_scope_level, is_singleton, default_value, consequence,
                                       cycle_code, clean_path)
      values ('zz.nowhere', 'policy', 'sales', 'config.zz.nowhere', 'suite', '{"type":"boolean"}'::jsonb,
              'tenant', true, 'true'::jsonb, 'suite', 'nowhere', 'suite');
      perform erp.assert_parameter_budget();
      v_err := 'passed';
      raise exception 'CLOVEERP_CASE_UNDO';
    exception when others then
      if sqlerrm <> 'CLOVEERP_CASE_UNDO' then v_err := left(sqlerrm, 200); end if;
    end;
    v_cases := v_cases + 1;
    case_name := 'a setting that names a cycle nobody declared is refused by name';
    passed := v_err like 'CLOVEERP_PARAMETER_BUDGET_BROKEN:%zz.nowhere belongs to nowhere, which is not a declared cycle%';
    detail := v_err;
    return next;

    -- ── 5. No clean path ─────────────────────────────────────────────────────
    v_step := 'a setting that says nothing of its default';
    v_err := null;
    begin
      insert into erp_ref.config_type (code, domain, module_code, name_key, description, value_schema,
                                       max_scope_level, is_singleton, default_value, consequence, cycle_code)
      values ('zz.silent', 'policy', 'sales', 'config.zz.silent', 'suite', '{"type":"boolean"}'::jsonb,
              'tenant', true, 'true'::jsonb, 'suite', 'o2c');
      perform erp.assert_parameter_budget();
      v_err := 'passed';
      raise exception 'CLOVEERP_CASE_UNDO';
    exception when others then
      if sqlerrm <> 'CLOVEERP_CASE_UNDO' then v_err := left(sqlerrm, 200); end if;
    end;
    v_cases := v_cases + 1;
    case_name := 'a setting whose default says nothing of the clean path is refused by name';
    passed := v_err like 'CLOVEERP_PARAMETER_BUDGET_BROKEN:%zz.silent does not say how its default is the clean path%';
    detail := v_err;
    return next;
  exception when others then
    v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
  end;

  -- ── 6. Nothing left ─────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the suite ran to its end and left no setting behind';
  passed := v_state is null and not exists (select 1 from erp_ref.config_type ct where ct.code like 'zz.%');
  detail := coalesce(v_state, 'nothing of the suite is left in the register');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_PARAMETER_BUDGET_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.parameter_budget_suite() from public, anon;

comment on function erp_test.parameter_budget_suite() is
  'The parameter budget holds today, and a sixteenth parameter, a setting with no cycle or an undeclared one, '
  'and a default that says nothing of the clean path are each refused (20261001600000).';

create or replace function erp_test.assert_parameter_budget_suite()
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
    from erp_test.parameter_budget_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_PARAMETER_BUDGET_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A cycle could take a sixteenth parameter, or a setting a default nobody justified. Read the case that failed.';
  end if;
  if v_total <> 6 then
    raise exception 'CLOVEERP_PARAMETER_BUDGET_SUITE_SHRANK: % case(s), expected 6', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('parameter budget: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_parameter_budget_suite() from public, anon;

comment on function erp_test.assert_parameter_budget_suite() is
  'No cycle takes a sixteenth parameter, and no setting a default nobody justified (20261001600000).';

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
select erp.assert_every_transition_is_driven();
select erp.assert_parameter_budget();
