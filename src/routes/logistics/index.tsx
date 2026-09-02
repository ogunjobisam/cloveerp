import { createFileRoute } from "@tanstack/react-router";

import { Gate } from "../../components/erp/gate";
import { ModulePage } from "../../components/erp/module-page";
import { LOGISTICS } from "../../lib/modules";

export const Route = createFileRoute("/logistics/")({
  head: () => ({
    meta: [
      { title: "Logistics — Clove ERP" },
      {
        name: "description",
        content: "Shipments, carrier bookings and on-time-in-full delivery performance.",
      },
      { property: "og:title", content: "Logistics — Clove ERP" },
      {
        property: "og:description",
        content: "Shipments, carrier bookings and on-time-in-full delivery performance.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <ModulePage def={LOGISTICS} />
    </Gate>
  ),
});
