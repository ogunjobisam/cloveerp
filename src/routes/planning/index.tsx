import { createFileRoute } from "@tanstack/react-router";

import { AutoPanel, StatusPill, shortDate } from "../../components/erp/auto";
import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { useT } from "../../lib/i18n";

export const Route = createFileRoute("/planning/")({
  head: () => ({
    meta: [
      { title: "Planning — ERPWare" },
      {
        name: "description",
        content:
          "Planned orders, planning exceptions and the planner workbench, with the reasoning behind each suggestion.",
      },
      { property: "og:title", content: "Planning — ERPWare" },
      {
        property: "og:description",
        content: "Planned orders, exceptions and the planner workbench.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <Planning />
    </Gate>
  ),
});

function Planning() {
  const { t } = useT();

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={t("module.planning", "Planning")}>
        Planning proposes; it does not commit. Every suggestion carries the demand, the policy and
        the lead time that produced it, so it can be argued with.
      </PageHeader>

      <AutoPanel
        title="Planning exceptions"
        description="What the planner should look at first, and why."
        fn="erp_planning_exceptions"
        empty="No exceptions — the plan is currently consistent."
        rowKey={(r) => String(r["exception_id"])}
        columns={[
          { header: "Item", cell: "item" },
          { header: "Site", cell: "site" },
          { header: "Kind", cell: "exception_kind" },
          { header: "Severity", cell: (r) => <StatusPill value={r["severity"]} /> },
          { header: "Message", cell: "message" },
          { header: "Acknowledged", cell: "is_acknowledged" },
        ]}
      />

      <AutoPanel
        title="Planned orders"
        description="Proposals awaiting conversion into works or purchase orders."
        fn="erp_planned_orders"
        empty="No planned orders. Nothing is short against current demand."
        rowKey={(r) => String(r["planned_order_id"])}
        columns={[
          { header: "Item", cell: "item" },
          { header: "Site", cell: "site" },
          { header: "Kind", cell: "order_kind" },
          { header: "Quantity", cell: "quantity", numeric: true },
          { header: "Required", cell: (r) => shortDate(r["required_on"]) },
          { header: "Release", cell: (r) => shortDate(r["release_on"]) },
          { header: "Status", cell: (r) => <StatusPill value={r["status"]} /> },
        ]}
      />

      <AutoPanel
        title="Demand signals"
        description="What the plan is answering: orders, forecast and dependent demand."
        fn="erp_demand_signals"
        empty="No demand recorded."
        rowKey={(r, i) => `${String(r["item"] ?? i)}-${i}`}
        columns={[
          { header: "Item", cell: "item" },
          { header: "Site", cell: "site" },
          { header: "Source", cell: "source" },
          { header: "Quantity", cell: "quantity", numeric: true },
          { header: "Due", cell: (r) => shortDate(r["due_on"]) },
        ]}
      />

      <AutoPanel
        title="Supply commitments"
        description="What is already inbound against that demand."
        fn="erp_supply_commitments"
        empty="Nothing inbound."
        rowKey={(r, i) => `${String(r["item"] ?? i)}-${i}`}
        columns={[
          { header: "Item", cell: "item" },
          { header: "Site", cell: "site" },
          { header: "Source", cell: "source" },
          { header: "Quantity", cell: "quantity", numeric: true },
          { header: "Expected", cell: (r) => shortDate(r["expected_on"]) },
        ]}
      />
    </div>
  );
}
