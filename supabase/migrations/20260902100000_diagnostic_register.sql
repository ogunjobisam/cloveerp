-- =============================================================================
-- The superadmin console, part A — diagnostics driven by a register
--
-- erp.platform_assurance() runs nine assertions from an array written into its
-- own body (20260830024837_...sql:16-21). CI runs twenty-four. The nine are not
-- the important nine; they are the nine that existed when it was written.
--
-- That is the same shape as the hardcoded array in apply_live_config_guards()
-- that let nine Addendum B surfaces go unguarded for as long as they existed: a
-- list that is the only statement of what is checked, with nothing comparing it
-- to anything. It was fixed there by making a register generate the behaviour
-- and an assertion police the register. Same fix here.
--
-- AND THE SCREEN COULD SAY WHAT FAILED BUT NOT WHY.
--
-- Every one of those nine assertions raises with a detail message and is backed
-- by a report function that lists the actual findings — isolation_report,
-- gateway_integrity_report, public_api_report, and so on. Not one of those
-- reports has a public wrapper. So the assurance screen could tell you
-- isolation had failed and could not tell you which table. The register pairs
-- each check with the report that explains it, and a failure now returns the
-- findings rather than a sentence.
--
-- ON THE DYNAMIC DISPATCH
--
-- erp.run_diagnostic() executes a function named by a table column. That
-- deserves a second look, because this codebase already carries one instance of
-- that pattern as a known risk — execute format('select %s', blocking_check)
-- over a tenant-writable column. This one is different in the way that matters:
-- erp_meta.diagnostic_check is platform_internal. RLS is on with no policy and
-- a blanket revoke, so no tenant session can write it and no public door
-- exposes it. Only a migration puts a row there. The register IS the allow-list,
-- which is why there is one dispatcher rather than forty-six near-identical
-- wrappers that somebody would forget to extend.
-- =============================================================================

create table if not exists erp_meta.diagnostic_check (
  code             text primary key,
  title            text not null,
  kind             text not null check (kind in ('assertion', 'report')),
  -- platform: reads the catalogue or reference data and needs no tenant.
  -- tenant:   needs erp.require_tenant_id() and answers for one organisation.
  scope            text not null check (scope in ('platform', 'tenant')),
  schema_name      text not null default 'erp',
  function_name    text not null,
  -- Literal SQL argument text, e.g. '''en'''. Written by a migration, never by
  -- a caller — see the note above about why that is the whole safety argument.
  arguments        text not null default '',
  -- The report that explains a failure. Null where the assertion's own message
  -- is the whole story.
  detail_function  text,
  detail_arguments text not null default '',
  blurb            text not null,
  runs_in_ci       boolean not null default true,
  seq              integer not null default 100
);

comment on table erp_meta.diagnostic_check is
  'Every check the product can run against itself, and the report that explains '
  'each failure. Read by erp.platform_assurance() and erp.run_diagnostic(), and '
  'policed by erp.assert_diagnostics_registered() so a new assertion cannot go '
  'unrun in silence the way fifteen of them already had.';

create table if not exists erp_meta.diagnostic_exemption (
  schema_name text not null,
  function_name text not null,
  rationale   text not null,
  primary key (schema_name, function_name)
);

comment on table erp_meta.diagnostic_exemption is
  'Assertions that deliberately cannot be run from a screen, each with a reason. '
  'An assertion that takes arguments only its caller knows belongs here rather '
  'than in a register of things a person can press.';

select erp_meta.register_table('erp_meta', 'diagnostic_check', 'platform_internal',
  'Register of self-checks. Not tenant data.');
select erp_meta.register_table('erp_meta', 'diagnostic_exemption', 'platform_internal',
  'Assertions deliberately not runnable from a screen.');

