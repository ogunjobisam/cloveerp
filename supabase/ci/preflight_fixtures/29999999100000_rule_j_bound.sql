-- Rule J. Three regular expressions whose repetition bound is over 255, one of
-- each shape PostgreSQL refuses — {n,m}, {n} and {n,} — inside a language sql
-- body that the parse treats as a string and never reads. The function is
-- created without complaint and raises the first time it runs.

create or replace function erp.preflight_fixture_bound()
returns boolean
language sql
stable
set search_path = ''
as $$
  select 'x' ~ '\M[^;]{0,800}'
      or 'x' ~ '^a{300}$'
      or 'x' ~ '(ab){256,}'
$$;

select erp.apply_execute_grants();
