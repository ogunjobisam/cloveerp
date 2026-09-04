-- Three checks that could not be asked.
--
-- Verifying the demonstration's year on live, erp.platform_assurance() came
-- back with three checks failing — caller_reachable_internals,
-- authorise_codes_exist and single_administrator_live — each with the same
-- detail: syntax error at or near "{". The same three fail on a fresh build.
-- They have failed since the day they were registered.
--
-- Nothing is wrong with the checks. Called directly, all three pass: none of
-- 434 doors reaches platform-internal data as the caller, every gate names a
-- permission in the catalogue, no live organisation has a single
-- administrator. What is wrong is three rows in erp_meta.diagnostic_check.
-- The register holds each check's argument text and each detail report's
-- argument text, to be spliced into a call by erp.run_diagnostic():
--
--   execute format('select %I.%I(%s)::text', schema, function, arguments)
--
-- Fifty-four rows carry '' and one carries 'en'. These three carry '{}',
-- which reads as an empty array to the person who wrote it and as
-- erp.assert_authorise_codes_exist({}) to the parser. The register said the
-- checks were there, erp.assert_diagnostics_registered() agreed because it
-- resolves names and never looks at arguments, and the console has shown
-- three red rows over three green facts since this morning.
--
-- Two things, then. The three rows carry '' like the rest. And the
-- registration assertion asks the one question it did not: does each call
-- the register describes actually parse? The call is issued under WHERE
-- FALSE, which the planner folds away before anything is evaluated, so the
-- text is parsed and planned and the check itself never runs — cheap and
-- safe to ask of an assertion that would otherwise take seconds, and
-- permitted inside a STABLE function where EXPLAIN is not. The migration
-- proves the assertion catches the row it just repaired, by breaking one
-- again inside a sub-block and watching it refuse.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The rows
-- ═════════════════════════════════════════════════════════════════════════════

do $rows$
declare v_n integer;
begin
  update erp_meta.diagnostic_check set arguments = '' where arguments = '{}';
  get diagnostics v_n = row_count;
  if v_n <> 3 then
    raise exception
      'CLOVEERP_DIAGNOSTIC_REGISTER_UNRECOGNISED: expected three checks with ''{}'' '
      'for arguments, found %', v_n;
  end if;
  update erp_meta.diagnostic_check set detail_arguments = '' where detail_arguments = '{}';
  get diagnostics v_n = row_count;
  if v_n <> 3 then
    raise exception
      'CLOVEERP_DIAGNOSTIC_REGISTER_UNRECOGNISED: expected three checks with ''{}'' '
      'for detail arguments, found %', v_n;
  end if;
end
$rows$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The assertion asks whether each call parses
-- ═════════════════════════════════════════════════════════════════════════════

do $assert$
declare
  v_def  text;
  v_n1   text := $n$  if v_count > 0 then
    raise exception E'CLOVEERP_DIAGNOSTICS_UNREGISTERED: % finding(s)\n%',$n$;
  v_r1   text := $r$  -- 4. And every call the register describes parses. Three rows carried '{}'
  --    as their argument text, which the runner spliced into
  --    erp.assert_x({}), and every run of those three checks failed on a
  --    syntax error over a fact that was true. Under WHERE FALSE the call is
  --    parsed and planned and never evaluated, which is all that is needed
  --    to know it can be asked — and is allowed here, where EXPLAIN is not.
  for r in
    select d.code, d.schema_name, d.function_name, d.arguments,
           d.detail_function, d.detail_arguments
      from erp_meta.diagnostic_check d
     order by d.code
  loop
    begin
      execute format('select %I.%I(%s) where false', r.schema_name, r.function_name, r.arguments);
    exception when others then
      v_count := v_count + 1;
      v_findings := v_findings || format(
        E'  %s is registered as %s.%s(%s), which does not parse: %s\n',
        r.code, r.schema_name, r.function_name, r.arguments, sqlerrm);
    end;
    if r.detail_function is not null then
      begin
        execute format('select * from %I.%I(%s) t where false',
                       r.schema_name, r.detail_function, r.detail_arguments);
      exception when others then
        v_count := v_count + 1;
        v_findings := v_findings || format(
          E'  %s promises detail from %s.%s(%s), which does not parse: %s\n',
          r.code, r.schema_name, r.detail_function, r.detail_arguments, sqlerrm);
      end;
    end if;
  end loop;

  if v_count > 0 then
    raise exception E'CLOVEERP_DIAGNOSTICS_UNREGISTERED: % finding(s)\n%',$r$;
  v_hits integer;
begin
  v_def := pg_get_functiondef('erp.assert_diagnostics_registered()'::regprocedure);
  v_hits := (length(v_def) - length(replace(v_def, v_n1, ''))) / length(v_n1);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_DIAGNOSTIC_REGISTER_UNRECOGNISED: expected the refusal once in '
      'erp.assert_diagnostics_registered(), found %.', v_hits;
  end if;
  if position('where false' in v_def) > 0 then
    raise exception
      'CLOVEERP_DIAGNOSTIC_REGISTER_UNRECOGNISED: erp.assert_diagnostics_registered() '
      'already parses each call.';
  end if;
  execute replace(v_def, v_n1, v_r1);
end
$assert$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Proved here: the rows are right, the checks run, and the assertion would
--    have caught the rows
-- ═════════════════════════════════════════════════════════════════════════════

do $prove$
declare
  v_code text;
  v_res  jsonb;
begin
  if exists (select 1 from erp_meta.diagnostic_check
              where arguments = '{}' or detail_arguments = '{}') then
    raise exception 'CLOVEERP_DIAGNOSTIC_REGISTER_UNRECOGNISED: a row still carries ''{}''';
  end if;

  foreach v_code in array array['caller_reachable_internals', 'authorise_codes_exist',
                                'single_administrator_live']
  loop
    v_res := erp.run_diagnostic(v_code);
    if not (v_res ->> 'ok')::boolean then
      raise exception
        'CLOVEERP_DIAGNOSTIC_STILL_FAILS: % still fails when run from the register: %',
        v_code, left(v_res ->> 'detail', 200);
    end if;
  end loop;

  -- The falsification: break one row again, inside a sub-block, and the
  -- assertion has to refuse. The sub-block's exception undoes the break.
  begin
    update erp_meta.diagnostic_check set arguments = '{}' where code = 'single_administrator_live';
    perform erp.assert_diagnostics_registered();
    raise exception 'CLOVEERP_DIAGNOSTIC_REGISTER_UNGUARDED: a row with ''{}'' passed registration';
  exception when others then
    if sqlerrm not like 'CLOVEERP_DIAGNOSTICS_UNREGISTERED:%'
       or sqlerrm not like '%single_administrator_live%does not parse%' then
      raise;
    end if;
  end;

  if (select arguments from erp_meta.diagnostic_check where code = 'single_administrator_live') <> '' then
    raise exception 'CLOVEERP_DIAGNOSTIC_REGISTER_UNRECOGNISED: the falsification was not undone';
  end if;
end
$prove$;

select erp.assert_diagnostics_registered();
select erp.assert_no_legacy_refusal_prefix();

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
