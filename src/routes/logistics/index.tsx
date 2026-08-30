import { createFileRoute } from "@tanstack/react-router";

import { AutoPanel, StatusPill, shortDate } from "../../components/erp/auto";
import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { useT } from "../../lib/i18n";

export const Route = createFileRoute("/logistics/")({
  head: () => ({
    meta: [
      { title: "Logistics — ERPWare" },
      {
        name: "description",
        content:
          "Shipments, carrier bookings, delivery performance and landed cost allocation across sites.",
      },
      { property: "og:title", content: "Logistics — ERPWare" },
      {
        property: "og:description",
        content: "Shipments, carrier bookings, delivery performance and landed cost.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <Logistics />
    </Gate>
  ),
});

function Logistics() {
  const { t } = useT();

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={t("module.logistics", "Logistics")}>
        A shipment groups deliveries; a booking is an integration call with a result, not a text
        field. Cost lands back on the stock it belongs to.
      </PageHeader>

      <AutoPanel
        title="Shipments"
        description="Planned and despatched loads."
        fn="erp_shipments"
        empty="No shipments planned."
        rowKey={(r) => String(r["shipment_id"])}
        columns={[
          { header: "Reference", cell: "reference" },
          { header: "Carrier", cell: "carrier" },
          { header: "Service", cell: "service_code" },
          { header: "Planned", cell: (r) => shortDate(r["planned_despatch"]) },
          { header: "Actual", cell: (r) => shortDate(r["actual_despatch"]) },
          { header: "Tracking", cell: "tracking_reference" },
          { header: "Status", cell: (r) => <StatusPill value={r["status"]} /> },
        ]}
      />

      <AutoPanel
        title="Delivery performance"
        description="On time, in full, over the last ninety days."
        fn="erp_delivery_performance"
        args={{ p_days: 90 }}
        empty="No deliveries in the window."
        rowKey={(r, i) => `${String(r["party"] ?? r["site"] ?? i)}-${i}`}
        columns={[
          { header: "Customer", cell: "party" },
          { header: "Deliveries", cell: "deliveries", numeric: true },
          { header: "On time", cell: "on_time", numeric: true },
          { header: "In full", cell: "in_full", numeric: true },
          { header: "OTIF %", cell: "otif_pct", numeric: true },
        ]}
      />
    </div>
  );
}
