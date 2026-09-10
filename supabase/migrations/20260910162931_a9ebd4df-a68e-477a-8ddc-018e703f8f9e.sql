-- The layout screen's own words.
--
-- A tile without a help topic ships with a help button that says there is no
-- guidance for this screen, and src/lib/guidance.test.ts fails for it before
-- that can happen. The screen added by the storage-rule migration is a tile,
-- so it gets its label and its topic here.

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('nav.inventory_warehouse', 'en', 'Warehouse layout', null,
   'Navigation label for the stock screen showing zones, aisles, bins and the storage rules that decide where a product belongs.')
on conflict (key, locale) do nothing;

insert into erp_ref.help_topic (screen_path, nav_key, module_code, summary, steps, next_action, actions) values
  ('/inventory/warehouse', 'nav.inventory_warehouse', 'inventory',
   'The shape of the warehouse: zones holding aisles holding bins, what each place holds and how often it is counted, and the storage rules that decide where a product is put away to and picked from.',
   '["Create the places: a goods-in location, zones, and the bins inside them. Give a bin a parent to nest it.","Say which places are pickable. A place that is not pickable is reserve — stock stands there, but pickers are not sent to it.","Add a storage rule for each product or product class: where it is put away to, and which face it is picked from.","Block a place while it is out of use; put-away and picking skip it and the stock in it stays put."]',
   'Add a put-away rule for your fastest-moving products first; everything else keeps today''s behaviour until you get to it.',
   '{erp_create_location,erp_create_storage_rule}')
on conflict (screen_path) do update set
  nav_key = excluded.nav_key, module_code = excluded.module_code,
  summary = excluded.summary, steps = excluded.steps,
  next_action = excluded.next_action, actions = excluded.actions;