import { createFileRoute } from "@tanstack/react-router";

import { Gate } from "../../components/erp/gate";
import { ModulePage } from "../../components/erp/module-page";
import { FINANCE } from "../../lib/modules";

export const Route = createFileRoute("/finance/")({
  head: () => ({
    meta: [
      { title: "Finance — ERPWare" },
      { name: "description", content: "Trial balance, fiscal periods, receivables ageing, dunning, tax and fixed assets from the posted ledger." },
      { property: "og:title", content: "Finance — ERPWare" },
      { property: "og:description", content: "Trial balance, fiscal periods, receivables ageing, dunning, tax and fixed assets from the posted ledger." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <ModulePage def={FINANCE} />
    </Gate>
  ),
});
