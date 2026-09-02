import { createFileRoute } from "@tanstack/react-router";

import { Gate } from "../../components/erp/gate";
import { ModulePage } from "../../components/erp/module-page";
import { PRODUCTION } from "../../lib/modules";

export const Route = createFileRoute("/production/")({
  head: () => ({
    meta: [
      { title: "Manufacturing — Clove ERP" },
      {
        name: "description",
        content:
          "Works orders and their progress against plan, including completed and scrapped quantity.",
      },
      { property: "og:title", content: "Manufacturing — Clove ERP" },
      {
        property: "og:description",
        content:
          "Works orders and their progress against plan, including completed and scrapped quantity.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <ModulePage def={PRODUCTION} />
    </Gate>
  ),
});
