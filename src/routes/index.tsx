import { useMutation, useQueryClient } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";

import { Gate, useErpSession } from "../components/erp/gate";
import { callErp } from "../lib/erp";

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
    <div>
      <dt className="text-xs font-medium uppercase tracking-wide text-muted-foreground">{label}</dt>
      <dd className="mt-0.5 text-sm">{value}</dd>
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
  const queryClient = useQueryClient();
  const mutation = useMutation({
    mutationFn: () =>
      callErp<{ tenant_id: string; already_existed: boolean }>("erp_seed_demo"),
    onSuccess: () => queryClient.invalidateQueries(),
  });

  return (
    <section className="rounded-xl border border-dashed border-border bg-card/50 p-5">
      <div className="flex flex-wrap items-center justify-between gap-4">
        <div>
          <h2 className="text-sm font-semibold">Explore with demo data</h2>
          <p className="mt-1 text-xs text-muted-foreground">
            Creates a demo tenant — two entities, three sites, a viewer principal — and switches
            your working context to it. Your current tenant is untouched.
          </p>
        </div>
        <button
          onClick={() => mutation.mutate()}
          disabled={mutation.isPending}
          className="shrink-0 rounded-md border border-input px-4 py-2 text-sm font-medium disabled:opacity-60"
        >
          {mutation.isPending ? "Seeding…" : "Seed a demo tenant"}
        </button>
      </div>
      {mutation.error ? (
        <p role="alert" className="mt-3 text-sm text-destructive">
          {(mutation.error as Error).message}
        </p>
      ) : null}
    </section>
  );
}

function Overview() {
  const { session, scope } = useErpSession();

  const entity = session.entities.find((e) => e.id === scope.entityId);
  const site = session.sites.find((s) => s.id === scope.siteId);

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h1 className="text-xl font-semibold">Overview</h1>
        <p className="mt-1 text-sm text-muted-foreground">
          Where you are, and what this account may do.
        </p>
      </div>

      <section className="rounded-xl border border-border bg-card p-5">
        <h2 className="text-sm font-semibold">Context</h2>
        <dl className="mt-4 grid grid-cols-2 gap-4 sm:grid-cols-4">
          <Field label="Tenant" value={session.tenant?.name ?? "—"} />
          <Field label="Principal" value={session.principal?.display_name ?? "—"} />
          <Field label="Entity" value={entity ? `${entity.code} — ${entity.name}` : "All"} />
          <Field label="Site" value={site ? `${site.code} — ${site.name}` : "All"} />
        </dl>
        <p className="mt-4 text-xs text-muted-foreground">
          The tenant is derived from your account, never chosen. Everything below is scoped to it by
          the database rather than by this page — narrowing entity or site changes what is shown,
          not what is permitted.
        </p>
      </section>

      <section className="rounded-xl border border-border bg-card p-5">
        <h2 className="text-sm font-semibold">Scope</h2>
        <div className="mt-3 grid gap-4 sm:grid-cols-2">
          <div>
            <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
              Entities ({session.entities.length})
            </p>
            <ul className="mt-2 flex flex-col gap-1 text-sm">
              {session.entities.length === 0 ? (
                <li className="text-muted-foreground">None configured yet.</li>
              ) : (
                session.entities.map((e) => (
                  <li key={e.id}>
                    <span className="font-mono text-xs text-muted-foreground">{e.code}</span>{" "}
                    {e.name}
                  </li>
                ))
              )}
            </ul>
          </div>
          <div>
            <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
              Sites ({session.sites.length})
            </p>
            <ul className="mt-2 flex flex-col gap-1 text-sm">
              {session.sites.length === 0 ? (
                <li className="text-muted-foreground">None configured yet.</li>
              ) : (
                session.sites.map((s) => (
                  <li key={s.id}>
                    <span className="font-mono text-xs text-muted-foreground">{s.code}</span>{" "}
                    {s.name}
                  </li>
                ))
              )}
            </ul>
          </div>
        </div>
      </section>

      <section className="rounded-xl border border-border bg-card p-5">
        <h2 className="text-sm font-semibold">Permissions held ({session.permissions.length})</h2>
        {session.permissions.length === 0 ? (
          <p className="mt-3 text-sm text-muted-foreground">
            This account holds no permissions yet, so most sections are hidden. That is the platform
            working: absence of a grant is a refusal, not a default.
          </p>
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
