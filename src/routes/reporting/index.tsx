import { createFileRoute } from "@tanstack/react-router";

import { Gate } from "../../components/erp/gate";
import { ModulePage } from "../../components/erp/module-page";
import { REPORTING } from "../../lib/modules";

export const Route = createFileRoute("/reporting/")({
  head: () => ({
    meta: [
      { title: "Reporting — ERPWare" },
      { name: "description", content: "Data quality, duplicate candidates and specification coverage, read from operational tables." },
      { property: "og:title", content: "Reporting — ERPWare" },
      { property: "og:description", content: "Data quality, duplicate candidates and specification coverage, read from operational tables." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <ModulePage def={REPORTING} />
    </Gate>
  ),
});
