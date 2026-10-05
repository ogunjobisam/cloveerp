import { createFileRoute, redirect } from "@tanstack/react-router";

/**
 * Cost centres are kept on Extra reporting tags (20261007170000).
 *
 * A cost centre is the COST_CENTRE reporting tag, and this screen and that one
 * were two stops in the setup order for one question: what a posting is
 * analysed by. The "Maintain cost centres" action and the "Cost centres" panel
 * moved there word for word, under the same doors and the same permissions.
 * The address stays, so a bookmark or a link from elsewhere still lands, and it
 * keeps its title for the moment before the redirect resolves.
 */
export const Route = createFileRoute("/finance/cost-centres")({
  head: () => ({
    meta: [
      { title: "Cost centres — Clove ERP" },
      {
        name: "description",
        content:
          "The cost centres every posting is analysed by, kept with the other reporting tags.",
      },
      { property: "og:title", content: "Cost centres — Clove ERP" },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  beforeLoad: () => {
    throw redirect({ to: "/finance/dimensions", replace: true });
  },
});
