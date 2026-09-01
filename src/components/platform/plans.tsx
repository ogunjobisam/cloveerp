import { useQuery } from "@tanstack/react-query";
import { CreditCard } from "lucide-react";

import { Pill, Table } from "../erp/panel";
import { callErp } from "../../lib/erp";
import { Card, Fail } from "./kit";

/**
 * Plans, what each entitles, and who is on which.
 *
 * Platform staff only: a subscription is the one thing in the product that is
 * about money, and an organisation sees its own through Plan and usage. Read-
 * only here too — a plan is registered in a migration, and a subscription is
 * written by the platform's own operations, both with their reasoning in the
 * diff. The findings are erp.entitlement_enforcement_report(): an entitlement
 * kind that no function counts, a subscription on a plan that is gone.
 */

type PlatformPlans = {
  plans: {
    code: string;
    name: string;
    description: string | null;
    seq: number;
    entitlements: {
      entitlement_code: string;
      title: string | null;
      unit: string | null;
      limit_value: number | null;
      note: string | null;
    }[];
    capabilities: string[];
    subscribers: number;
  }[];
  subscriptions: {
    tenant_code: string;
    plan_code: string;
    term_start: string;
    term_end: string | null;
    renews: boolean;
    currency: string | null;
    status: string;
    note: string | null;
    updated_at: string;
  }[];
  entitlement_kinds: {
    code: string;
    title: string;
    unit: string;
    counts_what: string | null;
  }[];
  findings: { finding: string; detail: string }[];
};

function day(value: string | null) {
  return value ? new Date(value).toLocaleDateString() : "—";
}

export function Plans() {
  const q = useQuery({
    queryKey: ["erp_platform_plans"],
    queryFn: () => callErp<PlatformPlans>("erp_platform_plans"),
  });

  return (
    <Card
      title="Plans and subscriptions"
      icon={<CreditCard className="size-4 text-primary" />}
      description="Every plan the platform offers, what each one limits and allows, and which organisation is on which."
    >
      {q.isPending ? (
        <p className="text-sm text-muted-foreground">Loading…</p>
      ) : q.error ? (
        <Fail error={q.error} />
      ) : !q.data ? null : (
        <div className="flex flex-col gap-6">
          {q.data.findings.length > 0 ? (
            <ul className="flex flex-col gap-1" role="alert">
              {q.data.findings.map((f, i) => (
                <li key={`${f.finding}-${i}`} className="text-xs text-destructive">
                  <span className="font-medium">{f.finding}:</span> {f.detail}
                </li>
              ))}
            </ul>
          ) : null}

          {q.data.plans.length === 0 ? (
            <p className="text-sm text-muted-foreground">No plan is registered.</p>
          ) : (
            <ul className="flex flex-col gap-5">
              {q.data.plans.map((p) => (
                <li key={p.code} className="border-b border-border/60 pb-5 last:border-0 last:pb-0">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="text-sm font-semibold">{p.name}</span>
                    <span className="font-mono text-xs text-muted-foreground">{p.code}</span>
                    <Pill tone={p.subscribers > 0 ? "ok" : "muted"}>
                      {p.subscribers === 1 ? "1 subscriber" : `${p.subscribers} subscribers`}
                    </Pill>
                  </div>
                  {p.description ? (
                    <p className="mt-1 text-sm text-muted-foreground">{p.description}</p>
                  ) : null}
                  {p.entitlements.length > 0 ? (
                    <dl className="mt-2 grid grid-cols-[auto_1fr] gap-x-4 gap-y-0.5 text-xs">
                      {p.entitlements.map((e) => (
                        <div key={e.entitlement_code} className="contents">
                          <dt className="text-muted-foreground">{e.title ?? e.entitlement_code}</dt>
                          <dd className="tabular-nums">
                            {e.limit_value != null
                              ? `${e.limit_value.toLocaleString()} ${e.unit ?? ""}`
                              : "Unlimited"}
                            {e.note ? (
                              <span className="text-muted-foreground"> · {e.note}</span>
                            ) : null}
                          </dd>
                        </div>
                      ))}
                    </dl>
                  ) : (
                    <p className="mt-2 text-xs text-muted-foreground">Sets no limits.</p>
                  )}
                  {p.capabilities.length > 0 ? (
                    <p className="mt-2 font-mono text-xs text-muted-foreground">
                      {p.capabilities.join(", ")}
                    </p>
                  ) : null}
                </li>
              ))}
            </ul>
          )}

          <div>
            <h3 className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
              Subscriptions
            </h3>
            {q.data.subscriptions.length === 0 ? (
              <p className="mt-2 text-sm text-muted-foreground">
                No organisation holds a subscription; each is on the default plan.
              </p>
            ) : (
              <div className="mt-2">
                <Table columns={["Organisation", "Plan", "Term", "Renews", "State"]}>
                  {q.data.subscriptions.map((s) => (
                    <tr
                      key={`${s.tenant_code}-${s.term_start}`}
                      className="border-b border-border/50 align-top last:border-0"
                    >
                      <td className="py-2 pr-4 font-mono text-xs">{s.tenant_code}</td>
                      <td className="py-2 pr-4 font-mono text-xs">{s.plan_code}</td>
                      <td className="py-2 pr-4 text-xs text-muted-foreground">
                        {day(s.term_start)} → {day(s.term_end)}
                        {s.currency ? ` · ${s.currency}` : ""}
                      </td>
                      <td className="py-2 pr-4 text-sm">{s.renews ? "Yes" : "No"}</td>
                      <td className="py-2">
                        <Pill tone={s.status === "active" ? "ok" : "warn"}>{s.status}</Pill>
                        {s.note ? (
                          <div className="mt-0.5 text-xs text-muted-foreground">{s.note}</div>
                        ) : null}
                      </td>
                    </tr>
                  ))}
                </Table>
              </div>
            )}
          </div>

          <div>
            <h3 className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
              What can be limited
            </h3>
            {q.data.entitlement_kinds.length === 0 ? (
              <p className="mt-2 text-sm text-muted-foreground">
                No entitlement kind is registered.
              </p>
            ) : (
              <ul className="mt-2 flex flex-col gap-1 text-xs">
                {q.data.entitlement_kinds.map((k) => (
                  <li key={k.code}>
                    <span className="font-medium">{k.title}</span>
                    <span className="text-muted-foreground">
                      {" "}
                      · {k.unit}
                      {k.counts_what ? ` · ${k.counts_what}` : ""}
                    </span>
                  </li>
                ))}
              </ul>
            )}
          </div>
        </div>
      )}
    </Card>
  );
}
