-- A migration with nothing wrong with it. Every rule must stay quiet, which is
-- the half of the falsification that keeps the other half honest: a check that
-- refuses everything proves nothing by refusing.

create or replace function erp.preflight_fixture_clean()
returns text
language sql
stable
set search_path = ''
as $$
  select 'nothing to see here'
$$;

select erp.apply_execute_grants();
