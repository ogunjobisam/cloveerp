import { useQuery } from "@tanstack/react-query";
import { AlertTriangle, CheckCircle2 } from "lucide-react";
import { type ReactNode } from "react";

import { Pill } from "../erp/panel";
import { callErp } from "../../lib/erp";
import { Card, Fail } from "./kit";
import type { CheckResult, TenantConfiguration, MyTenancy } from "../../lib/platform";

/**
 * What needs you.
 *
 * The landing view exists because nine equally-weighted tabs answer "where is
 * everything" and never answer "what should I look at". Every number here comes
 * from a read one of the other areas already uses — nothing is queried specially
 * for a dashboard, so nothing here can disagree with the page it links to.
 */

function Signal({
  tone,
  title,
  children,
}: {
  tone: "ok" | "warn" | "bad";
  title: string;
  children: ReactNode;
}) {
  return (
    <li className="flex items-start gap-3 border-b border-border/60 py-3 last:border-0">
      {tone === "ok" ? (
        <CheckCircle2 className="mt-0.5 size-4 shrink-0 text-muted-foreground" />
      ) : (
        <AlertTriangle
          className={`mt-0.5 size-4 shrink-0 ${tone === "bad" ? "text-destructive" : "text-foreground"}`}
        />
      )}
      <div className="min-w-0">
        <div className="text-sm font-medium">{title}</div>
        <div className="mt-0.5 text-xs text-muted-foreground">{children}</div>
      </div>
    </li>
  );
}

export function Overview({ onGo }: { onGo: (area: string) => void }) {
  // erp_platform_assurance is the cheap one: pass/fail for every registered
  // check in a single call, no findings.
  const assurance = useQuery({
    queryKey: ["erp_platform_assurance"],
    queryFn: () => callErp<CheckResult[]>("erp_platform_assurance"),
  });

  const config = useQuery({
    queryKey: ["erp_platform_tenant_configuration"],
    queryFn: () => callErp<TenantConfiguration[]>("erp_platform_tenant_configuration"),
  });

  const mine = useQuery({
    queryKey: ["erp_platform_my_tenancies"],
    queryFn: () => callErp<MyTenancy[]>("erp_platform_my_tenancies"),
  });

  const checks = assurance.data ?? [];
  const failing = checks.filter((c) => c.ok === false);
  const orgs = config.data ?? [];
  const unconfigured = orgs.filter(
    (o) => o.status === "active" && o.modules_installed.length === 0,
  );
  const awaiting = orgs.filter((o) => o.change_sets_awaiting > 0);
  const determination = orgs.filter((o) => o.determination_findings > 0);
  const inside = (mine.data ?? []).filter((t) => t.is_active);

  const anyError = assurance.error ?? config.error ?? mine.error;
  const loading = assurance.isPending || config.isPending || mine.isPending;

  return (
    <div className="flex flex-col gap-5">
      <Card
        title="What needs you"
        description="Read across every organisation. Each line links to the place that fixes it."
      >
        {anyError ? (
          <Fail error={anyError} />
        ) : loading ? (
          <p className="text-sm text-muted-foreground">Loading…</p>
        ) : (
          <ul className="flex flex-col">
            {failing.length > 0 ? (
              <Signal
                tone="bad"
                title={`${failing.length} check${failing.length === 1 ? "" : "s"} failing`}
              >
                {failing.map((c) => c.title ?? c.code).join(", ")} —{" "}
                <button type="button" className="underline" onClick={() => onGo("health")}>
                  see the findings
                </button>
              </Signal>
            ) : (
              <Signal tone="ok" title="Every check holds">
                {checks.filter((c) => c.ok === true).length} run,{" "}
                {checks.filter((c) => c.ok === null).length} need an organisation to run in.
              </Signal>
            )}

            {unconfigured.length > 0 ? (
              <Signal
                tone="warn"
                title={`${unconfigured.length} organisation${unconfigured.length === 1 ? "" : "s"} with nothing installed`}
              >
                {unconfigured.map((o) => o.code).join(", ")} — no module has been promoted, so there
                is nothing to operate.{" "}
                <button type="button" className="underline" onClick={() => onGo("organisations")}>
                  Open organisations
                </button>
              </Signal>
            ) : null}

            {awaiting.length > 0 ? (
              <Signal
                tone="warn"
                title={`${awaiting.length} organisation(s) with a change set waiting`}
              >
                {awaiting.map((o) => `${o.code} (${o.change_sets_awaiting})`).join(", ")} — approved
                or ready, and not yet promoted.
              </Signal>
            ) : null}

            {determination.length > 0 ? (
              <Signal tone="bad" title="A posting could fail to determine an account">
                {determination.map((o) => `${o.code} (${o.determination_findings})`).join(", ")} —
                §5 refuses a suspense fallback, so each is a refusal waiting to happen.
              </Signal>
            ) : null}

            {inside.length > 0 ? (
              <Signal
                tone="warn"
                title={`You are inside ${inside.length} organisation${inside.length === 1 ? "" : "s"}`}
              >
                {inside.map((t) => t.code).join(", ")} — you hold the administrator role there until
                you leave.{" "}
                <button type="button" className="underline" onClick={() => onGo("organisations")}>
                  Leave
                </button>
              </Signal>
            ) : null}

            {failing.length === 0 &&
            unconfigured.length === 0 &&
            awaiting.length === 0 &&
            determination.length === 0 &&
            inside.length === 0 ? (
              <Signal tone="ok" title="Nothing is waiting on you">
                Every organisation is configured, no check is failing, and you are not inside
                anybody&rsquo;s company.
              </Signal>
            ) : null}
          </ul>
        )}
      </Card>

      <Card title="Organisations at a glance">
        {config.isPending ? (
          <p className="text-sm text-muted-foreground">Loading…</p>
        ) : config.error ? (
          <Fail error={config.error} />
        ) : orgs.length === 0 ? (
          <p className="text-sm text-muted-foreground">No organisations yet.</p>
        ) : (
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            {orgs.map((o) => (
              <div key={o.tenant_id} className="rounded-lg border border-border p-3">
                <div className="flex items-center justify-between gap-2">
                  <span className="truncate text-sm font-medium">{o.name}</span>
                  <Pill tone={o.is_live ? "ok" : "warn"}>{o.is_live ? "live" : "building"}</Pill>
                </div>
                <div className="mt-1 font-mono text-xs text-muted-foreground">{o.code}</div>
                <div className="mt-2 text-xs text-muted-foreground">
                  {o.modules_installed.length} module(s) · {o.accounts} account(s) ·{" "}
                  {o.document_types} document type(s) · {o.jobs} job(s)
                </div>
              </div>
            ))}
          </div>
        )}
      </Card>
    </div>
  );
}
