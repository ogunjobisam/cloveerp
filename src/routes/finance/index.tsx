import { createFileRoute } from "@tanstack/react-router";

import { AutoPanel, StatusPill, shortDate } from "../../components/erp/auto";
import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { useT } from "../../lib/i18n";

export const Route = createFileRoute("/finance/")({
  head: () => ({
    meta: [
      { title: "Finance — ERPWare" },
      {
        name: "description",
        content:
          "Trial balance, ledgers, period control, receivables ageing, dunning, tax, fixed assets and intercompany position.",
      },
      { property: "og:title", content: "Finance — ERPWare" },
      {
        property: "og:description",
        content: "Trial balance, period control, receivables, tax and intercompany position.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <Finance />
    </Gate>
  ),
});

function Finance() {
  const { t } = useT();
  const from = new Date(new Date().getFullYear(), 0, 1).toISOString().slice(0, 10);
  const to = new Date().toISOString().slice(0, 10);

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={t("module.finance", "Finance")}>
        Every posting traces to an operational event and the version of the rule that produced it.
        Nothing here is keyed in.
      </PageHeader>

      <AutoPanel
        title="Trial balance"
        description="By ledger and currency. It balances, or the posting that broke it was refused."
        fn="erp_trial_balance"
        empty="Nothing posted yet."
        rowKey={(r, i) => `${String(r["ledger"])}-${String(r["account"])}-${i}`}
        columns={[
          { header: "Ledger", cell: "ledger" },
          { header: "Account", cell: "account" },
          { header: "Name", cell: "name" },
          { header: "Type", cell: "account_type" },
          { header: "Debit", cell: "debit_minor", numeric: true },
          { header: "Credit", cell: "credit_minor", numeric: true },
          { header: "Balance", cell: "balance_minor", numeric: true },
        ]}
      />

      <AutoPanel
        title="Ledgers"
        description="Parallel ledgers — statutory, group, tax, management — each with its own rules."
        fn="erp_ledgers"
        empty="No ledger configured. Installing the finance module is what creates one."
        rowKey={(r) => String(r["ledger_id"])}
        columns={[
          { header: "Code", cell: "code" },
          { header: "Name", cell: "name" },
          { header: "Kind", cell: "kind" },
          { header: "Currency", cell: "currency" },
          { header: "Primary", cell: "is_primary" },
          { header: "Status", cell: (r) => <StatusPill value={r["status"]} /> },
        ]}
      />

      <AutoPanel
        title="Periods"
        description="A closed period cannot be posted to without an explicit reopening event."
        fn="erp_fiscal_periods"
        empty="No fiscal calendar yet."
        rowKey={(r) => String(r["fiscal_period_id"])}
        columns={[
          { header: "Period", cell: "code" },
          { header: "Ledger", cell: "ledger" },
          { header: "Year", cell: "fiscal_year", numeric: true },
          { header: "Starts", cell: (r) => shortDate(r["starts_on"]) },
          { header: "Ends", cell: (r) => shortDate(r["ends_on"]) },
          { header: "Status", cell: (r) => <StatusPill value={r["status"]} /> },
        ]}
      />

      <AutoPanel
        title="Receivables ageing"
        description="What is owed, by how long it has been owed."
        fn="erp_receivables_ageing"
        empty="Nothing outstanding."
        rowKey={(r, i) => `${String(r["party"] ?? i)}-${i}`}
        columns={[
          { header: "Customer", cell: "party" },
          { header: "Currency", cell: "currency" },
          { header: "Current", cell: "current_minor", numeric: true },
          { header: "1–30", cell: "days_1_30_minor", numeric: true },
          { header: "31–60", cell: "days_31_60_minor", numeric: true },
          { header: "60+", cell: "days_60_plus_minor", numeric: true },
          { header: "Total", cell: "total_minor", numeric: true },
        ]}
      />

      <AutoPanel
        title="Dunning worklist"
        description="Who to chase, and on what basis."
        fn="erp_dunning_worklist"
        empty="Nobody needs chasing."
        rowKey={(r, i) => `${String(r["party"] ?? i)}-${i}`}
        columns={[
          { header: "Customer", cell: "party" },
          { header: "Overdue", cell: "overdue_minor", numeric: true },
          { header: "Oldest", cell: (r) => shortDate(r["oldest_due_date"]) },
          { header: "Stage", cell: "dunning_stage" },
        ]}
      />

      <AutoPanel
        title="Goods received not invoiced"
        description="Receipts with no matching invoice, aged."
        fn="erp_grni"
        empty="Nothing received awaiting an invoice."
        rowKey={(r, i) => `${String(r["document_number"] ?? i)}-${i}`}
        columns={[
          { header: "Receipt", cell: "document_number" },
          { header: "Supplier", cell: "party" },
          { header: "Item", cell: "item_code" },
          { header: "Quantity", cell: "quantity_open", numeric: true },
          { header: "Value", cell: "value_minor", numeric: true },
          { header: "Age (days)", cell: "age_days", numeric: true },
        ]}
      />

      <AutoPanel
        title="Tax report"
        description="This calendar year to date, as determined at transaction time."
        fn="erp_tax_report"
        args={{ p_from: from, p_to: to }}
        empty="No taxable transactions in this period."
        rowKey={(r, i) => `${String(r["tax_code"] ?? i)}-${i}`}
        columns={[
          { header: "Code", cell: "tax_code" },
          { header: "Rate %", cell: "rate_pct", numeric: true },
          { header: "Net", cell: "net_minor", numeric: true },
          { header: "Tax", cell: "tax_minor", numeric: true },
          { header: "Currency", cell: "currency" },
        ]}
      />

      <AutoPanel
        title="Fixed assets"
        description="The register as at today."
        fn="erp_fixed_asset_register"
        empty="No fixed assets recorded."
        rowKey={(r, i) => `${String(r["asset_code"] ?? i)}-${i}`}
        columns={[
          { header: "Asset", cell: "asset_code" },
          { header: "Name", cell: "name" },
          { header: "Cost", cell: "cost_minor", numeric: true },
          { header: "Depreciation", cell: "accumulated_depreciation_minor", numeric: true },
          { header: "Net book value", cell: "net_book_value_minor", numeric: true },
        ]}
      />

      <AutoPanel
        title="Intercompany position"
        description="What each entity owes another, before elimination."
        fn="erp_intercompany_position"
        empty="No intercompany balances."
        rowKey={(r, i) => `${String(r["from_entity"] ?? i)}-${String(r["to_entity"] ?? i)}-${i}`}
        columns={[
          { header: "From", cell: "from_entity" },
          { header: "To", cell: "to_entity" },
          { header: "Currency", cell: "currency" },
          { header: "Balance", cell: "balance_minor", numeric: true },
          { header: "Matched", cell: "is_matched" },
        ]}
      />
    </div>
  );
}
