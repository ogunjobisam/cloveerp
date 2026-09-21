-- A migration with nothing wrong with it. Every rule must stay quiet, which is
-- the half of the falsification that keeps the other half honest: a check that
-- refuses everything proves nothing by refusing.
--
-- It carries the two things rule J must not mistake for a bound over 255: a
-- bound at exactly 255, which PostgreSQL accepts, and an integer array literal
-- whose numbers are large and whose braces open the string.

create or replace function erp.preflight_fixture_clean()
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when 'x' ~ '^[a-z]{1,255}$' and cardinality('{300,4000}'::integer[]) = 2
      then 'nothing to see here'
  end
$$;

select erp.apply_execute_grants();
