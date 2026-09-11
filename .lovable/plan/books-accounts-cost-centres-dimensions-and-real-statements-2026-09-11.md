# Books: accounts, cost centres, dimensions and real statements

## What exists already

The ledger machinery is largely built: a chart of accounts per company, account
determination rules per transaction type, analysis dimensions with derivation
rules, and journals that already carry a dimensions field on every line.
Purchases, goods receipts, despatches, invoices and cash already post.

Three real gaps:

1. **Nothing fills the dimensions.** Every posted line so far carries an empty
   analysis, because no cost centre exists and the one demo dimension derives
   from a field nobody fills.
2. **Clove Foods has no determination rules and no posting classes**, so
   supplier invoices and sales invoices refuse to post for that company.
3. **There are no financial statements.** Only a trial balance exists — no
   profit and loss, no balance sheet.

## What I will build

### 1. Cost centres as a first-class thing

- A `COST_CENTRE` dimension seeded for each company, derived automatically from
  the document's site, then its department, then the company default — so a
  purchase, a stock movement or a sales invoice lands on a cost centre without
  anyone typing one.
- Cost centre values seeded from existing sites and departments, plus a
  screen to add, rename, retire and re-parent them.
- An `ANALYSIS`-style second dimension (product class) kept optional.
- Where a cost centre is mandatory, posting refuses with wording that names the
  missing analysis and where to set it.

### 2. Complete the chart and the determination for Clove Foods

- Add the missing accounts (bank, operating expenses, wages, freight, discounts,
  retained earnings, suspense) so the chart covers a full profit and loss and
  balance sheet.
- Seed the account determination rules for all twenty transaction types, plus
  default item and party posting classes, so supplier invoices, sales invoices,
  stock adjustments and payments all post rather than refusing.

### 3. Profit and loss, and balance sheet

- New governed routines producing, from posted journals only:
  - profit and loss for a period, with comparative prior period and
    year-to-date, grouped revenue / cost of sales / gross profit / overheads /
    operating profit;
  - balance sheet as at a date, grouped fixed assets / current assets /
    current liabilities / net assets / capital and reserves, including the
    retained result for the year so it balances;
  - both filterable by company, ledger, site and cost centre.
- A **Finance → Statements** screen presenting them properly: period picker,
  cost-centre filter, grouped rows with subtotals, positive/negative colouring,
  a balance check line, and a per-account drill to the journals behind a figure.
- Trial balance gains the same period and cost-centre filters.

### 4. Proof

- Assertions in the same migrations: every posting carries a cost centre where
  one is mandatory; balance sheet net assets equal capital and reserves; profit
  and loss result equals the movement on the reserves account; determination
  covers every transaction type for every company.
- Then a Clove Foods walkthrough: purchase order → receipt → supplier invoice →
  despatch → sales invoice, checking the statements move by the right amounts.

## Technical notes

Forward-only migrations under `supabase/migrations/`, each registering its own
governance and re-running the generators. New public wrappers
`erp_profit_and_loss`, `erp_balance_sheet`, `erp_cost_centres`,
`erp_upsert_cost_centre`, plus period/cost-centre arguments on
`erp_trial_balance`. UI in `src/routes/finance/statements.tsx` and
`src/routes/finance/cost-centres.tsx`, wired into `src/lib/modules.tsx`.
Checked with `bun run typecheck`, `bun run lint`, `bun run test`, `bun run build`.
