-- Rule C. The door is registered as gated by erp.authorise and its body never
-- calls it, nor names the erp function that would. erp.public_api_report() asks
-- exactly this question of prosrc and refuses.

create or replace function public.erp_preflight_fixture_ungated(p_note text)
returns text
language plpgsql
set search_path = ''
as $$
begin
  insert into erp.preflight_fixture_note (note) values (p_note);
  return p_note;
end;
$$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_preflight_fixture_ungated', 'erp.authorise',
   'A fixture door registered against a gate it does not call.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

insert into erp_meta.api_only_door (function_name, caller, intended_screen_path, reason) values
  ('erp_preflight_fixture_ungated', 'pending_screen', '/preflight',
   'A fixture. It has a home so that rule F stays quiet and rule C is the only one speaking.')
on conflict (function_name) do update set reason = excluded.reason;
