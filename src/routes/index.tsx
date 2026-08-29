import { createFileRoute } from "@tanstack/react-router";

import { Gate, useErpSession } from "../components/erp/gate";
import { EmptyState, PageHeader, Prose } from "../components/erp/page";
import { SeedDemoAction } from "../components/erp/seed";

export const Route = createFileRoute("/")({
  head: () => ({
    meta: [{ title: "ERPWare" }],
  }),
  component: () => (
    <Gate>
      <Overview />
    </Gate>
  ),
});

function Field({ label, value }: { label: string; value: string }) {
  return (
    <div className="min-w-0">
      <dt className="text-xs font-medium uppercase tracking-wide text-muted-foreground">{label}</dt>
      <dd className="mt-0.5 truncate text-sm">{value}</dd>
    </div>
  );
}

/**
 * One-click exploration. Seeding creates a demo tenant — entities, sites, a
 * viewer principal, and the caller's administrator grant — and makes it the
 * working context, because the newest principal wins. Calling it again
 * returns the same tenant rather than piling up copies.
 */
function DemoSeed() {
  return (
    <section className="rounded-xl border border-dashed border-border bg-card/50 p-4 sm:p-5">
      <div className="flex flex-col gap-4 md:flex-row md:items-center md:justify-between">
        <div className="min-w-0">
          <h2 className="text-sm font-semibold">Explore with demo data</h2>
          <Prose className="mt-1 text-xs text-muted-foreground">
            Creates a demo tenant — two entities, three sites, a viewer principal — and switches
            your working context to it. Your current tenant is untouched.
          </Prose>
        </div>
        <div className="shrink-0">
          <SeedDemoAction label="Seed a demo tenant" />
        </div>
      </div>
    </section>
  );
}

function Overview() {
  const { session, scope } = useErpSession();

  const entity = session.entities.find((e) => e.id === scope.entityId);
  const site = session.sites.find((s) => s.id === scope.siteId);

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title="Overview">Where you are, and what this account may do.</PageHeader>

      <section className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5">
        <h2 className="text-sm font-semibold">Context</h2>
        {/* Stacked below md. Two columns on a 375px screen gave each field
            about 150px, which truncated every value that mattered. */}
        <dl className="mt-4 grid grid-cols-1 gap-4 md:grid-cols-4">
          <Field label="Tenant" value={session.tenant?.name ?? "—"} />
          <Field label="Principal" value={session.principal?.display_name ?? "—"} />
          <Field label="Entity" value={entity ? `${entity.code} — ${entity.name}` : "All"} />
          <Field label="Site" value={site ? `${site.code} — ${site.name}` : "All"} />
        </dl>
        <Prose className="mt-4 text-xs text-muted-foreground">
          The tenant is derived from your account, never chosen. Everything below is scoped to it by
          the database rather than by this page — narrowing entity or site changes what is shown,
          not what is permitted.
        </Prose>
      </section>

      <section className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5">
        <h2 className="text-sm font-semibold">Scope</h2>
        <div className="mt-3 grid grid-cols-1 gap-4 md:grid-cols-2">
          <div className="min-w-0">
            <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
              Entities ({session.entities.length})
            </p>
            {session.entities.length === 0 ? (
              <div className="mt-2">
                <EmptyState message="None configured yet." action={<SeedDemoAction />} />
              </div>
            ) : (
              <ul className="mt-2 flex flex-col gap-1 text-sm">
                {session.entities.map((e) => (
                  <li key={e.id} className="truncate">
                    <span className="font-mono text-xs text-muted-foreground">{e.code}</span>{" "}
                    {e.name}
                  </li>
                ))}
              </ul>
            )}
          </div>
          <div className="min-w-0">
            <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
              Sites ({session.sites.length})
            </p>
            {session.sites.length === 0 ? (
              <div className="mt-2">
                <EmptyState message="None configured yet." action={<SeedDemoAction />} />
              </div>
            ) : (
              <ul className="mt-2 flex flex-col gap-1 text-sm">
                {session.sites.map((s) => (
                  <li key={s.id} className="truncate">
                    <span className="font-mono text-xs text-muted-foreground">{s.code}</span>{" "}
                    {s.name}
                  </li>
                ))}
              </ul>
            )}
          </div>
        </div>
      </section>

      {!session.tenant?.code.startsWith("demo-") ? <DemoSeed /> : null}

      <section className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5">
        <h2 className="text-sm font-semibold">Permissions held ({session.permissions.length})</h2>
        {session.permissions.length === 0 ? (
          <Prose className="mt-3 text-sm text-muted-foreground">
            This account holds no permissions yet, so most sections are hidden. That is the platform
            working: absence of a grant is a refusal, not a default.
          </Prose>
        ) : (
          <ul className="mt-3 flex flex-wrap gap-1.5">
            {session.permissions.map((p) => (
              <li
                key={p}
                className="rounded-full bg-muted px-2.5 py-1 font-mono text-xs text-muted-foreground"
              >
                {p}
              </li>
            ))}
          </ul>
        )}
      </section>
    </div>
  );
}
