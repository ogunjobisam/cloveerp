-- Rule G, advisory. A module installer that grows by a posting rule moves every
-- total another suite wrote down as a literal. Preflight cannot know the new
-- number; it names the places that carry the old one, and exits zero.

insert into erp_ref.module_upgrade_item
  (install_code, to_version, object_kind, object_key, payload, seq)
values
  ('sales-lifecycle', 99, 'posting_rule', 'preflight_fixture_rule',
   jsonb_build_object('code', 'preflight_fixture_rule'), 100)
on conflict do nothing;
