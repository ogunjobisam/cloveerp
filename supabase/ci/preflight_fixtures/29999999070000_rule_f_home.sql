-- Rule F, the home half. No screen in src names this door and no row claims it
-- for a caller, so erp.assert_doors_have_a_home() refuses with
-- CLOVEERP_DOOR_HAS_NO_HOME. It calls the gate it declares and is on the
-- allow-list, so C and the other half of F stay quiet.

create or replace function public.erp_preflight_fixture_homeless(p_note text)
returns text
language plpgsql
set search_path = ''
as $$
begin
  perform erp.authorise('administration.configure');
  return p_note;
end;
$$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_preflight_fixture_homeless', 'erp.authorise',
   'A fixture door with an allowance and nowhere to live.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;
