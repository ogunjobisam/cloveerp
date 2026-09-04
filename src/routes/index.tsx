import { createFileRoute } from "@tanstack/react-router";
import { Sparkles } from "lucide-react";

import { FirstRun } from "../components/erp/first-run";
import { Gate } from "../components/erp/gate";
import { Launchpad } from "../components/erp/launchpad";
import { useErpSession } from "../components/erp/session-context";
import { PageHeader, Prose } from "../components/erp/page";
import { SeedDemoAction } from "../components/erp/seed";
import { useT } from "../lib/i18n";

/**
 * The Work area's home.
 *
 * Three things, in the order a person needs them: who and where they are,
 * their first steps if they have any left, and the flow of screens they may
 * open. The scope selectors live in the header, the permission list lives on
 * the permissions screen, and the settings live in their own area — none of
 * them is the reason somebody opens the product in the morning.
 */

export const Route = createFileRoute("/")({
  head: () => ({
    meta: [
      { title: "Clove ERP — Your work, one governed ledger" },
      {
        name: "description",
        content:
          "Sign in to Clove ERP: your organisation's finance, inventory and operations on one append-only, tenant-isolated ledger, with every action audited.",
      },
      { property: "og:title", content: "Clove ERP — Your work, one governed ledger" },
      {
        property: "og:description",
        content:
          "Finance, inventory and operations on one append-only, tenant-isolated ledger, with every action audited.",
      },
      { property: "og:type", content: "website" },
      { property: "og:url", content: "https://cloveerp.com/" },
      { property: "og:image", content: "https://cloveerp.com/og-image.png" },
      { name: "twitter:card", content: "summary_large_image" },
      { name: "twitter:image", content: "https://cloveerp.com/og-image.png" },
    ],
    links: [{ rel: "canonical", href: "https://cloveerp.com/" }],
  }),
  component: () => (
    <Gate>
      <Overview />
    </Gate>
  ),
});

/**
 * One-click exploration. Seeding creates a demo tenant — entities, sites, a
 * viewer principal, and the caller's administrator grant — and makes it the
 * working context, because the newest principal wins. Calling it again
 * returns the same tenant rather than piling up copies.
 */
function DemoSeed() {
  const { ui } = useT();
  return (
    <section className="rounded-2xl border border-dashed border-accent/40 bg-accent/5 p-4 sm:p-5">
      <div className="flex flex-col gap-4 md:flex-row md:items-center md:justify-between">
        <div className="flex min-w-0 items-start gap-3">
          <span className="grid size-9 shrink-0 place-items-center rounded-lg bg-accent/15 text-accent">
            <Sparkles className="size-4.5" />
          </span>
          <div className="min-w-0">
            <h2 className="font-display text-sm font-semibold">{ui("Explore with demo data")}</h2>
            <Prose className="mt-1 text-xs text-muted-foreground">
              {ui(
                "Creates a demo organisation with companies, sites and a viewer, and switches your working context to it. Your current organisation is untouched.",
              )}
            </Prose>
          </div>
        </div>
        <div className="shrink-0">
          <SeedDemoAction label="Seed a demo organisation" />
        </div>
      </div>
    </section>
  );
}

function Overview() {
  const { session, scope } = useErpSession();
  const { ui } = useT();

  const entity = session.entities.find((e) => e.id === scope.entityId);
  const site = session.sites.find((s) => s.id === scope.siteId);
  const where = [
    session.tenant?.name ?? "",
    entity ? `${entity.code} — ${entity.name}` : ui("All companies"),
    site ? `${site.code} — ${site.name}` : ui("All sites"),
  ]
    .filter(Boolean)
    .join(" · ");

  return (
    <div className="flex min-w-0 flex-col gap-8">
      <PageHeader
        title={`${ui("Welcome")}, ${
          session.principal?.given_name || session.principal?.display_name || ui("there")
        }`}
      >
        {where}
      </PageHeader>

      <FirstRun />

      <Launchpad />

      {!session.tenant?.code.startsWith("demo-") ? <DemoSeed /> : null}
    </div>
  );
}
