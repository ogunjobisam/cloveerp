import { createFileRoute } from "@tanstack/react-router";

import { AutoPanel, StatusPill, shortDate } from "../../components/erp/auto";
import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { useT } from "../../lib/i18n";

export const Route = createFileRoute("/inventory/")({
  head: () => ({
    meta: [
      { title: "Inventory — ERPWare" },
      {
        name: "description",
        content:
          "Stock health, valuation, ageing, expiry horizon, batches and count tasks, derived from the movement ledger.",
      },
      { property: "og:title", content: "Inventory — ERPWare" },
      {
        property: "og:description",
        content: "Stock health, valuation, ageing, expiry and counting, derived from the ledger.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <Inventory />
    </Gate>
  ),
});

function Inventory() {
  const { t } = useT();

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={t("module.inventory", "Inventory and warehouse")}>
        Every figure here is derived from the movement ledger. None of it is an editable balance,
        which is why a correction is a reversing movement rather than a new number.
      </PageHeader>

      <AutoPanel
        title="Stock health"
        description="Cover against policy, by item and site."
        fn="erp_stock_health"
        empty="No stock positions yet — nothing has moved into this tenant."
        rowKey={(r, i) => `${String(r["item_code"] ?? i)}-${String(r["site_code"] ?? i)}`}
        columns={[
          { header: "Item", cell: "item_code" },
          { header: "Site", cell: "site_code" },
          { header: "On hand", cell: "on_hand", numeric: true },
          { header: "Available", cell: "available", numeric: true },
          { header: "Allocated", cell: "allocated", numeric: true },
          { header: "Status", cell: (r) => <StatusPill value={r["health"] ?? r["status"]} /> },
        ]}
      />

      <AutoPanel
        title="Valuation"
        description="Reconcilable to the ledger by construction — same movements, same cost context."
        fn="erp_stock_valuation"
        empty="Nothing to value yet."
        rowKey={(r, i) => `${String(r["item_code"] ?? i)}-${i}`}
        columns={[
          { header: "Item", cell: "item_code" },
          { header: "Site", cell: "site_code" },
          { header: "Quantity", cell: "quantity", numeric: true },
          { header: "Value (minor)", cell: "value_minor", numeric: true },
          { header: "Currency", cell: "currency" },
        ]}
      />

      <AutoPanel
        title="Ageing"
        description="How long stock has been standing, in bands."
        fn="erp_stock_ageing"
        empty="No aged stock."
        rowKey={(r, i) => `${String(r["item_code"] ?? i)}-${i}`}
        columns={[
          { header: "Item", cell: "item_code" },
          { header: "Site", cell: "site_code" },
          { header: "Band", cell: "age_band" },
          { header: "Quantity", cell: "quantity", numeric: true },
        ]}
      />

      <AutoPanel
        title="Expiry horizon"
        description="Batches reaching expiry within thirty days."
        fn="erp_expiry_horizon"
        args={{ p_days: 30 }}
        empty="Nothing expires in the next thirty days."
        rowKey={(r, i) => `${String(r["batch_number"] ?? i)}-${i}`}
        columns={[
          { header: "Batch", cell: "batch_number" },
          { header: "Item", cell: "item_code" },
          { header: "Expires", cell: (r) => shortDate(r["expires_on"]) },
          { header: "Quantity", cell: "quantity", numeric: true },
          { header: "Days left", cell: "days_remaining", numeric: true },
        ]}
      />

      <AutoPanel
        title="Batches"
        description="Lot identity and its status lifecycle. Attributes are amendable without moving stock."
        fn="erp_batches"
        empty="No batches yet."
        rowKey={(r) => String(r["batch_id"])}
        columns={[
          { header: "Batch", cell: "batch_number" },
          { header: "Item", cell: "item" },
          { header: "Status", cell: (r) => <StatusPill value={r["status"]} /> },
          { header: "Made", cell: (r) => shortDate(r["manufactured_on"]) },
          { header: "Expires", cell: (r) => shortDate(r["expires_on"]) },
          { header: "Supplier lot", cell: "supplier_lot" },
        ]}
      />

      <AutoPanel
        title="Count tasks"
        description="Counting runs without freezing stock; committed quantity is excluded automatically."
        fn="erp_count_tasks"
        empty="No count tasks raised."
        rowKey={(r) => String(r["task_id"])}
        columns={[
          { header: "Item", cell: "item" },
          { header: "Location", cell: "location" },
          { header: "Expected", cell: "expected", numeric: true },
          { header: "Counted", cell: "counted", numeric: true },
          { header: "Variance", cell: "variance", numeric: true },
          { header: "Status", cell: (r) => <StatusPill value={r["status"]} /> },
        ]}
      />

      <AutoPanel
        title="Count accuracy"
        description="What the counting programme says about the reliability of the ledger."
        fn="erp_count_accuracy"
        empty="No counts posted yet, so accuracy cannot be stated."
        rowKey={(r, i) => `${String(r["programme_code"] ?? i)}-${i}`}
        columns={[
          { header: "Programme", cell: "programme_code" },
          { header: "Counted", cell: "tasks_counted", numeric: true },
          { header: "Within tolerance", cell: "within_tolerance", numeric: true },
          { header: "Accuracy %", cell: "accuracy_pct", numeric: true },
        ]}
      />
    </div>
  );
}