-- ── The register ─────────────────────────────────────────────────────────────
--
-- Scope was measured, not guessed: each assertion was run with no tenant
-- context and classified by what came back. Three of them need one, which is
-- not something their names tell you.

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function,
   detail_arguments, blurb, runs_in_ci, seq) values

  -- The structural core: reads the catalogue, needs no data to be meaningful.
  ('isolation', 'Tenant isolation', 'assertion', 'platform',
   'assert_isolation', '', 'isolation_report', '',
   'Every tenant-scoped table has row security on and a policy behind it.', true, 10),
  ('audit_coverage', 'Audit coverage', 'assertion', 'platform',
   'assert_audit_coverage', '', 'audit_coverage_report', '',
   'Every table that should be audited carries the trigger, and every exemption is registered.', true, 11),
  ('attribution_coverage', 'Attribution coverage', 'assertion', 'platform',
   'assert_attribution_coverage', '', 'attribution_coverage_report', '',
   'Every row that should say who wrote it can.', true, 12),
  ('session_context_hygiene', 'Session context hygiene', 'assertion', 'platform',
   'assert_session_context_hygiene', '', 'session_context_hygiene_report', '',
   'Tenant context is transaction-local, so it cannot leak across a pooled connection.', true, 13),
  ('public_api_safe', 'Public API is gated', 'assertion', 'platform',
   'assert_public_api_safe', '', 'public_api_report', '',
   'Every public write door is allow-listed, names its gate, and reaches erp.authorise().', true, 14),
  ('governed_views', 'Governed views', 'assertion', 'platform',
   'assert_governed_views_are_safe', '', 'governed_view_safety_report', '',
   'No view hands out rows the querying principal could not read directly.', true, 15),
  ('intelligence_boundary', 'Intelligence boundary', 'assertion', 'platform',
   'assert_intelligence_boundary', '', 'intelligence_boundary_report', '',
   'Nothing on the transaction path can reach the AI layer, and every proposal was decided by a person.', true, 16),
  ('gateway_integrity', 'Integration gateway', 'assertion', 'platform',
   'assert_gateway_integrity', '', 'gateway_integrity_report', '',
   'The write gateway cannot be talked past.', true, 17),
  ('scheduler_integrity', 'Scheduler integrity', 'assertion', 'platform',
   'assert_scheduler_integrity', '', 'scheduler_integrity_report', '',
   'Every enabled job names a handler that exists.', true, 18),

  -- Configuration health.
  ('dead_configuration', 'Dead configuration', 'assertion', 'platform',
   'assert_no_dead_configuration', '', 'dead_configuration_report', '',
   'No configuration is stored that nothing reads — the failure mode that looks like a feature.', true, 20),
  ('configuration_promotable', 'Configuration surfaces', 'assertion', 'platform',
   'assert_configuration_promotable', '', null, '',
   'Every registered configuration surface is promotable, capturable and guarded.', true, 21),
  ('transaction_control', 'Transaction control routines', 'assertion', 'platform',
   'assert_transaction_control_routines', '', null, '',
   'No routine that commits is called from somewhere that cannot allow it to.', true, 22),
  ('document_create_permissions', 'Document create permissions', 'assertion', 'platform',
   'assert_document_create_permissions', '', 'document_create_permission_report', '',
   'No document type can be raised by somebody who only has permission to move it.', true, 23),
  ('resource_coverage', 'Resource coverage (en)', 'assertion', 'platform',
   'assert_resource_coverage', '''en''', 'resource_coverage_report', '''en''',
   'Every resource key the product references resolves in English.', true, 24),

  -- Module sanity: can each installed module's configuration actually fire?
  ('master_data_sane', 'Master data', 'assertion', 'platform',
   'assert_master_data_sane', '', 'master_data_configuration_report', '',
   'Every master-data rule can fire.', true, 30),
  ('inventory_sane', 'Inventory', 'assertion', 'platform',
   'assert_inventory_sane', '', 'inventory_configuration_report', '',
   'Every costing and count rule can fire.', true, 31),
  ('procurement_controls_sane', 'Procurement controls', 'assertion', 'platform',
   'assert_procurement_controls_sane', '', 'procurement_configuration_report', '',
   'Every tolerance and budget can fire.', true, 32),
  ('planning_sane', 'Planning', 'assertion', 'platform',
   'assert_planning_sane', '', 'planning_configuration_report', '',
   'Every planned item can actually be planned.', true, 33),
  ('production_sane', 'Production', 'assertion', 'platform',
   'assert_production_sane', '', 'production_configuration_report', '',
   'Every bill can be exploded and costed.', true, 34),
  ('sales_controls_sane', 'Sales controls', 'assertion', 'platform',
   'assert_sales_controls_sane', '', 'sales_configuration_report', '',
   'Every price and policy can apply.', true, 35),
  ('quality_logistics_sane', 'Quality and logistics', 'assertion', 'platform',
   'assert_quality_logistics_sane', '', 'quality_logistics_report', '',
   'Every plan measures something and every carrier can quote.', true, 36),
  ('finance_depth_sane', 'Finance depth', 'assertion', 'platform',
   'assert_finance_depth_sane', '', 'finance_depth_report', '',
   'Every close check runs and every rate has a source.', true, 37),
  ('part5_coverage', 'Part 5 capability coverage', 'assertion', 'platform',
   'assert_part5_coverage', '', 'part5_coverage_report', '',
   'Every declared capability is built, partial or absent — and says which.', true, 38),

  -- The invariants. These are the ones that catch a wrong number rather than a
  -- missing trigger, and three of the five are not in CI.
  ('determination_coverage', 'Account determination coverage (C1)', 'assertion', 'platform',
   'assert_determination_coverage', '', 'determination_coverage_report', '',
   'No posting can fail to determine an account. §5 refuses a suspense fallback, so a gap is a refusal.', true, 40),
  ('stock_reconciles', 'Stock reconciliation', 'assertion', 'platform',
   'assert_stock_reconciles', '', 'stock_reconciliation_report', '',
   'Every cached balance equals the sum of its movements.', false, 41),
  ('inventory_reconciles', 'Inventory valuation', 'assertion', 'platform',
   'assert_inventory_reconciles', '', 'inventory_reconciliation_report', '',
   'The stock ledger and the valuation agree.', false, 42),

  -- Tenant-scoped: these three need a tenant context, established by running them.
  ('subledger_reconciles', 'Subledger reconciliation', 'assertion', 'tenant',
   'assert_subledger_reconciles', '', 'subledger_reconciliation_report', '',
   'Every control account equals its subledger.', false, 50),
  ('batch_genealogy', 'Batch genealogy', 'assertion', 'tenant',
   'assert_batch_genealogy', '', null, '',
   'Every batch can be traced to what it was made from.', false, 51),
  ('manifest_unique', 'Configuration manifest keys', 'assertion', 'tenant',
   'assert_manifest_unique', '', null, '',
   'No two configuration objects share a key — every diff built on the manifest depends on it.', false, 52)

  ,('diagnostics_registered', 'The check register itself', 'assertion', 'platform',
   'assert_diagnostics_registered', '', null, '',
   'Every assertion is registered or exempt, and everything the register names exists.', true, 5)

