-- Rule H, advisory. The fixture catches where it stopped into v_state and the
-- count guard raises a bare number, so the one thing that says why never
-- reaches the build log.

create or replace function erp_test.preflight_fixture_guard_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 2;
  v_cases integer := 0;
  v_state text;
  v_step  text := 'starting';
begin
  begin
    v_step := 'the fixture does its work';
    v_cases := v_cases + 1;
    case_name := 'the work was done';
    passed := true;
    detail := 'it was';
    return next;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := v_state is null;
  detail := coalesce(v_state, 'it was');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_PREFLIGHT_FIXTURE_GUARD_SUITE_SHRANK: % case(s), expected %',
      v_cases, c_expected;
  end if;
end;
$$;
