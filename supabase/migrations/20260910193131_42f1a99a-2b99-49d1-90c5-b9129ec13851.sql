-- The stock forecast screen's own words, and its guidance.
-- Keyed by value: a phrase already on file keeps the key it has, so two
-- screens saying "Supplier" stay one glossary entry rather than two.

insert into erp_ref.resource (key, locale, value, module_code, description)
select v.key, 'en', v.value, v.module_code, v.description
  from (values
    ('nav.inventory_forecast', 'Stock forecast', null::text,
     'Navigation label for the screen showing usage, lead time and when to reorder.'),
    ('ui.stock_forecast_title', 'Stock forecast', 'inventory',
     'Heading of the stock forecast screen.'),
    ('ui.stock_forecast_header',
     'How fast each product has actually been going out, how long it takes to replace, and therefore when it has to be ordered. Days of cover is the balance divided by the daily usage; the reorder-by date is the day the balance reaches the reorder point, so ordering after it is late by definition. What is already on purchase order is counted, so a product waiting on a delivery is not ordered twice.',
     'inventory', 'The sentence under the stock forecast heading.'),
    ('ui.stock_forecast_what', 'What to order, and by when', 'inventory',
     'Heading of the main forecast table.'),
    ('ui.stock_forecast_what_desc',
     'Ordered by urgency. Where no reorder point has been set, the one the product''s own history implies is shown instead, so nothing is left unanswerable.',
     'inventory', 'Description of the main forecast table.'),
    ('ui.stock_forecast_what_empty',
     'Nothing to forecast yet. A product needs stock, a movement out, or a purchase order against it before there is anything to measure.',
     'inventory', 'Shown when there is nothing to forecast.'),
    ('ui.stock_forecast_why', 'How the figures were worked out', 'inventory',
     'Heading of the workings table.'),
    ('ui.stock_forecast_why_desc',
     'The same products with what sits behind the answer: the quantity measured, over how many days, the demand that falls inside the lead time, and the policy figures the organisation set.',
     'inventory', 'Description of the workings table.'),
    ('ui.stock_forecast_why_empty', 'Nothing measured yet, so there is nothing to explain.',
     'inventory', 'Shown when there are no workings to show.'),
    ('ui.stock_forecast_on_hand', 'On hand', 'inventory', 'Column: quantity standing in stock.'),
    ('ui.stock_forecast_on_order', 'On order', 'inventory',
     'Column: quantity on purchase orders not yet received.'),
    ('ui.stock_forecast_customer_demand', 'Ordered by customers', 'inventory',
     'Column: quantity on sales orders not yet despatched.'),
    ('ui.stock_forecast_per_day', 'Used per day', 'inventory',
     'Column: average quantity leaving stock each day.'),
    ('ui.stock_forecast_lead_time', 'Lead time', 'inventory',
     'Column: days between ordering and receiving.'),
    ('ui.stock_forecast_reorder_point', 'Reorder point', 'inventory',
     'Column: the balance at which the product must be reordered.'),
    ('ui.stock_forecast_days_cover', 'Days of cover', 'inventory',
     'Column: how many days the balance lasts at the current rate.'),
    ('ui.stock_forecast_order_by', 'Order by', 'inventory',
     'Column: the date the product has to be ordered by.'),
    ('ui.stock_forecast_order_quantity', 'Order quantity', 'inventory',
     'Column: the quantity suggested to bring the product back up to cover.'),
    ('ui.stock_forecast_used', 'Used', 'inventory',
     'Column: quantity that left stock over the window measured.'),
    ('ui.stock_forecast_over', 'Over', 'inventory',
     'Column: how many days the usage was measured over.'),
    ('ui.stock_forecast_lead_time_demand', 'Demand in the lead time', 'inventory',
     'Column: expected usage while a replacement order is in transit.'),
    ('ui.stock_forecast_safety_stock', 'Safety stock', 'inventory',
     'Column: the buffer held against variability.'),
    ('ui.stock_forecast_order_up_to', 'Order up to', 'inventory',
     'Column: the balance an order is intended to restore.'),
    ('ui.stock_forecast_minimum', 'Minimum', 'inventory',
     'Column: the smallest quantity the supplier will accept.'),
    ('ui.stock_forecast_multiple', 'Multiple', 'inventory',
     'Column: the pack multiple an order must be rounded to.'),
    ('ui.stock_forecast_state_out', 'out of stock', 'inventory',
     'State: nothing on hand and there is demand for it.'),
    ('ui.stock_forecast_state_order_now', 'order now', 'inventory',
     'State: the balance is at or below the reorder point.'),
    ('ui.stock_forecast_state_below_safety', 'below safety', 'inventory',
     'State: the balance has fallen into the safety buffer.'),
    ('ui.stock_forecast_state_covered', 'covered', 'inventory',
     'State: stock and orders cover expected usage.'),
    ('ui.stock_forecast_state_no_usage', 'no usage', 'inventory',
     'State: nothing has left stock over the window, so no rate can be measured.'),
    ('ui.stock_forecast_state_dormant', 'dormant', 'inventory',
     'State: no stock, no usage and nothing on order.')
  ) as v(key, value, module_code, description)
 where not exists (select 1 from erp_ref.resource r
                    where r.locale = 'en' and r.value = v.value)
   and not exists (select 1 from erp_ref.resource r
                    where r.locale = 'en' and r.key = v.key);

insert into erp_ref.help_topic (screen_path, nav_key, module_code, summary, steps, next_action, actions) values
  ('/inventory/forecast', 'nav.inventory_forecast', 'inventory',
   'The buying question answered in one row: what has been going out, how long a replacement takes, what is already on order, and therefore the date each product has to be ordered by and how much to buy. Usage is measured from movements rather than forecast — a demand plan is a separate instrument and lives in Planning.',
   '["Read the top of the list first. Out of stock and order now are the rows that cost money today.","Check the lead time. Where a product has none, set it against the product-supplier so the reorder-by date can be worked out.","Use the order quantity as the starting figure, then round it to the supplier''s minimum and pack multiple.","Raise the purchase order. Once it is sent it counts as on order here, so the product stops asking to be bought again.","Open the workings table when a figure looks wrong: it shows the quantity measured, the window, and the policy figures behind the answer."]',
   'Start with anything showing out of stock, then work down the reorder-by dates.',
   '{erp_calculate_policy,erp_apply_calculated_policy,erp_raise_replenishment_tasks}')
on conflict (screen_path) do update set
  nav_key = excluded.nav_key, module_code = excluded.module_code,
  summary = excluded.summary, steps = excluded.steps,
  next_action = excluded.next_action, actions = excluded.actions;
