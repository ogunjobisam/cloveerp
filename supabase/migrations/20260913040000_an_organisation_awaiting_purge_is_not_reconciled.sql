-- An organisation awaiting purge is not reconciled.
--
-- The deploy proves the live database last by asking
-- erp.assert_whole_database_reconciles() to visit every organisation. On 13
-- September it stopped on a demonstration organisation seeded before the
-- ledger learned to follow the stock event: a valuation of 17,061,995 minor
-- units with nothing posted against nominal account 1200. The organisation's
-- owner has asked for it to be deleted, which is the right answer for data
-- that was never meant to be kept. A deletion request sets erp.tenant.deleted_at
-- and suspends the organisation; the purge job removes it once the grace
-- period has passed (20260831180000, 20260831214239).
--
-- Until then, every deploy would apply its migrations, record its release,
-- and stop red on books that are about to be destroyed. That is not a finding
-- about the platform; it is a finding about an organisation that has already
-- been judged. So the whole-database reconciliation now leaves aside any
-- organisation whose deleted_at is set, and says so in its result, by name.
--
-- deleted_at, not status, is the marker. 20260831180000 put it plainly:
-- "deleted_at is the marker of intent, and only two things set it:
-- erp_request_tenant_deletion, and an owner marking an organisation ended. An
-- organisation merely suspended has suspended_at and no deleted_at, so it is
-- never swept — suspension is not a deletion request." A suspended
-- organisation's books must still balance, and they are still checked here.
--
-- Nothing else about the check moves. The raise keeps its prefix and still
-- names the organisation and the rule at fault (erp_test.ci_coverage_suite
-- case 10 reads both); the success text still begins 'whole database: N
-- organisation(s), ' and still ends ' check(s), all reconcile'
-- (erp_test.door_isolation_suite case 4 reads both ends), and is byte-for-byte
-- what it was when nothing is awaiting purge.
--
-- A rule a suite cannot see is a missing suite, so erp_test.ci_coverage_suite
-- gains a case: an organisation with deleted_at set and an unbalanced posting
-- rule is named as skipped and is not visited. The suite and its wrapper are
-- patched from their live definitions rather than re-emitted — the wrapper's
-- body was rewritten once already by 20260906050000 to the strict verdict
-- form, and re-emitting the original would undo that.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The check leaves aside what is about to be destroyed
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
  v_skipped  integer := 0;
  v_skipped_codes text;
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

  -- An organisation awaiting purge has asked to be destroyed; deleted_at is
  -- the marker of that request (20260831180000). Its books are not visited,
  -- and it is named below so the result says what was left aside.
  select count(*), string_agg(tn.code, ', ' order by tn.code)
    into v_skipped, v_skipped_codes
    from erp.tenant tn
   where (v_trusted or tn.id = v_own)
     and tn.deleted_at is not null;

  for t in
    select tn.id, tn.code
      from erp.tenant tn
     where (v_trusted or tn.id = v_own)
       and tn.deleted_at is null
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

  if v_skipped > 0 then
    v_findings := v_findings || format(E'  %s awaiting purge skipped (%s)\n', v_skipped, v_skipped_codes);
  end if;

  if v_fail > 0 then
    raise exception E'CLOVEERP_DATABASE_DOES_NOT_RECONCILE: %/% check(s) failed across % organisation(s)\n%',
      v_fail, v_fail + v_checks, v_tenants, v_findings
      using errcode = '23514';
  end if;

  return format('whole database: %s organisation(s), %s%s check(s), all reconcile',
                v_tenants,
                case when v_skipped > 0
                     then format('%s awaiting purge skipped (%s), ', v_skipped, v_skipped_codes)
                     else '' end,
                v_checks);
end;
$$;

comment on function erp.assert_whole_database_reconciles is
  'Stock, subledger, inventory, genealogy and manifest for every organisation, '
  'every active posting rule balanced, every bound entity conformant. A trusted '
  'session visits every organisation; an organisation session checks its own. '
  'An organisation awaiting purge (deleted_at set) is left aside and named in '
  'the result: its books are about to be destroyed with it. The build runs it '
  'last, after every suite, against whatever they left.';

revoke all on function erp.assert_whole_database_reconciles() from public, anon, authenticated;

-- The register row says the same, so the console does.
insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq) values
  ('whole_database', 'The whole database reconciles', 'assertion', 'tenant',
   'assert_whole_database_reconciles', '', null, '',
   'Stock, subledger, inventory, genealogy and manifest for this organisation, every posting rule in force balanced, every bound entity conformant. An organisation awaiting purge is left aside and named. The build runs it for every organisation, last.', true, 90)
