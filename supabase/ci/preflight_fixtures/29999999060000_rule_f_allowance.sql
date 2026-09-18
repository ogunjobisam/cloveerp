-- Rule F, the allowance half. A public door that is not STABLE may write, and
-- erp.assert_public_api_safe() refuses one that is on no write allow-list. It
-- has a home, so the other half stays quiet.

create or replace function public.erp_preflight_fixture_unlisted(p_note text)
returns text
language plpgsql
set search_path = ''
as $$
begin
  perform erp.authorise('administration.configure');
  return p_note;
end;
$$;

insert into erp_meta.api_only_door (function_name, caller, intended_screen_path, reason) values
  ('erp_preflight_fixture_unlisted', 'pending_screen', '/preflight',
   'A fixture with a home and no allowance.')
on conflict (function_name) do update set reason = excluded.reason;
