-- The stock audit screen's own words, and its guidance.
--
-- Every string a screen shows has to have a row it can be renamed by, or the
-- terminology layer is claiming a renameability the code does not provide.
-- Keyed by value here: a word already on file keeps the key it has, so two
-- screens saying "Variance" stay one glossary entry rather than two.

insert into erp_ref.resource (key, locale, value, module_code, description)
select v.key, 'en', v.value, v.module_code, v.description
  from (values
    ('nav.inventory_audit', 'Stock audit', null::text,
     'Navigation label for the screen comparing book stock with what the last count found.'),
    ('ui.stock_audit_title', 'Stock audit', 'inventory', 'Heading of the stock audit screen.'),
    ('ui.stock_audit_by_location', 'Balances by location', 'inventory',
     'Heading of the per-location audit table.'),
    ('ui.stock_audit_by_product', 'Balances by product within a location', 'inventory',
     'Heading of the per-product audit table.'),
    ('ui.stock_audit_last_counted', 'Last counted', 'inventory',
     'Column: when the place was last counted.'),
    ('ui.stock_audit_count', 'Count', 'inventory', 'Column: the state of the last count.'),
    ('ui.stock_audit_variance_value', 'Variance value', 'inventory',
     'Column: what the counted difference is worth.'),
    ('ui.stock_audit_never_counted', 'never counted', 'inventory',
     'State: no count has ever been raised against this place.'),
    ('ui.stock_audit_agreed', 'agreed', 'inventory',
     'State: the last count matched the book.'),
    ('ui.stock_audit_counting', 'counting', 'inventory',
     'State: a count is open against this place.'),
    ('ui.stock_audit_variance', 'variance', 'inventory',
     'State: the last count differed from the book.'),
    ('ui.stock_audit_counting_bar', 'Counting', 'inventory',
     'Heading of the counting actions on the stock audit screen.'),
    ('ui.stock_audit_counting_note',
     'Raise tasks from a counting programme, record what was found, then post it. Posting is what moves the stock: until then the count is an observation, not a correction.',
     'inventory', 'Explanation under the counting actions.'),
    ('ui.stock_audit_raise_desc',
     'Ask a counting programme for its next set of places to count.', 'inventory',
     'What raising count tasks does.'),
    ('ui.stock_audit_record_desc',
     'What the counter found in the place. The variance is worked out from it.', 'inventory',
     'What recording a count does.'),
    ('ui.stock_audit_post_desc', 'Accept the difference and correct the stock by it.', 'inventory',
     'What posting a count does.'),
    ('ui.stock_audit_header',
     'What the book says is standing in each place, what it is worth, and what the last count actually found. A place nobody has counted shows as never counted rather than as agreement — an untested balance is not a verified one. Nothing here changes stock: post a count and the correction is made as a movement, with a reason.',
     'inventory', 'The sentence under the stock audit heading.'),
    ('ui.stock_audit_by_location_desc',
     'Every active place at every site, whether or not anything stands in it, with the last count against it.',
     'inventory', 'Description of the per-location audit table.'),
    ('ui.stock_audit_by_product_desc',
     'The same audit one line deeper: which product the quantity is, what it costs, and what the last count expected against what it found. Value in a bin is its share of the product''s valuation at that site, not a separate cost.',
     'inventory', 'Description of the per-product audit table.'),
    ('ui.stock_audit_by_location_empty',
     'No locations to audit yet. Add locations under Warehouse layout, and receive stock into them, and each one is listed here with its balance.',
     'inventory', 'Shown when no locations exist.'),
    ('ui.stock_audit_by_product_empty',
     'No stock standing anywhere and no counts raised. Receive a purchase order and put it away, and the lines appear here.',
     'inventory', 'Shown when nothing is on hand and nothing counted.')
  ) as v(key, value, module_code, description)
 where not exists (select 1 from erp_ref.resource r
                    where r.locale = 'en' and r.value = v.value)
   and not exists (select 1 from erp_ref.resource r
                    where r.locale = 'en' and r.key = v.key);

insert into erp_ref.help_topic (screen_path, nav_key, module_code, summary, steps, next_action, actions) values
  ('/inventory/audit', 'nav.inventory_audit', 'inventory',
   'The book beside the count. Every location with what is standing in it and what that is worth, when it was last counted, what the count found, and the difference — in quantity and in money. A place nobody has counted is shown as such rather than as agreement.',
   '["Read the balances by location. Never counted and variance are the two rows worth opening; agreed needs nothing from you.","Raise count tasks from a counting programme, or count a place because this screen told you to.","Record what the counter actually found. Nothing moves yet — the count is an observation.","Post the count to accept the difference. That is what corrects the stock, as a movement with a reason behind it.","Open the per-product table to see which product inside a bin the difference is in."]',
   'Start with the locations that have never been counted: an untested balance is the one most likely to be wrong.',
   '{erp_raise_count_tasks,erp_record_count,erp_post_count}')
on conflict (screen_path) do update set
  nav_key = excluded.nav_key, module_code = excluded.module_code,
  summary = excluded.summary, steps = excluded.steps,
  next_action = excluded.next_action, actions = excluded.actions;