on conflict (code) do update
  set title = excluded.title, function_name = excluded.function_name, arguments = excluded.arguments,
      detail_function = excluded.detail_function, blurb = excluded.blurb, seq = excluded.seq;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The suite sees the rule
-- ═════════════════════════════════════════════════════════════════════════════

do $suite$
declare
  v_def text;
  v_new text;
begin
  v_def := pg_get_functiondef('erp_test.ci_coverage_suite()'::regprocedure);

  -- The new case goes in ahead of the last one, which checks that every
  -- falsification was undone, and that check learns the new tenant's name.
  v_new := replace(v_def,
$old$  -- 11. And the falsification was undone.
  v_cases := v_cases + 1;
  case_name := 'every falsification was undone';
  passed := not exists (select 1 from erp.tenant where code = 'zz-ci-coverage')$old$,
$new$  -- 10b. An organisation awaiting purge is left aside by name, not reconciled.
  -- Its unbalanced rule would fail the check if it were visited; the result
  -- must name it as skipped and must not name it as a finding.
  v_cases := v_cases + 1;
  v_msg := null;
  begin
    insert into erp.tenant (code, name, status, suspended_at, deleted_at)
    values ('zz-ci-purging', 'CI coverage suite, awaiting purge',
            'suspended'::erp.tenant_status, now(), now())
    returning id into v_tenant;
    insert into erp.posting_rule (tenant_id, code, event_type, posting_lines, status, effective_from)
    values (v_tenant, 'zz_unbalanced', 'goods_receipt',
            '[{"side":"debit","account":"1200","basis":"document_value","rate":1}]'::jsonb,
            'active', date '2020-01-01');
    begin
      v_msg := erp.assert_whole_database_reconciles();
    exception when others then v_msg := sqlerrm;
    end;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
  end;
  -- Named inside the skipped list whatever else is in it — on live another
  -- organisation may be awaiting purge beside this one — with a whole-number
  -- count in front, and not visited: a visited finding reads '  <code>: …'.
  case_name := 'an organisation awaiting purge is left aside by name rather than reconciled';
  passed := v_msg like '%awaiting purge skipped (%zz-ci-purging%)%'
        and v_msg ~ '\m[1-9][0-9]* awaiting purge skipped \('
        and v_msg not like '%zz-ci-purging: %';
  detail := v_msg;
  return next;

  -- 11. And the falsification was undone.
  v_cases := v_cases + 1;
  case_name := 'every falsification was undone';
  passed := not exists (select 1 from erp.tenant where code in ('zz-ci-coverage', 'zz-ci-purging'))$new$);

  if v_new = v_def then
    raise exception 'CLOVEERP_SUITE_UNRECOGNISED: erp_test.ci_coverage_suite() no longer carries the closing case this migration extends';
  end if;

  v_new := replace(v_new,
$old$  if v_cases <> 11 then
    raise exception 'CLOVEERP_SUITE_SHRANK: ci_coverage_suite ran % cases, expected 11', v_cases;
  end if;$old$,
$new$  if v_cases <> 12 then
    raise exception 'CLOVEERP_SUITE_SHRANK: ci_coverage_suite ran % cases, expected 12', v_cases;
  end if;$new$);

  if position('expected 12' in v_new) = 0 then
    raise exception 'CLOVEERP_SUITE_UNRECOGNISED: erp_test.ci_coverage_suite() no longer pins its case count where this migration expects';
  end if;

  execute v_new;

  -- The wrapper pins the count again, from its live definition: 20260906050000
  -- rewrote it to the strict verdict form, and that form is what stays.
  v_def := pg_get_functiondef('erp_test.assert_ci_coverage_suite()'::regprocedure);
  v_new := replace(v_def,
$old$  if v_all <> 11 then
    raise exception 'CLOVEERP_SUITE_SHRANK: ci_coverage_suite ran % cases, expected 11', v_all;
  end if;$old$,
$new$  if v_all <> 12 then
    raise exception 'CLOVEERP_SUITE_SHRANK: ci_coverage_suite ran % cases, expected 12', v_all;
  end if;$new$);

  if v_new = v_def then
    raise exception 'CLOVEERP_SUITE_UNRECOGNISED: erp_test.assert_ci_coverage_suite() no longer pins its case count where this migration expects';
  end if;

  execute v_new;
end
$suite$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_execute_grants();

select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp_test.assert_ci_coverage_suite();
-- The reconciliation itself is not run here. The suite above has just proved
-- the new rule; the deploy's prove step runs the check after every migration
-- has applied; and a migration that stepped around an organisation's books
-- should not itself refuse to apply on the state of those books.
