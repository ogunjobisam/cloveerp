set lock_timeout = '30s';

insert into erp_ref.help_topic (screen_path, nav_key, module_code, summary, steps, next_action, actions) values
  ('/finance/statements', 'nav.finance_statements', 'finance',
   'The two readings everyone asks for, taken straight from the journals that purchases, goods receipts, deliveries and invoices have already posted: what the period made, and what the organisation is worth on a date. Both can be narrowed to a single cost centre.',
   '["Set the period. The balance sheet uses the second date as its as-at date.","Read the result at the foot of the profit and loss; it is income less cost of sales and expenses.","Check the balance badge on the balance sheet. It carries the result to date, so it balances without a year-end entry.","Pick a cost centre to see one site or department on its own.","Open the account detail when a total looks wrong: it shows every account that moved, with its debits and credits."]',
   'Start with the year to date, then narrow to a cost centre once the totals look right.',
   '{erp_profit_and_loss,erp_balance_sheet,erp_trial_balance}'),
  ('/finance/cost-centres', 'nav.finance_cost_centres', 'finance',
   'The list of cost centres postings are analysed by. Nobody types one on a document: the value is derived from the document''s own cost centre, then its department, then the site it happened at. Every site and department already set up appears here.',
   '["Add the cost centres this organisation reports on. Use the same code as the site or department where one maps to it.","Group several under a parent where you report on the heading rather than the parts.","Retire one by setting it inactive. The postings that already carry it keep it.","Read the posted-lines column to see which cost centres the books are actually using.","Go to the profit and balance sheet to read results for one of them."]',
   'Check every site and department has a cost centre, then read the statements for one.',
   '{erp_cost_centres,erp_upsert_cost_centre}')
on conflict (screen_path) do update set
  nav_key = excluded.nav_key, module_code = excluded.module_code,
  summary = excluded.summary, steps = excluded.steps,
  next_action = excluded.next_action, actions = excluded.actions;