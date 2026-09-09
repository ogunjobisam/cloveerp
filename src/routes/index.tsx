import { ClientOnly, Navigate, createFileRoute } from "@tanstack/react-router";
import { Sparkles } from "lucide-react";

import { FirstRun } from "../components/erp/first-run";
import { Gate } from "../components/erp/gate";
import { hasStoredSession } from "../lib/erp";
import { Launchpad } from "../components/erp/launchpad";
import { useErpSession } from "../components/erp/session-context";
import { PageHeader, Prose } from "../components/erp/page";
import { SeedDemoAction } from "../components/erp/seed";
import { useT } from "../lib/i18n";

/**
 * The Work area's home — and, for anybody else, the front door.
 *
 * Three things, in the order a person needs them: who and where they are,
 * their first steps if they have any left, and the flow of screens they may
 * open. The scope selectors live in the header, the permission list lives on
 * the permissions screen, and the settings live in their own area — none of
 * them is the reason somebody opens the product in the morning.
 *
 * A visitor with no session is not here for any of that, and used to get a
 * password box — or, on a build with no project configured, a message naming
 * two environment variables. They go to the product page instead, which needs
 * no database and is what the domain should answer with. Sign-in has its own
 * route now, linked from there.
 */

export const Route = createFileRoute("/")({
  head: () => ({
    meta: [
      { title: "Clove ERP — Your work, one governed ledger" },
      {
        name: "description",
        content:
          "Your organisation's finance, inventory and operations on one append-only, tenant-isolated ledger, with every action audited.",
      },
      // Neither a page to index nor a page to share: for a visitor this is a
      // redirect to the product page, and for everybody else it is their own
      // desk behind the gate. The product page carries the description, the
      // card and the canonical URL a link should resolve to.
      { name: "robots", content: "noindex, follow" },
    ],
    links: [{ rel: "canonical", href: "https://cloveerp.com/product" }],
  }),
  component: Home,
});

/**
 * The desk for somebody signed in, the product page for everybody else.
 *
 * `hasStoredSession()` is read rather than awaited because the decision has to
 * be made on the first paint: waiting would show a spinner to a visitor and a
 * marketing page to a colleague, each for a moment, and both are wrong.
 * Whether the stored session is any good is still `Gate`'s question, and it
 * still asks it.
 *
 * The decision is made after hydration rather than during it, and that is the
 * whole of what ClientOnly is doing here. The session lives in localStorage,
 * which the server cannot read, so the server always concluded "no session"
 * and the browser of anybody signed in concluded the opposite — two different
 * trees for the same route. React calls that a hydration mismatch, throws, and
 * regenerates the tree, which every signed-in visitor paid for on every visit
 * to the root. A browser test found it; nothing else could, because the server
 * and the client are each individually right.
 *
 * The fallback is nothing rather than a spinner. `/` is a fork in the road and
 * not a screen: it carries noindex and a canonical pointing at `/product`, so
 * the HTML it serves has no job beyond existing, and an empty first frame is
 * shorter than the regeneration it replaces.
 */
function Home() {
  return (
    <ClientOnly fallback={null}>
      <Fork />
    </ClientOnly>
  );
}

function Fork() {
  if (!hasStoredSession()) return <Navigate to="/product" replace />;
  return (
    <Gate>
      <Overview />
    </Gate>
  );
}

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
