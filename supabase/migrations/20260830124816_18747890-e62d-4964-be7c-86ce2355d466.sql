insert into erp_ref.resource (key, locale, value, description) values
  ('nav.enter_company','en','Enter a company (recorded)','Account menu')
on conflict (key, locale) do nothing;

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v), 'en', v, 'Interface wording'
  from unnest(array[
    'Actions','Ask','Ask a question','Asking…','Cancel','Choose…','Dashboard','Home','Loading…',
    'Reports','Work','Working…','Plan','Source','Make','Move','Sell','Settle','Govern & assure',
    'Administration','On','Days','Available to promise',
    'What can still be committed for one item at one site, on a date.','Batch genealogy',
    'Everything one batch touched — what it was made from and where it went.',
    'Temperature excursion impact',
    'What stock was standing in a place between two times, so an excursion can be scoped.',
    'Date and time, e.g. 2026-08-30 06:00','Date and time, e.g. 2026-08-30 18:00',
    'Redistribution suggestions','Where slow stock at one site would sell at another.','Default 60.',
    'Credit position','Limit, exposure and what is left for one customer.','Budget position',
    'Budget against actual for one budget code.','Supply and demand',
    'The projected balance for one item and site across the horizon.','Calculated stocking policy',
    'What the engine would set for one item and site, before adopting it.','Component availability',
    'Whether one works order can be released against what is on hand.','Works order','Recall',
    'Works order variance','Planned against actual materials and time, once it has run.',
    'Batch record','The manufacturing record for one works order, as issued.','Recall readiness',
    'Whether the trace for a recall can be produced inside the regulatory clock.','Recall evidence',
    'The trace and the actions logged against one recall.'
  ]) as v
on conflict (key, locale) do nothing;