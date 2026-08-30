-- Pin the search path on the test procedure the linter flagged.
alter procedure erp_test.assert_context_not_leaked() set search_path = '';
