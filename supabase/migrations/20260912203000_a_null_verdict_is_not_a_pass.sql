-- Two suite wrappers count "not passed", which a NULL verdict walks through.
--
-- erp.assert_suite_verdicts_strict() named both of the document suites:
--
--   erp_test.assert_document_issue_suite
--   erp_test.assert_document_archive_authenticated_suite
--
-- Each counts its failures with count(*) filter (where not passed). In SQL,
-- "not null" is null, and a filter clause keeps only rows where the condition
-- is true — so a case that returns no verdict at all is counted as neither a
-- pass nor a failure, and the wrapper reports success. A suite that cannot
-- fail is not a suite. Both are the document work, and both would have gone
-- on saying 22/22 and 7/7 whatever happened inside them.
--
-- The total is still pinned, so a case that vanishes is still caught; this
-- closes the case that runs and answers nothing.

do $verdicts$
declare
  v_def text;
  v_new text;
begin
  v_def := pg_get_functiondef('erp_test.assert_document_issue_suite()'::regprocedure);
  v_new := replace(v_def, 'not r.passed', 'not coalesce(r.passed, false)');
  if v_new = v_def then
    raise exception 'CLOVEERP_VERDICT_COUNT_UNRECOGNISED: erp_test.assert_document_issue_suite() does not count "not r.passed"';
  end if;
  execute v_new;

  v_def := pg_get_functiondef('erp_test.assert_document_archive_authenticated_suite()'::regprocedure);
  v_new := replace(v_def, 'not s.passed', 'not coalesce(s.passed, false)');
  if v_new = v_def then
    raise exception 'CLOVEERP_VERDICT_COUNT_UNRECOGNISED: erp_test.assert_document_archive_authenticated_suite() does not count "not s.passed"';
  end if;
  execute v_new;
end
$verdicts$;

select erp.assert_suite_verdicts_strict();
