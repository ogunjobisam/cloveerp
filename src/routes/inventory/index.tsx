import { createFileRoute } from "@tanstack/react-router";

import { Gate } from "../../components/erp/gate";
import { ModulePage } from "../../components/erp/module-page";
import { INVENTORY } from "../../lib/modules";

export const Route = createFileRoute("/inventory/")({
  head: () => ({
    meta: [
      { title: "Inventory — ERPWare" },
      { name: "description", content: "Stock health, valuation, ageing, expiry horizon, batches and count tasks, derived from the movement ledger." },
      { property: "og:title", content: "Inventory — ERPWare" },
      { property: "og:description", content: "Stock health, valuation, ageing, expiry horizon, batches and count tasks, derived from the movement ledger." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <ModulePage def={INVENTORY} />
    </Gate>
  ),
});
