-- Rule B. The code is registered and raised only from a suite, which is exactly
-- where erp.refusal_report() does not look.

select erp.register_refusal(
  'CLOVEERP_PREFLIGHT_FIXTURE_UNRAISED',
  'a refusal nothing raises',
  'Registered here and raised nowhere the register reads.',
  'Raise it from the routine that refuses, or take the registration out.');

create or replace function erp_test.preflight_fixture_unraised_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
begin
  case_name := 'the refusal is raised'; passed := true; detail := 'here, and only here';
  return next;
  raise exception 'CLOVEERP_PREFLIGHT_FIXTURE_UNRAISED: raised in a suite and nowhere else';
end;
$$;
