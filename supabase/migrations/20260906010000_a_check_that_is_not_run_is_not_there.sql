-- A check that is not run is not there.
--
-- The catalogue holds seventy-three erp.assert_* functions and seventy-two
-- erp_test.assert_* suite wrappers. The build runs the ones somebody typed
-- into .github/workflows/schema.yml: sixty assertions and seventy-two
-- wrappers. Twelve assertions have never run in a build, five of them added
-- in the last week and simply never added to the list, and among the twelve
-- are the four that say whether the stock ledger, the subledgers, the
-- inventory valuation and the batch genealogy agree with themselves. The
-- product's central promise has been checked by hand on a demonstration
-- organisation and by nothing else.
--
-- supabase/ci/run_checks.sh has enumerated the catalogue since 4 September,
-- and its header says why: "a check that exists and is not run is a check
-- that is not there." The workflow never called it. This is the same shape
-- as the three health checks that could not be asked (20260905040000): a
-- sound check that nobody invoked, invisible because the register only
-- knows what it was seeded with.
--
-- So the build stops keeping a list. From here:
--
--   * erp.ci_check_catalogue() is the list. It reads pg_proc: every
--     erp.assert_* and erp_test.assert_* that can be called with no
--     arguments, the one procedure, and the whole-database reconciliation
--     that runs last. A new check is in the build by existing.
--
--   * erp_meta.check_run_exemption is the register for the checks CI
--     genuinely cannot call — the ones that take arguments only their
--     caller knows. A row either names the catalogue routine that drives
--     the check with those arguments, and the driver's body is checked for
--     the call, or it carries a written reason. An exemption for a check CI
--     could run is refused, so the register cannot be used to turn a check
--     off.
--
--   * erp.assert_ci_coverage() fails the build when a catalogue routine is
--     neither runnable nor exempt, an exemption names nothing, a driver does
--     not drive, or a suite has no wrapper pinning its case count. It is the
--     check that keeps this gap from reopening.
--
--   * erp.assert_ci_ran(p_ran) is called by the runner with the names it
--     actually executed. A catalogue entry missing from that list fails the
--     build; so does a name the catalogue does not carry, because a runner
--     that ran something the catalogue does not list has a list of its own.
--
--   * erp.assert_whole_database_reconciles() visits every organisation in a
--     trusted session (and the caller's own in a tenant session) and runs
--     every per-organisation assertion the register holds — the five
--     reconciliations the workflow never ran — plus every active posting
--     rule through erp.assert_posting_rule_balances() and every bound entity
--     through erp.assert_legislation_conformance(). CI runs it after every
--     suite has finished, against whatever the suites and the seeded
--     demonstration left behind. Per-organisation assertions are not in the
--     bare catalogue: three of the five refuse outside an organisation, and
--     the other two — stock and inventory — were found to pass over nothing,
--     registered as platform checks while filtering on a tenant nobody had
--     set. They are re-scoped here.
--
-- One more thing found on the way. supabase/ci/run_checks.sh skips
-- erp_test.gateway_suite() at exactly 3/49 on a local build, and the reason
-- given is PostgreSQL 16 against 17.6. It is not: it is
-- extensions.jsonb_matches_schema being a `select true` stub wherever
-- pg_jsonschema is absent. Two cases assert that an instance missing a
-- required key is refused; the third counts one command more because the
-- invalid one was accepted. erp.jsonb_matches_schema() enforces `type` and
-- `required` in SQL and then asks the extension, and every call site is
-- moved onto it by one asserted replacement loop. Local and CI now agree
-- on all forty-nine, and the remaining difference — the extension enforces
-- keywords the floor does not — is reported by erp.json_validator_report()
-- rather than hidden in a skip.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The register of checks the build cannot call directly
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists erp_meta.check_run_exemption (
  schema_name   text not null,
  function_name text not null,
  -- The catalogue routine that calls this check with the arguments only it
  -- knows, as schema.function. Null when the check is exempt for a reason
  -- rather than driven by something.
  driven_by     text,
  rationale     text not null,
  registered_at timestamptz not null default now(),
  primary key (schema_name, function_name),
  constraint check_run_exemption_explains
    check (length(btrim(rationale)) >= 40),
  constraint check_run_exemption_driver_is_qualified
    check (driven_by is null or driven_by ~ '^[a-z_]+\.[a-z0-9_]+$')
);

comment on table erp_meta.check_run_exemption is
  'The assertions the build cannot call with no arguments, each either driven '
  'by a catalogue routine that supplies them (and is checked for the call) or '
  'exempt for a written reason. erp.assert_ci_coverage() refuses a row that '
  'hides a check CI could run, so this register cannot turn a check off.';

select erp_meta.register_table('erp_meta', 'check_run_exemption', 'platform_internal',
  'Register of assertions the build cannot call directly. Not tenant data.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The catalogue, read from pg_proc rather than from a list
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.ci_check_catalogue()
returns table(phase text, seq integer, schema_name text, function_name text,
              qualified_name text, call text)
language sql
stable
set search_path = ''
as $$
  with routines as (
    select n.nspname as schema_name, p.proname as function_name,
           p.prokind, p.pronargs, p.pronargdefaults
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('erp', 'erp_test')
       and p.proname like 'assert\_%'
       and p.prokind in ('f', 'p')
       -- Callable with no arguments: every parameter has a default.
       and p.pronargs = p.pronargdefaults
       -- Not per-organisation. A tenant-scoped assertion run with no
       -- organisation either refuses (three of them) or passes over
       -- nothing (two of them did, for a fortnight). The whole-database
       -- reconciliation runs every one of them for every organisation.
       and not exists (
         select 1 from erp_meta.diagnostic_check d
          where d.schema_name = n.nspname and d.function_name = p.proname
            and d.scope = 'tenant'
            and d.function_name <> 'assert_whole_database_reconciles')
  ),
  phased as (
    select r.*,
           case
             when r.schema_name = 'erp'
              and r.function_name = 'assert_whole_database_reconciles' then 'final'
             when r.prokind = 'p'                                       then 'procedure'
             when r.schema_name = 'erp_test'                            then 'suite'
             else                                                            'structural'
           end as phase
      from routines r
  )
  select p.phase,
         case p.phase when 'structural' then 1 when 'suite' then 2
                      when 'procedure' then 3 else 4 end as seq,
         p.schema_name, p.function_name,
         p.schema_name || '.' || p.function_name as qualified_name,
         case when p.prokind = 'p'
              then format('call %I.%I()', p.schema_name, p.function_name)
              else format('select %I.%I()', p.schema_name, p.function_name)
         end as call
    from phased p
   order by 2, 3, 4;
$$;

comment on function erp.ci_check_catalogue is
  'Every check the build runs, in the order it runs them: structural '
  'assertions, adversarial suites, the one procedure, and the whole-database '
  'reconciliation last. Read from pg_proc, so a check is in the build by '
  'existing and a deleted one is noticed by erp.assert_ci_ran().';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Coverage: what the catalogue cannot see, and what would hide from it
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.ci_coverage_report()
returns table(finding text, detail text)
language sql
stable
set search_path = ''
as $$
  with routines as (
    select n.nspname as schema_name, p.proname as function_name,
           p.prokind, p.pronargs, p.pronargdefaults, p.proretset, p.prosrc
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('erp', 'erp_test')
  ),
  asserts as (
    select * from routines where function_name like 'assert\_%'
  ),
  runnable as (
    select schema_name, function_name from asserts
     where prokind in ('f', 'p') and pronargs = pronargdefaults
  )
  -- 1. An assertion the build cannot call, with no exemption and no driver.
  select 'an assertion takes arguments the build cannot supply and is neither driven nor exempt',
         format('%s.%s takes %s argument(s); register it in erp_meta.check_run_exemption '
                'with the routine that drives it, or a reason', a.schema_name, a.function_name, a.pronargs)
    from asserts a
   where not (a.prokind in ('f', 'p') and a.pronargs = a.pronargdefaults)
     and not exists (select 1 from erp_meta.check_run_exemption e
                      where e.schema_name = a.schema_name and e.function_name = a.function_name)
  union all
  -- 2. Two overloads under one name: the catalogue cannot name one of them.
  select 'two assertions share a name, so a call by name is ambiguous',
         format('%s.%s has %s overloads', a.schema_name, a.function_name, count(*))
    from asserts a
   group by a.schema_name, a.function_name
  having count(*) > 1
  union all
  -- 3. An exemption for something that does not exist.
  select 'an exemption names a routine that does not exist',
         format('%s.%s is exempt and is not in the catalogue', e.schema_name, e.function_name)
    from erp_meta.check_run_exemption e
   where not exists (select 1 from asserts a
                      where a.schema_name = e.schema_name and a.function_name = e.function_name)
  union all
  -- 4. An exemption that hides a check the build could run.
  select 'an exemption hides a check the build could run',
         format('%s.%s can be called with no arguments; delete the exemption', e.schema_name, e.function_name)
    from erp_meta.check_run_exemption e
    join runnable r on r.schema_name = e.schema_name and r.function_name = e.function_name
  union all
  -- 5. A driver that is not in the catalogue, or does not call what it drives.
  select 'a driver does not drive the check it is registered as driving',
         format('%s.%s is driven by %s, which %s', e.schema_name, e.function_name, e.driven_by,
                case when d.function_name is null then 'is not a routine the build runs'
                     else 'does not call it' end)
    from erp_meta.check_run_exemption e
    left join runnable d
      on d.schema_name || '.' || d.function_name = e.driven_by
    left join routines dr
      on dr.schema_name = d.schema_name and dr.function_name = d.function_name
   where e.driven_by is not null
     and (d.function_name is null
          or position(e.schema_name || '.' || e.function_name || '(' in dr.prosrc) = 0)
  union all
  -- 6. A suite body nothing wraps: its case count is pinned by nobody.
  select 'a suite has no wrapper, so nothing pins its case count',
         format('erp_test.%s() is called by no erp_test.assert_* routine', s.function_name)
    from routines s
   where s.schema_name = 'erp_test'
     and s.function_name like '%\_suite'
     and s.function_name not like 'assert\_%'
     and s.proretset
     and not exists (
       select 1 from routines w
        where w.schema_name = 'erp_test' and w.function_name like 'assert\_%'
          and position('erp_test.' || s.function_name || '(' in w.prosrc) > 0)
  order by 1, 2;
$$;

comment on function erp.ci_coverage_report is
  'Every way a check could exist without being run: an assertion the build '
  'cannot call and nothing accounts for, an ambiguous name, a stale or '
  'dishonest exemption, a driver that does not drive, a suite with no wrapper.';

create or replace function erp.assert_ci_coverage()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count    integer;
  v_findings text;
begin
  select count(*), string_agg(format('  %s — %s', r.finding, r.detail), E'\n' order by r.finding, r.detail)
    into v_count, v_findings
    from erp.ci_coverage_report() r;

  if v_count > 0 then
    raise exception E'CLOVEERP_CHECKS_UNRUNNABLE: % finding(s)\n%', v_count, v_findings
      using errcode = '23514',
            hint = 'Every assertion is run by the build by existing. One that takes arguments '
                   'is registered in erp_meta.check_run_exemption with the routine that drives it.';
  end if;

  return format('ci coverage: %s structural, %s suite(s), %s procedure(s), %s final, %s exempt (%s driven)',
    (select count(*) from erp.ci_check_catalogue() where phase = 'structural'),
    (select count(*) from erp.ci_check_catalogue() where phase = 'suite'),
    (select count(*) from erp.ci_check_catalogue() where phase = 'procedure'),
    (select count(*) from erp.ci_check_catalogue() where phase = 'final'),
    (select count(*) from erp_meta.check_run_exemption),
    (select count(*) from erp_meta.check_run_exemption where driven_by is not null));
end;
$$;

comment on function erp.assert_ci_coverage is
  'Fails the build when a catalogue assertion or suite exists that the build '
  'neither runs nor accounts for. This is the check that keeps the gap between '
  'the catalogue and the workflow from reopening.';

create or replace function erp.assert_ci_ran(p_ran text[])
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_missing text;
  v_n_missing integer;
  v_extra   text;
  v_n_extra integer;
  v_total   integer;
begin
  perform erp.assert_ci_coverage();

  select count(*), string_agg('  ' || c.qualified_name, E'\n' order by c.seq, c.qualified_name)
    into v_n_missing, v_missing
    from erp.ci_check_catalogue() c
   where c.qualified_name <> all (coalesce(p_ran, '{}'));

  if v_n_missing > 0 then
    raise exception E'CLOVEERP_CHECK_NOT_RUN: % catalogue check(s) were not run\n%', v_n_missing, v_missing
      using errcode = '23514',
            hint = 'The runner reads erp.ci_check_catalogue(); a check it did not run was skipped or failed to be listed.';
  end if;

  select count(*), string_agg('  ' || x, E'\n' order by x)
    into v_n_extra, v_extra
    from unnest(coalesce(p_ran, '{}')) x
   where not exists (select 1 from erp.ci_check_catalogue() c where c.qualified_name = x);

  if v_n_extra > 0 then
    raise exception E'CLOVEERP_CHECK_UNLISTED: the runner ran % name(s) the catalogue does not carry\n%', v_n_extra, v_extra
      using errcode = '23514',
            hint = 'A runner with names of its own has a list of its own. Run the catalogue and nothing else.';
  end if;

  select count(*) into v_total from erp.ci_check_catalogue();
  return format('ci ran %s of %s catalogue checks', v_total, v_total);
end;
$$;

comment on function erp.assert_ci_ran is
  'Called by supabase/ci/run_checks.sh with the qualified names it executed. '
  'A catalogue check absent from the list, or a listed name absent from the '
  'catalogue, fails the build.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The whole database, at the very end
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.assert_whole_database_reconciles()
returns text
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_trusted  boolean := erp.session_is_trusted();
  v_prev     text    := current_setting('erp.job_tenant_id', true);
  v_own      uuid    := erp.current_tenant_id();
  v_tenants  integer := 0;
  v_checks   integer := 0;
  v_fail     integer := 0;
  v_findings text    := '';
  v_out      text;
  v_call     text;
  t          record;
  r          record;
begin
  if not v_trusted and v_own is null then
    raise exception 'CLOVEERP_NO_TENANT_CONTEXT: the whole-database reconciliation visits every organisation from a trusted session, or the caller''s own from an organisation session; this session has neither'
      using errcode = '42501';
  end if;

  for t in
    select tn.id, tn.code
      from erp.tenant tn
     where v_trusted or tn.id = v_own
     order by tn.code
  loop
    v_tenants := v_tenants + 1;
    if v_trusted then
      perform set_config('erp.job_tenant_id', t.id::text, true);
    end if;

    -- Every per-organisation assertion the register holds — stock, subledger,
    -- inventory, genealogy, manifest today — read from the register, so a
    -- tenant-scoped assertion registered tomorrow is driven by existing.
    for r in
      select d.schema_name, d.function_name, d.arguments
        from erp_meta.diagnostic_check d
       where d.kind = 'assertion' and d.scope = 'tenant'
         and d.function_name <> 'assert_whole_database_reconciles'
       order by d.seq, d.code
    loop
      v_call := format('%I.%I(%s)', r.schema_name, r.function_name, r.arguments);
      begin
        execute 'select ' || v_call into v_out;
        v_checks := v_checks + 1;
      exception when others then
        v_fail := v_fail + 1;
        v_findings := v_findings || format(E'  %s: %s — %s\n', t.code, v_call, left(sqlerrm, 300));
      end;
    end loop;

    -- Every posting rule in force, through the check its installer ran once.
    for r in
      select pr.code, pr.version
        from erp.posting_rule pr
       where pr.tenant_id = t.id and pr.status = 'active'
       order by pr.code, pr.version
    loop
      begin
        perform erp.assert_posting_rule_balances(r.code, r.version);
        v_checks := v_checks + 1;
      exception when others then
        v_fail := v_fail + 1;
        v_findings := v_findings || format(E'  %s: posting rule %s v%s — %s\n', t.code, r.code, r.version, left(sqlerrm, 300));
      end;
    end loop;

    -- Every entity bound to legislation, through the conformance cases.
    for r in
      select distinct b.entity_id, e.code as entity_code
        from erp.entity_legislation_binding b
        join erp.entity e on e.id = b.entity_id
       where b.tenant_id = t.id and b.status = 'active'
         and (b.effective_to is null or b.effective_to > current_date)
       order by e.code
    loop
      begin
        perform erp.assert_legislation_conformance(r.entity_id);
        v_checks := v_checks + 1;
      exception when others then
        v_fail := v_fail + 1;
        v_findings := v_findings || format(E'  %s: legislation on %s — %s\n', t.code, r.entity_code, left(sqlerrm, 300));
      end;
    end loop;
  end loop;

  if v_trusted then
    perform set_config('erp.job_tenant_id', coalesce(v_prev, ''), true);
  end if;

  if v_fail > 0 then
    raise exception E'CLOVEERP_DATABASE_DOES_NOT_RECONCILE: %/% check(s) failed across % organisation(s)\n%',
      v_fail, v_fail + v_checks, v_tenants, v_findings
      using errcode = '23514';
  end if;

  return format('whole database: %s organisation(s), %s check(s), all reconcile', v_tenants, v_checks);
end;
$$;

comment on function erp.assert_whole_database_reconciles is
  'Stock, subledger, inventory, genealogy and manifest for every organisation, '
  'every active posting rule balanced, every bound entity conformant. A trusted '
  'session visits every organisation; an organisation session checks its own. '
  'The build runs it last, after every suite, against whatever they left.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. A JSON floor the stub cannot fall through
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.jsonb_matches_schema(p_schema json, p_instance jsonb)
returns boolean
language sql
stable
set search_path = ''
as $$
  select case
    when p_schema is null then true
    -- `type: object` against a non-object is a refusal on any validator.
    when (p_schema::jsonb ->> 'type') = 'object' and jsonb_typeof(p_instance) <> 'object' then false
    -- `required` applies to objects: every named key must be present.
    when jsonb_typeof(p_instance) = 'object'
     and exists (select 1
                   from jsonb_array_elements_text(coalesce(p_schema::jsonb -> 'required', '[]'::jsonb)) k
                  where not (p_instance ? k)) then false
    else extensions.jsonb_matches_schema(p_schema, p_instance)
  end
$$;

comment on function erp.jsonb_matches_schema is
  'JSON Schema validation with a floor: `type: object` and `required` are '
  'enforced here, and everything else is asked of extensions.jsonb_matches_schema. '
  'On a host where the extension is a stub the floor still refuses an instance '
  'missing a required key, so a build with and without pg_jsonschema agree.';

create or replace function erp.json_validator_report()
returns table(validator_real boolean, detail text)
language sql
stable
set search_path = ''
as $$
  -- A schema the floor does not cover: additionalProperties. Only a real
  -- validator refuses it.
  select not extensions.jsonb_matches_schema(
           '{"type":"object","properties":{"a":{"type":"integer"}},"additionalProperties":false}'::json,
           '{"a":1,"b":2}'::jsonb),
         case when extensions.jsonb_matches_schema(
                     '{"type":"object","properties":{"a":{"type":"integer"}},"additionalProperties":false}'::json,
                     '{"a":1,"b":2}'::jsonb)
              then 'extensions.jsonb_matches_schema accepts an undeclared property: it is a stub here, and only `type` and `required` are enforced'
              else 'extensions.jsonb_matches_schema refuses an undeclared property: the validator is real' end;
$$;

comment on function erp.json_validator_report is
  'Whether the host''s pg_jsonschema enforces more than the floor in '
  'erp.jsonb_matches_schema(). Reported, not asserted: a local build without '
  'the extension is a smaller claim, not a broken one.';

-- Move every call site onto the floor, from the definitions the database is
-- carrying, and refuse if the count is not the one measured on a fresh build.
do $patch$
declare
  r        record;
  v_def    text;
  v_n      integer := 0;
  -- Eight on a fresh build: lint_rule_set_version, validate_event_payload,
  -- validate_config_value, evaluate_rules, check_external_system_connection,
  -- submit_command, complete_command, maintain_job_schedule. Eleven files
  -- carry the call; three of those bodies were since redefined without it.
  v_expect constant integer := 8;
begin
  for r in
    select p.oid, n.nspname, p.proname
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('erp', 'erp_ref', 'erp_meta', 'erp_ai', 'erp_test', 'erp_ingress', 'public')
       and not (n.nspname = 'erp' and p.proname in ('jsonb_matches_schema', 'json_validator_report'))
       and position('extensions.jsonb_matches_schema(' in p.prosrc) > 0
     order by n.nspname, p.proname
  loop
    v_def := pg_get_functiondef(r.oid);
    v_def := replace(v_def, 'extensions.jsonb_matches_schema(', 'erp.jsonb_matches_schema(');
    execute v_def;
    v_n := v_n + 1;
  end loop;

  if v_n <> v_expect then
    raise exception 'CLOVEERP_JSON_CALL_SITES_UNRECOGNISED: expected % routines calling extensions.jsonb_matches_schema, patched %', v_expect, v_n;
  end if;

  if exists (
    select 1 from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('erp', 'erp_ref', 'erp_meta', 'erp_ai', 'erp_test', 'erp_ingress', 'public')
       and not (n.nspname = 'erp' and p.proname in ('jsonb_matches_schema', 'json_validator_report'))
       and position('extensions.jsonb_matches_schema(' in p.prosrc) > 0)
  then
    raise exception 'CLOVEERP_JSON_CALL_SITES_UNRECOGNISED: a routine still calls the extension directly';
  end if;
end
$patch$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. Registers
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_meta.check_run_exemption (schema_name, function_name, driven_by, rationale) values
  ('erp', 'assert_posting_rule_balances', 'erp.assert_whole_database_reconciles',
   'Takes a posting rule code and version. The whole-database reconciliation calls it for every '
   'rule in force in every organisation, at the end of the build.'),
  ('erp', 'assert_legislation_conformance', 'erp.assert_whole_database_reconciles',
   'Takes an entity and a date. The whole-database reconciliation calls it for every entity with '
   'an active legislation binding, in every organisation, at the end of the build.'),
  ('erp', 'assert_ci_ran', null,
   'Takes the list of qualified names the runner executed. supabase/ci/run_checks.sh calls it '
   'last with that list; nothing else can know what ran.')
on conflict (schema_name, function_name) do update
  set driven_by = excluded.driven_by, rationale = excluded.rationale;

-- Two reconciliations were registered as platform-scoped and pass over
-- nothing outside an organisation: erp.assert_stock_reconciles() answers
-- "every cached balance equals the sum of its movements" for zero balances,
-- and erp.assert_inventory_reconciles() "the ledger and the valuation agree"
-- for an empty ledger. They filter on erp.current_tenant_id() rather than
-- requiring one. Scoped correctly, the console short-circuits them without an
-- organisation and the whole-database reconciliation drives them with one.
update erp_meta.diagnostic_check set scope = 'tenant'
 where function_name in ('assert_stock_reconciles', 'assert_inventory_reconciles');

do $scope$ begin
  if (select count(*) from erp_meta.diagnostic_check
       where kind = 'assertion' and scope = 'tenant'
         and function_name in ('assert_stock_reconciles', 'assert_subledger_reconciles',
                               'assert_inventory_reconciles', 'assert_batch_genealogy',
                               'assert_manifest_unique')) <> 5 then
    raise exception 'CLOVEERP_DIAGNOSTIC_REGISTER_UNRECOGNISED: the five reconciliations are not all tenant-scoped';
  end if;
end $scope$;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq) values
  ('ci_coverage', 'Every check is run by the build', 'assertion', 'platform',
   'assert_ci_coverage', '', 'ci_coverage_report', '',
   'Every assertion and suite in the catalogue is run by the build or accounted for in the exemption register.', true, 54),
  ('whole_database', 'The whole database reconciles', 'assertion', 'tenant',
   'assert_whole_database_reconciles', '', null, '',
   'Stock, subledger, inventory, genealogy and manifest for this organisation, every posting rule in force balanced, every bound entity conformant. The build runs it for every organisation, last.', true, 90)
on conflict (code) do update
  set title = excluded.title, function_name = excluded.function_name, arguments = excluded.arguments,
      detail_function = excluded.detail_function, blurb = excluded.blurb, seq = excluded.seq;

insert into erp_meta.diagnostic_exemption (schema_name, function_name, rationale) values
  ('erp', 'assert_ci_ran',
   'Takes the list of names the CI runner executed. A button has no such list; the console '
   'runs erp.assert_ci_coverage(), which answers the catalogue side of the same question.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

revoke all on function erp.ci_check_catalogue() from public, anon, authenticated;
revoke all on function erp.ci_coverage_report() from public, anon, authenticated;
revoke all on function erp.assert_ci_coverage() from public, anon, authenticated;
revoke all on function erp.assert_ci_ran(text[]) from public, anon, authenticated;
revoke all on function erp.assert_whole_database_reconciles() from public, anon, authenticated;
revoke all on function erp.json_validator_report() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.ci_coverage_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases    integer := 0;
  v_expected integer;
  v_actual   integer;
  v_names    text[];
  v_msg      text;
  v_tenant   uuid;
  v_ran      boolean;
begin
  -- 1. The catalogue is exactly the set of zero-argument assert_* routines.
  v_cases := v_cases + 1;
  select count(*) into v_expected
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('erp', 'erp_test') and p.proname like 'assert\_%'
     and p.prokind in ('f', 'p') and p.pronargs = p.pronargdefaults
     and not exists (select 1 from erp_meta.diagnostic_check d
                      where d.schema_name = n.nspname and d.function_name = p.proname
                        and d.scope = 'tenant' and d.function_name <> 'assert_whole_database_reconciles');
  select count(*) into v_actual from erp.ci_check_catalogue();
  case_name := 'the catalogue lists every assertion the build can call bare, and no per-organisation one';
  passed := v_actual = v_expected and v_actual > 100
        and not exists (select 1 from erp.ci_check_catalogue() where function_name = 'assert_subledger_reconciles')
        and exists (select 1 from erp.ci_check_catalogue() where function_name = 'assert_whole_database_reconciles' and phase = 'final');
  detail := format('%s in the catalogue, %s callable bare; the subledger reconciliation is driven, not listed', v_actual, v_expected);
  return next;

  -- 2. An assertion that takes arguments and is accounted for by nothing.
  v_cases := v_cases + 1;
  v_msg := null;
  begin
    execute 'create function erp.assert_zz_takes_args(p_x integer) returns text language sql as $f$ select ''x'' $f$';
    begin
      perform erp.assert_ci_coverage();
    exception when others then v_msg := sqlerrm;
    end;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
  end;
  case_name := 'an assertion that takes arguments and is neither driven nor exempt is refused';
  passed := v_msg like 'CLOVEERP_CHECKS_UNRUNNABLE:%' and v_msg like '%assert_zz_takes_args%';
  detail := left(coalesce(v_msg, 'no refusal'), 200);
  return next;

  -- 3. An exemption naming nothing.
  v_cases := v_cases + 1;
  v_msg := null;
  begin
    insert into erp_meta.check_run_exemption (schema_name, function_name, rationale)
    values ('erp', 'assert_zz_missing', 'A rationale long enough to satisfy the constraint and nothing more.');
    begin
      perform erp.assert_ci_coverage();
    exception when others then v_msg := sqlerrm;
    end;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
  end;
  case_name := 'an exemption naming a routine that does not exist is refused';
  passed := v_msg like 'CLOVEERP_CHECKS_UNRUNNABLE:%' and v_msg like '%assert_zz_missing%';
  detail := left(coalesce(v_msg, 'no refusal'), 200);
  return next;

  -- 4. An exemption that would turn a runnable check off.
  v_cases := v_cases + 1;
  v_msg := null;
  begin
    insert into erp_meta.check_run_exemption (schema_name, function_name, rationale)
    values ('erp', 'assert_isolation', 'Pretend the isolation assertion cannot be run, which it can.');
    begin
      perform erp.assert_ci_coverage();
    exception when others then v_msg := sqlerrm;
    end;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
  end;
  case_name := 'an exemption that hides a check the build could run is refused';
  passed := v_msg like 'CLOVEERP_CHECKS_UNRUNNABLE:%' and v_msg like '%hides a check%assert_isolation%';
  detail := left(coalesce(v_msg, 'no refusal'), 200);
  return next;

  -- 5. A driver that does not call what it drives.
  v_cases := v_cases + 1;
  v_msg := null;
  begin
    update erp_meta.check_run_exemption set driven_by = 'erp.assert_isolation'
     where schema_name = 'erp' and function_name = 'assert_posting_rule_balances';
    begin
      perform erp.assert_ci_coverage();
    exception when others then v_msg := sqlerrm;
    end;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
  end;
  case_name := 'a driver that does not call the check it drives is refused';
  passed := v_msg like 'CLOVEERP_CHECKS_UNRUNNABLE:%' and v_msg like '%does not call it%';
  detail := left(coalesce(v_msg, 'no refusal'), 200);
  return next;

  -- 6. A suite body with no wrapper.
  v_cases := v_cases + 1;
  v_msg := null;
  begin
    execute 'create function erp_test.zz_orphan_suite() returns table(case_name text, passed boolean, detail text) language sql as $f$ select ''x'', true, ''y'' $f$';
    begin
      perform erp.assert_ci_coverage();
    exception when others then v_msg := sqlerrm;
    end;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
  end;
  case_name := 'a suite with no wrapper pinning its case count is refused';
  passed := v_msg like 'CLOVEERP_CHECKS_UNRUNNABLE:%' and v_msg like '%zz_orphan_suite%';
  detail := left(coalesce(v_msg, 'no refusal'), 200);
  return next;

  -- 7. The runner left one out.
  v_cases := v_cases + 1;
  select array_agg(c.qualified_name) into v_names
    from erp.ci_check_catalogue() c where c.qualified_name <> 'erp.assert_isolation';
  v_msg := null;
  begin
    perform erp.assert_ci_ran(v_names);
  exception when others then v_msg := sqlerrm;
  end;
  case_name := 'a catalogue check the runner did not run is refused';
  passed := v_msg like 'CLOVEERP_CHECK_NOT_RUN:%' and v_msg like '%erp.assert_isolation%';
  detail := left(coalesce(v_msg, 'no refusal'), 200);
  return next;

  -- 8. The runner ran something of its own.
  v_cases := v_cases + 1;
  select array_agg(c.qualified_name) || array['erp.assert_zz_nothing'] into v_names
    from erp.ci_check_catalogue() c;
  v_msg := null;
  begin
    perform erp.assert_ci_ran(v_names);
  exception when others then v_msg := sqlerrm;
  end;
  case_name := 'a name the catalogue does not carry is refused';
  passed := v_msg like 'CLOVEERP_CHECK_UNLISTED:%' and v_msg like '%erp.assert_zz_nothing%';
  detail := left(coalesce(v_msg, 'no refusal'), 200);
  return next;

  -- 9. The complete list passes.
  v_cases := v_cases + 1;
  select array_agg(c.qualified_name) into v_names from erp.ci_check_catalogue() c;
  v_msg := null;
  begin
    v_msg := erp.assert_ci_ran(v_names);
    v_ran := true;
  exception when others then v_msg := sqlerrm; v_ran := false;
  end;
  case_name := 'the complete list is accepted';
  passed := v_ran and v_msg like 'ci ran % of % catalogue checks';
  detail := left(coalesce(v_msg, 'no answer'), 200);
  return next;

  -- 10. The whole database refuses an organisation whose posting rule is unbalanced.
  v_cases := v_cases + 1;
  v_msg := null;
  begin
    insert into erp.tenant (code, name) values ('zz-ci-coverage', 'CI coverage suite')
    returning id into v_tenant;
    insert into erp.posting_rule (tenant_id, code, event_type, posting_lines, status, effective_from)
    values (v_tenant, 'zz_unbalanced', 'goods_receipt',
            '[{"side":"debit","account":"1200","basis":"document_value","rate":1}]'::jsonb,
            'active', date '2020-01-01');
    begin
      perform erp.assert_whole_database_reconciles();
    exception when others then v_msg := sqlerrm;
    end;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
  end;
  case_name := 'the whole-database reconciliation names the organisation whose rule is unbalanced';
  passed := v_msg like 'CLOVEERP_DATABASE_DOES_NOT_RECONCILE:%' and v_msg like '%zz-ci-coverage%zz_unbalanced%';
  detail := left(coalesce(v_msg, 'no refusal'), 200);
  return next;

  -- 11. And the falsification was undone.
  v_cases := v_cases + 1;
  case_name := 'every falsification was undone';
  passed := not exists (select 1 from erp.tenant where code = 'zz-ci-coverage')
        and not exists (select 1 from pg_catalog.pg_proc where proname in ('assert_zz_takes_args', 'zz_orphan_suite'))
        and not exists (select 1 from erp_meta.check_run_exemption where function_name in ('assert_zz_missing', 'assert_isolation'))
        and (select driven_by from erp_meta.check_run_exemption
              where schema_name = 'erp' and function_name = 'assert_posting_rule_balances') = 'erp.assert_whole_database_reconciles';
  detail := 'no tenant, no routine, no row left behind';
  return next;

  if v_cases <> 11 then
    raise exception 'CLOVEERP_SUITE_SHRANK: ci_coverage_suite ran % cases, expected 11', v_cases;
  end if;
end;
$$;

create or replace function erp_test.assert_ci_coverage_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_fail   integer;
  v_all    integer;
  v_detail text;
begin
  create temp table if not exists _ci_coverage on commit drop as
    select * from erp_test.ci_coverage_suite();
  select count(*), count(*) filter (where not passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_all, v_fail, v_detail
    from _ci_coverage;
  drop table _ci_coverage;
  if v_fail > 0 then
    raise exception E'CLOVEERP_CI_COVERAGE_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> 11 then
    raise exception 'CLOVEERP_SUITE_SHRANK: ci_coverage_suite ran % cases, expected 11', v_all;
  end if;
  return format('ci coverage: %s/%s cases passed', v_all, v_all);
end;
$$;

revoke all on function erp_test.ci_coverage_suite() from public, anon, authenticated;
revoke all on function erp_test.assert_ci_coverage_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. Prove it
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();

select erp.assert_ci_coverage();
select erp_test.assert_ci_coverage_suite();
select erp.assert_whole_database_reconciles();

-- The floor: forty-nine of forty-nine, with or without the extension.
select erp_test.assert_gateway_suite();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_diagnostics_registered();
select erp.assert_session_context_hygiene();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();

-- And the whole console, green.
do $console$
declare v_bad text;
begin
  select string_agg(c ->> 'code' || ': ' || left(c ->> 'detail', 80), '; ')
    into v_bad
    from jsonb_array_elements(erp.platform_assurance()) c
   where not (c ->> 'ok')::boolean;
  if v_bad is not null then
    raise exception 'CLOVEERP_ASSURANCE_NOT_GREEN: %', v_bad;
  end if;
end
$console$;
