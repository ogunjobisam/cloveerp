import { createFileRoute } from "@tanstack/react-router";
import { Building2, Landmark, MapPin, Sparkles, UserRound, type LucideIcon } from "lucide-react";

import { FirstRun } from "../components/erp/first-run";
import { Gate } from "../components/erp/gate";
import { Launchpad } from "../components/erp/launchpad";
import { useErpSession } from "../components/erp/session-context";
import { EmptyState, PageHeader, Prose } from "../components/erp/page";
import { SeedDemoAction } from "../components/erp/seed";

export const Route = createFileRoute("/")({
  head: () => ({
    meta: [{ title: "Clove ERP" }],
  }),
  component: () => (
    <Gate>
      <Overview />
    </Gate>
  ),
});

function Field({ label, value, icon: Icon }: { label: string; value: string; icon: LucideIcon }) {
  return (
    <div className="min-w-0 rounded-xl border border-border bg-card p-3">
      <dt className="flex items-center gap-1.5 text-[11px] font-medium uppercase tracking-wide text-muted-foreground">
        <Icon className="size-3.5 text-accent" />
        {label}
      </dt>
      <dd className="mt-1 truncate text-sm font-medium">{value}</dd>
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
    <section className="rounded-2xl border border-dashed border-accent/40 bg-accent/5 p-4 sm:p-5">
      <div className="flex flex-col gap-4 md:flex-row md:items-center md:justify-between">
        <div className="flex min-w-0 items-start gap-3">
          <span className="grid size-9 shrink-0 place-items-center rounded-lg bg-accent/15 text-accent">
            <Sparkles className="size-4.5" />
          </span>
          <div className="min-w-0">
            <h2 className="font-display text-sm font-semibold">Explore with demo data</h2>
            <Prose className="mt-1 text-xs text-muted-foreground">
              Creates a demo tenant — two entities, three sites, a viewer principal — and switches
              your working context to it. Your current tenant is untouched.
            </Prose>
          </div>
        </div>
        <div className="shrink-0">
          <SeedDemoAction label="Seed a demo tenant" />
        </div>
      </div>
    </section>
  );
}

function ScopeList({
  title,
  rows,
  icon: Icon,
}: {
  title: string;
  rows: { id: string; code: string; name: string }[];
  icon: LucideIcon;
}) {
  return (
    <div className="min-w-0">
      <p className="flex items-center gap-1.5 text-xs font-medium uppercase tracking-wide text-muted-foreground">
        <Icon className="size-3.5 text-accent" />
        {title} ({rows.length})
      </p>
      {rows.length === 0 ? (
        <div className="mt-2">
          <EmptyState message="None configured yet." action={<SeedDemoAction />} />
        </div>
      ) : (
        <ul className="mt-2 flex flex-col gap-1 text-sm">
          {rows.map((r) => (
            <li key={r.id} className="truncate rounded-md px-2 py-1 hover:bg-muted">
              <span className="font-mono text-xs text-accent">{r.code}</span> {r.name}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

function Overview() {
  const { session, scope } = useErpSession();

  const entity = session.entities.find((e) => e.id === scope.entityId);
  const site = session.sites.find((s) => s.id === scope.siteId);

  return (
    <div className="flex min-w-0 flex-col gap-8">
      <section className="relative overflow-hidden rounded-2xl border border-border bg-card p-5 shadow-[var(--shadow-card)] sm:p-6">
        <div className="pointer-events-none absolute -right-16 -top-24 size-64 rounded-full bg-accent/10 blur-3xl" />
        <div className="relative flex flex-col gap-5">
          <PageHeader title={`Welcome, ${session.principal?.display_name ?? "there"}`}>
            Where you are, what this account may do, and every screen it can reach.
          </PageHeader>
          <dl className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <Field label="Organisation" value={session.tenant?.name ?? "—"} icon={Building2} />
            <Field label="User" value={session.principal?.display_name ?? "—"} icon={UserRound} />
            <Field
              label="Company"
              value={entity ? `${entity.code} — ${entity.name}` : "All"}
              icon={Landmark}
            />
            <Field
              label="Site"
              value={site ? `${site.code} — ${site.name}` : "All"}
              icon={MapPin}
            />
          </dl>
          <Prose className="text-xs text-muted-foreground">
            The organisation is derived from your account, never chosen. Everything below is scoped
            to it by the database rather than by this page — narrowing company or site changes what
            is shown, not what is permitted.
          </Prose>
        </div>
      </section>

      <FirstRun />

      <Launchpad />

      <section className="min-w-0 rounded-2xl border border-border bg-card p-4 shadow-[var(--shadow-card)] sm:p-5">
        <h2 className="font-display text-sm font-semibold">Scope</h2>
        <div className="mt-3 grid grid-cols-1 gap-4 md:grid-cols-2">
          <ScopeList title="Companies" rows={session.entities} icon={Landmark} />
          <ScopeList title="Sites" rows={session.sites} icon={MapPin} />
        </div>
      </section>

      {!session.tenant?.code.startsWith("demo-") ? <DemoSeed /> : null}

      <section className="min-w-0 rounded-2xl border border-border bg-card p-4 shadow-[var(--shadow-card)] sm:p-5">
        <h2 className="font-display text-sm font-semibold">
          Permissions held ({session.permissions.length})
        </h2>
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
                className="rounded-full border border-border bg-muted/60 px-2.5 py-1 font-mono text-xs text-muted-foreground"
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
