import { createFileRoute, redirect } from "@tanstack/react-router";

/**
 * Features and content are kept on Configuration (20261007180000).
 *
 * A feature switch and a pack only ever prepared a change, and Configuration
 * is where a change is approved and promoted, so this screen and that one were
 * two stops in the setup order for one sequence. Readiness, the Features and
 * Content packs tabs and their closing note moved there word for word, as the
 * first section, under the same doors and the same permissions, and still
 * shown read-only to whoever may not configure. The address stays, so a
 * bookmark or a link from elsewhere still lands on that section, and it keeps
 * its title for the moment before the redirect resolves.
 */
export const Route = createFileRoute("/administration/packs")({
  head: () => ({
    meta: [
      { title: "Features and content — Clove ERP" },
      {
        name: "description",
        content:
          "Product features and starter content packs, kept on Configuration with the changes they prepare.",
      },
      { property: "og:title", content: "Features and content — Clove ERP" },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  beforeLoad: () => {
    throw redirect({
      to: "/administration/configuration",
      hash: "features-and-content",
      replace: true,
    });
  },
});
