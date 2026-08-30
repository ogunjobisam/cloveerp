import { createFileRoute } from "@tanstack/react-router";

import { Gate } from "../../components/erp/gate";
import { ModulePage } from "../../components/erp/module-page";
import { PLANNING } from "../../lib/modules";

export const Route = createFileRoute("/planning/")({
  head: () => ({
    meta: [
      { title: "Planning — ERPWare" },
      { name: "description", content: "Planned orders and planning exceptions, with the release dates that keep supply on time." },
      { property: "og:title", content: "Planning — ERPWare" },
      { property: "og:description", content: "Planned orders and planning exceptions, with the release dates that keep supply on time." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <ModulePage def={PLANNING} />
    </Gate>
  ),
});
