import { friendlyError } from "@/lib/errors";
import { useQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import type { ReactNode } from "react";

import { Gate } from "../../components/erp/gate";
import { PageHeader, Prose } from "../../components/erp/page";
import { Pill, Table } from "../../components/erp/panel";
import { useErpSession } from "../../components/erp/session-context";
import { callErp, hasPermission } from "../../lib/erp";

/**
 * The organisation's own plan, in one read.
 *
 * §18.2 requires an organisation to see what it is entitled to and how much
 * of it is used, continuously, not on request. erp_commercial_summary() is
 * one call that answers plan, subscription, capabilities, entitlements and
 * meters together, so this screen is one query rendered five ways rather than
 * five panels each polling on its own.
 *
 * Nothing here is editable. A plan is chosen by platform staff against a
 * subscription; what this screen does is make the consequence visible before
 * the limit bites.
 */

export const Route = createFileRoute("/administration/commercial")({
  head: () => ({ meta: [{ title: "Plan and usage — Clove ERP" }] }),
  component: () => (
    <Gate>
      <Commercial />
    </Gate>
  ),
});

type Summary = {
  plan: { code: string; name: string; description: string | null } | null;
  subscription: {
    plan_code: string;
    term_start: string;
    term_end: string | null;
    renews: boolean;
    currency: string | null;
    status: string;
    note: string | null;
  } | null;
  capabilities: string[];
  entitlements: {
    entitlement_code: string;
    title: string;
    unit: string;
    limit_value: number | null;
    used: number;
    remaining: number | null;
    breached: boolean;
  }[];
  meters: {
    meter_code: string;
    title: string | null;
    unit: string | null;
    period_start: string;
    period_end: string;
    quantity: number;
    measured_at: string;
  }[];
};

function day(value: string | null) {
  return value ? new Date(value).toLocaleDateString() : "—";
}

function Section({
  title,
  description,
  children,
}: {
  title: string;
  description?: string;
  children: ReactNode;
}) {
  return (
    <section className="min-w-0 rounded-xl border border-border bg-card">
      <header className="border-b border-border px-4 py-4 sm:px-5">
        <h2 className="text-sm font-semibold">{title}</h2>
        {description ? (
          <Prose className="mt-0.5 text-xs text-muted-foreground">{description}</Prose>
        ) : null}
      </header>
      <div className="px-4 py-4 sm:px-5">{children}</div>
    </section>
  );
}

function Commercial() {
  const { session } = useErpSession();
  const allowed = hasPermission(session, "administration.read");

  const { data, isPending, error } = useQuery({
    queryKey: ["erp_commercial_summary", {}],
    queryFn: () => callErp<Summary>("erp_commercial_summary", {}),
    refetchInterval: 60_000,
    enabled: allowed,
  });

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title="Plan and usage">
        What this organisation is subscribed to, what the plan lets it do, how much of each
        entitlement it has used, and the meters that usage is read from. A limit is enforced by the
        database when it is reached; this is where it can be seen coming.
      </PageHeader>

      {!allowed ? (
        <p className="rounded-xl border border-border bg-card p-4 text-sm text-muted-foreground sm:p-5">
          This account does not hold <code className="font-mono text-xs">administration.read</code>,
          so the plan is not offered. Absence of a grant is a refusal, not a default.
        </p>
      ) : isPending ? (
        <p className="text-sm text-muted-foreground">Loading…</p>
      ) : error ? (
        <div role="alert" className="rounded-xl border border-border bg-card p-4 sm:p-5">
          <p className="text-sm font-medium text-destructive">This did not load.</p>
          <p className="mt-1 text-xs text-muted-foreground">{friendlyError(error).title}</p>
        </div>
      ) : !data ? null : (
        <>
          <Section
            title="Plan"
            description="The plan the current subscription names. Without a subscription the organisation is on the platform's default plan, which is deliberately the smallest."
          >
            {data.plan ? (
              <div className="flex flex-wrap items-start gap-x-8 gap-y-3">
                <div>
                  <div className="text-lg font-semibold">{data.plan.name}</div>
                  <div className="mt-0.5 font-mono text-xs text-muted-foreground">
                    {data.plan.code}
                  </div>
                  {data.plan.description ? (
                    <p className="mt-2 max-w-prose text-sm text-muted-foreground">
                      {data.plan.description}
                    </p>
                  ) : null}
                </div>
                {data.subscription ? (
                  <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
                    <dt className="text-muted-foreground">Term</dt>
                    <dd>
                      {day(data.subscription.term_start)} → {day(data.subscription.term_end)}
                    </dd>
                    <dt className="text-muted-foreground">Renews</dt>
                    <dd>{data.subscription.renews ? "Yes" : "No"}</dd>
                    <dt className="text-muted-foreground">State</dt>
                    <dd>
                      <Pill tone={data.subscription.status === "active" ? "ok" : "warn"}>
                        {data.subscription.status}
                      </Pill>
                    </dd>
                    {data.subscription.currency ? (
                      <>
                        <dt className="text-muted-foreground">Billed in</dt>
                        <dd className="font-mono text-xs">{data.subscription.currency}</dd>
                      </>
                    ) : null}
                    {data.subscription.note ? (
                      <>
                        <dt className="text-muted-foreground">Note</dt>
                        <dd className="text-muted-foreground">{data.subscription.note}</dd>
                      </>
                    ) : null}
                  </dl>
                ) : (
                  <p className="text-sm text-muted-foreground">
                    No subscription is recorded, so this is the default plan.
                  </p>
                )}
              </div>
            ) : (
              <p className="text-sm text-muted-foreground">
                No plan is registered on the platform, which is itself unexpected.
              </p>
            )}
          </Section>

          <Section
            title="Entitlements"
            description="Each limit the plan sets, against what has been used. Remaining is empty where the plan sets no limit. A breached entitlement is one the database is already refusing on."
          >
            {data.entitlements.length === 0 ? (
              <p className="text-sm text-muted-foreground">The plan sets no limits.</p>
            ) : (
              <Table columns={["Entitlement", "Used", "Limit", "Remaining", "State"]}>
                {data.entitlements.map((e) => (
                  <tr
                    key={e.entitlement_code}
                    className="border-b border-border/50 align-top last:border-0"
                  >
                    <td className="py-2 pr-4">
                      <div className="text-sm">{e.title}</div>
                      <div className="mt-0.5 font-mono text-xs text-muted-foreground">
                        {e.entitlement_code}
                      </div>
                    </td>
                    <td className="py-2 pr-4 text-sm tabular-nums">
                      {e.used.toLocaleString()} {e.unit}
                    </td>
                    <td className="py-2 pr-4 text-sm tabular-nums">
                      {e.limit_value != null ? e.limit_value.toLocaleString() : "Unlimited"}
                    </td>
                    <td className="py-2 pr-4 text-sm tabular-nums">
                      {e.remaining != null ? e.remaining.toLocaleString() : "—"}
                    </td>
                    <td className="py-2">
                      {e.breached ? (
                        <Pill tone="bad">Breached</Pill>
                      ) : e.limit_value != null &&
                        e.remaining != null &&
                        e.remaining <= Math.max(1, Math.floor(e.limit_value / 10)) ? (
                        <Pill tone="warn">Near the limit</Pill>
                      ) : (
                        <Pill tone="ok">Within</Pill>
                      )}
                    </td>
                  </tr>
                ))}
              </Table>
            )}
          </Section>

          <Section
            title="Capabilities the plan allows"
            description="A capability outside this list cannot be switched on for the organisation, whatever pack or preset asks for it."
          >
            {data.capabilities.length === 0 ? (
              <p className="text-sm text-muted-foreground">
                The plan names no capabilities, so every one the product has is available.
              </p>
            ) : (
              <ul className="flex flex-wrap gap-2">
                {data.capabilities.map((c) => (
                  <li key={c}>
                    <Pill tone="muted">
                      <span className="font-mono">{c}</span>
                    </Pill>
                  </li>
                ))}
              </ul>
            )}
          </Section>

          <Section
            title="Meters"
            description="The readings usage is charged and limited from, most recent period first. A reading is taken by the platform's own job and is not editable from anywhere."
          >
            {data.meters.length === 0 ? (
              <p className="text-sm text-muted-foreground">No reading has been taken yet.</p>
            ) : (
              <Table columns={["Meter", "Period", "Reading", "Measured"]}>
                {data.meters.map((m) => (
                  <tr
                    key={`${m.meter_code}-${m.period_start}`}
                    className="border-b border-border/50 align-top last:border-0"
                  >
                    <td className="py-2 pr-4">
                      <div className="text-sm">{m.title ?? m.meter_code}</div>
                      <div className="mt-0.5 font-mono text-xs text-muted-foreground">
                        {m.meter_code}
                      </div>
                    </td>
                    <td className="py-2 pr-4 text-xs text-muted-foreground">
                      {day(m.period_start)} → {day(m.period_end)}
                    </td>
                    <td className="py-2 pr-4 text-sm tabular-nums">
                      {m.quantity.toLocaleString()} {m.unit ?? ""}
                    </td>
                    <td className="py-2 text-xs text-muted-foreground">
                      {new Date(m.measured_at).toLocaleString()}
                    </td>
                  </tr>
                ))}
              </Table>
            )}
          </Section>
        </>
      )}
    </div>
  );
}