on conflict (code) do update set
  title = excluded.title, kind = excluded.kind, scope = excluded.scope,
  function_name = excluded.function_name, arguments = excluded.arguments,
  detail_function = excluded.detail_function,
  detail_arguments = excluded.detail_arguments,
  blurb = excluded.blurb, runs_in_ci = excluded.runs_in_ci, seq = excluded.seq;

insert into erp_meta.diagnostic_exemption (schema_name, function_name, rationale) values
  ('erp', 'assert_legislation_conformance',
   'Takes an entity and a date. It runs on the promotion path — erp.promote_change_set() '
   'calls it for every entity with an active legislation binding — where the entity is known. '
   'A button could not supply one meaningfully.'),
  ('erp', 'assert_posting_rule_balances',
   'Takes a posting rule code and version. The module installers call it as they author each '
   'rule, which is the only point at which the pair is known.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

-- ── A gap in the generator, found by adding a table to it ────────────────────
--
-- The platform_internal branch of erp.apply_row_security() carries the comment
-- "No policy at all, and no grant. RLS is enabled, so a tenant session sees
-- zero rows" — and then only revokes. Enabling row security was left to each
-- migration by hand, which fourteen of them duly did, so the omission never
-- showed. Adding the fifteenth table found it: assert_isolation refused this
-- migration until the two tables above were enabled.
--
-- Fixing the generator rather than writing a fifteenth ALTER is the same
-- judgement as apply_live_config_guards(): a generator that leaves half its
-- stated job to its callers is a convention with a comment, not a generator.
-- It is a no-op for the fourteen that already have it.

create or replace function erp.apply_platform_internal_security()
returns integer
language plpgsql
set search_path = ''
as $$
declare r record; v_count integer := 0;
begin
  for r in
    select t.schema_name, t.table_name
      from erp_meta.table_policy t
      join pg_catalog.pg_class c on c.relname = t.table_name
      join pg_catalog.pg_namespace n
        on n.oid = c.relnamespace and n.nspname = t.schema_name
     where t.table_class = 'platform_internal' and c.relkind = 'r'
       and not (c.relrowsecurity and c.relforcerowsecurity)
  loop
    execute format('alter table %I.%I enable row level security',
                   r.schema_name, r.table_name);
    execute format('alter table %I.%I force row level security',
                   r.schema_name, r.table_name);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

comment on function erp.apply_platform_internal_security is
  'Enables and forces row security on every platform_internal table, which '
  'erp.apply_row_security() has always said it does and never did. Idempotent.';

select erp.apply_platform_internal_security();

-- ── Running one ──────────────────────────────────────────────────────────────

create or replace function erp.run_diagnostic(p_code text)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  c         erp_meta.diagnostic_check%rowtype;
  v_summary text;
  v_error   text;
  v_detail  jsonb;
begin
  select * into c from erp_meta.diagnostic_check where code = p_code;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_DIAGNOSTIC: % is not a registered check', p_code
      using errcode = '23503',
            hint = 'The register is the allow-list. A check that is not in it cannot be run.';
  end if;

  begin
    execute format('select %I.%I(%s)::text', c.schema_name, c.function_name, c.arguments)
      into v_summary;
    v_error := null;
  exception when others then
    v_summary := null;
    v_error := sqlerrm;
  end;

  -- The half that was missing. Every one of these assertions is backed by a
  -- report that lists what actually went wrong, and not one of those reports
  -- was reachable, so the screen could say isolation had failed and could not
  -- say which table.
  if v_error is not null and c.detail_function is not null then
    begin
      execute format('select coalesce(jsonb_agg(t), ''[]''::jsonb) from %I.%I(%s) t',
                     c.schema_name, c.detail_function, c.detail_arguments)
        into v_detail;
    exception when others then
      v_detail := jsonb_build_array(
        jsonb_build_object('finding', 'the detail report itself failed',
                           'detail', sqlerrm));
    end;
  end if;

  return jsonb_build_object(
    -- 'check' and 'detail' keep the shape the assurance screen already reads,
    -- so this is additive rather than a rename with a screen change attached.
    'check',    c.schema_name || '.' || c.function_name,
    'detail',   v_error,
    'code',     c.code,
    'title',    c.title,
    'scope',    c.scope,
    'blurb',    c.blurb,
    'runs_in_ci', c.runs_in_ci,
    'ok',       v_error is null,
    'summary',  v_summary,
    'findings', coalesce(v_detail, '[]'::jsonb));
end;
$$;

comment on function erp.run_diagnostic is
  'Runs one registered check and, if it failed, the report that explains why. '
  'The function it executes comes from erp_meta.diagnostic_check, which is '
  'platform_internal — no tenant session can write it and no door exposes it, '
  'so the register is the allow-list.';

-- ── Running all of them ──────────────────────────────────────────────────────
--
-- Same signature and same result shape as before; nine becomes twenty-nine, and
-- the next one is a row rather than an edit to this function.

create or replace function erp.platform_assurance()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_result jsonb := '[]'::jsonb;
  r        record;
begin
  for r in
    select d.code, d.scope from erp_meta.diagnostic_check d
     where d.kind = 'assertion'
     order by d.seq, d.code
  loop
    -- A tenant-scoped check outside a tenant context would report a missing
    -- context as a failure, which is a lie about the organisation rather than
    -- a finding about it.
    if r.scope = 'tenant' and erp.current_tenant_id() is null then
      v_result := v_result || jsonb_build_array(jsonb_build_object(
        'check', 'erp.' || (select function_name from erp_meta.diagnostic_check
                             where code = r.code),
        'code', r.code, 'ok', null, 'scope', r.scope,
        'title', (select title from erp_meta.diagnostic_check where code = r.code),
        'blurb', (select blurb from erp_meta.diagnostic_check where code = r.code),
        'summary', 'not run: needs an organisation',
        'detail', null, 'findings', '[]'::jsonb));
    else
      v_result := v_result || jsonb_build_array(erp.run_diagnostic(r.code));
    end if;
  end loop;
  return v_result;
end;
$$;

-- ── The doors ────────────────────────────────────────────────────────────────
--
-- Two levels, deliberately. Pass/fail is available to anybody who can read the
-- assurance screen, because "is this deployment sound" is a fair question for a
-- tenant administrator. The findings behind a failure name tables, functions
-- and other tenants' configuration, so they are platform staff only.

create or replace function public.erp_platform_diagnostics()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v erp_meta.platform_staff;
begin
  v := erp_meta.require_platform('support');

  return coalesce((select jsonb_agg(jsonb_build_object(
           'code', d.code, 'title', d.title, 'kind', d.kind, 'scope', d.scope,
           'blurb', d.blurb, 'runs_in_ci', d.runs_in_ci,
           'has_detail', d.detail_function is not null,
           'function', d.schema_name || '.' || d.function_name)
         order by d.seq, d.code)
    from erp_meta.diagnostic_check d), '[]'::jsonb);
end;
$$;

create or replace function public.erp_platform_run_check(p_code text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v erp_meta.platform_staff;
begin
  v := erp_meta.require_platform('support');
  return erp.run_diagnostic(p_code);
end;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.erp_platform_diagnostics()',
    'public.erp_platform_run_check(text)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale)
values ('public', 'erp_platform_diagnostics',
        'Lists the check register. erp_meta is platform_internal — RLS on with no '
        'policy and a blanket revoke — so no session reaches it without a definer. '
        'Returns no findings, only what could be run.')
on conflict do nothing;

insert into erp_meta.public_write_allowance (function_name, gate, rationale)
values
  -- Volatile because erp_meta.require_platform() binds auth_user_id the first
  -- time it sees an account, which is a write. erp_platform_audit is on this
  -- list for exactly the same reason.
  ('erp_platform_diagnostics', 'erp_meta.require_platform',
   'Lists the check register for platform staff. Writes nothing of its own; it '
   'is volatile because its gate binds the caller''s identity on first use.'),
  ('erp_platform_run_check', 'erp_meta.require_platform',
        'Runs one registered check and returns its findings. Gated on platform '
        'staff rather than erp.authorise() because the findings name tables and '
        'functions across every organisation, which is not a tenant permission.')
on conflict (function_name) do update set gate = excluded.gate,
                                          rationale = excluded.rationale;

-- ── The assertion that stops check thirty going unrun ────────────────────────

create or replace function erp.assert_diagnostics_registered()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count integer := 0;
  v_findings text := '';
  r record;
begin
  -- 1. Every assertion in the catalogue is registered or exempt. This is the
  --    whole reason for a register: fifteen of the twenty-four checks CI runs
  --    were unreachable from the product, and nothing said so.
  for r in
    select p.proname
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'erp' and p.proname like 'assert\_%'
       and not exists (select 1 from erp_meta.diagnostic_check d
                        where d.schema_name = 'erp' and d.function_name = p.proname)
       and not exists (select 1 from erp_meta.diagnostic_exemption e
                        where e.schema_name = 'erp' and e.function_name = p.proname)
     order by 1
  loop
    v_count := v_count + 1;
    v_findings := v_findings || format(
      E'  erp.%s is an assertion that is neither registered nor exempt — nothing can run it\n',
      r.proname);
  end loop;

  -- 2. Every registered function exists. A register naming something renamed
  --    away is worse than no register: it reports green over nothing.
  for r in
    select d.code, d.schema_name, d.function_name from erp_meta.diagnostic_check d
     where not exists (
       select 1 from pg_catalog.pg_proc p
         join pg_catalog.pg_namespace n on n.oid = p.pronamespace
        where n.nspname = d.schema_name and p.proname = d.function_name)
     order by d.code
  loop
    v_count := v_count + 1;
    v_findings := v_findings || format(
      E'  %s is registered as %s.%s, and no such function exists\n',
      r.code, r.schema_name, r.function_name);
  end loop;

  -- 3. And every detail report it promises.
  for r in
    select d.code, d.schema_name, d.detail_function from erp_meta.diagnostic_check d
     where d.detail_function is not null
       and not exists (
         select 1 from pg_catalog.pg_proc p
           join pg_catalog.pg_namespace n on n.oid = p.pronamespace
          where n.nspname = d.schema_name and p.proname = d.detail_function)
     order by d.code
  loop
    v_count := v_count + 1;
    v_findings := v_findings || format(
      E'  %s promises detail from %s.%s, and no such report exists\n',
      r.code, r.schema_name, r.detail_function);
  end loop;

  if v_count > 0 then
    raise exception E'ERPWARE_DIAGNOSTICS_UNREGISTERED: % finding(s)\n%',
      v_count, v_findings using errcode = '23514';
  end if;

  return format('diagnostics: %s checks registered, %s exempt, all resolvable',
                (select count(*) from erp_meta.diagnostic_check),
                (select count(*) from erp_meta.diagnostic_exemption));
end;
$$;

comment on function erp.assert_diagnostics_registered is
  'Every erp.assert_* is registered in erp_meta.diagnostic_check or exempted in '
  'erp_meta.diagnostic_exemption, and everything either register names exists. '
  'Without this, adding an assertion and forgetting to register it is silent — '
  'which is how fifteen of them ended up reachable only from a SQL client.';

-- ── Prove it ─────────────────────────────────────────────────────────────────

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();

select erp.assert_diagnostics_registered();
select erp.assert_public_api_safe();
select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
