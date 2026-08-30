import { createFileRoute } from "@tanstack/react-router";

import { AutoPanel, StatusPill, shortDate } from "../../components/erp/auto";
import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { useT } from "../../lib/i18n";

export const Route = createFileRoute("/production/")({
  head: () => ({
    meta: [
      { title: "Production — ERPWare" },
      {
        name: "description",
        content:
          "Works orders, operation progress and batch records, from release through to close and variance.",
      },
      { property: "og:title", content: "Production — ERPWare" },
      {
        property: "og:description",
        content: "Works orders, operations and batch records with close-out variance.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <Production />
    </Gate>
  ),
});

function Production() {
  const { t } = useT();

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={t("module.production", "Production")}>
        A works order is a document like any other: it has a state machine, an audit trail, and a
        close that produces variance rather than silence.
      </PageHeader>

      <AutoPanel
        title="Works orders"
        description="Released and in-progress orders across sites."
        fn="erp_works_orders"
        empty="No works orders raised."
        rowKey={(r) => String(r["works_order_id"])}
        columns={[
          { header: "Number", cell: "order_number" },
          { header: "Item", cell: "item" },
          { header: "Site", cell: "site" },
          { header: "Kind", cell: "order_kind" },
          { header: "Ordered", cell: "quantity", numeric: true },
          { header: "Completed", cell: "quantity_completed", numeric: true },
          { header: "Scrapped", cell: "quantity_scrapped", numeric: true },
          { header: "Due", cell: (r) => shortDate(r["planned_end"]) },
          { header: "Status", cell: (r) => <StatusPill value={r["status"]} /> },
        ]}
      />

      <AutoPanel
        title="Operation progress"
        description="Booked time against standard, by operation."
        fn="erp_operation_progress"
        empty="No time booked."
        rowKey={(r, i) => `${String(r["works_order"] ?? i)}-${String(r["operation_seq"] ?? i)}`}
        columns={[
          { header: "Works order", cell: "works_order" },
          { header: "Seq", cell: "operation_seq", numeric: true },
          { header: "Operation", cell: "operation" },
          { header: "Minutes", cell: "minutes_booked", numeric: true },
          { header: "Completed", cell: "quantity_completed", numeric: true },
          { header: "Status", cell: (r) => <StatusPill value={r["status"]} /> },
        ]}
      />
    </div>
  );
}
