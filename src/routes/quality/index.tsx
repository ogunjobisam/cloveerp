import { createFileRoute } from "@tanstack/react-router";

import { Gate } from "../../components/erp/gate";
import { ModulePage } from "../../components/erp/module-page";
import { QUALITY } from "../../lib/modules";

export const Route = createFileRoute("/quality/")({
  head: () => ({
    meta: [
      { title: "Quality control — Clove ERP" },
      {
        name: "description",
        content:
          "Quality events, dispositions, supplier qualification and recalls against a regulatory clock.",
      },
      { property: "og:title", content: "Quality control — Clove ERP" },
      {
        property: "og:description",
        content:
          "Quality events, dispositions, supplier qualification and recalls against a regulatory clock.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <ModulePage def={QUALITY} />
    </Gate>
  ),
});
