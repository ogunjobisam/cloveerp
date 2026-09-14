import { useQueries, useQuery } from "@tanstack/react-query";
import {
  ArrowLeft,
  Building2,
  CreditCard,
  FileSignature,
  Receipt,
  Settings2,
  Users,
} from "lucide-react";

import { Pill, Table } from "../erp/panel";
import { callErp } from "../../lib/erp";
import { formatMinorWhole } from "../../lib/money";
import type {
  MyTenancy,
  PlatformRole,
  PlatformTenant,
  TenantConfiguration,
} from "../../lib/platform";
import { isDemoCode } from "../../lib/platform-console";
import { Card, ConsoleLink, Fail, LINK_BUTTON, statusLabel, statusTone } from "./kit";
import { OrganisationActions } from "./organisation-actions";
import type { PlatformPlans } from "./plans";
import { Seats } from "./seats";

/**
 * One organisation, on one page.
 *
 * What the owner needs to know about a customer was spread over four tabs —
 * the list for its people, Plans for its subscription, Contracts for its
 * agreement, and each contract for its invoices — each keyed by a code. This
 * page puts them together, read from the same doors under the same query keys,
 * with the actions the list offers and the same gates.
 */

type ContractSummary = {
  id: string;
  tenant_code: string;
  customer_legal_name: string;
  status: string;
  plan_code: string;
  currency: string;
  annual_value_minor: number;
  commencement: string;
  current_term_end: string;
  renewal_kind: string;
  notice_deadline: string | null;
  amendments: number;
  unsigned_amendments: number;
};

type Invoice = {
  id: string;
  reference: string;
  period_start: string;
  period_end: string;
  due_on: string;
  currency: string;
  total_minor: number;
  status: string;
  paid_at: string | null;
};

function day(value: string | null | undefined) {
  return value ? new Date(value).toLocaleDateString() : "—";
}

function contractTone(status: string): "ok" | "warn" | "muted" {
  return status === "active" ? "ok" : status === "draft" ? "warn" : "muted";
}

const RENEWAL: Record<string, string> = {
  automatic: "renews automatically",
  by_agreement: "renews by agreement",
  none: "does not renew",
};

export function OrganisationPage({ code, role }: { code: string; role: PlatformRole }) {
  const tenants = useQuery({
    queryKey: ["erp_platform_tenants"],
    queryFn: () => callErp<PlatformTenant[]>("erp_platform_tenants"),
  });
  const mine = useQuery({
    queryKey: ["erp_platform_my_tenancies"],
    queryFn: () => callErp<MyTenancy[]>("erp_platform_my_tenancies"),
  });

  const back = (
    <ConsoleLink section="customers" view="organisations" className={`${LINK_BUTTON} self-start`}>
      <ArrowLeft className="size-4" />
      All organisations
    </ConsoleLink>
  );

  if (tenants.isPending) {
    return <p className="text-sm text-muted-foreground">Loading…</p>;
  }
  if (tenants.error) {
    return (
      <div className="flex flex-col gap-4">
        {back}
        <Fail error={tenants.error} />
      </div>
    );
  }

  const wanted = code.toLowerCase();
  const t = (tenants.data ?? []).find((x) => x.code.toLowerCase() === wanted);
  if (!t) {
    return (
      <div className="flex flex-col gap-4">
        {back}
        <Card title="No such organisation" icon={<Building2 className="size-4 text-primary" />}>
          <p className="text-sm text-muted-foreground">
            No organisation on this deployment has the code{" "}
            <span className="font-mono text-foreground">{code}</span>. It may have been purged, or
            the link may be mistyped.
          </p>
        </Card>
      </div>
    );
  }

  const inside = (mine.data ?? []).some((m) => m.tenant_id === t.id && m.is_active);

  return (
    <div className="flex flex-col gap-5">
      {back}

      <section className="surface-card rounded-xl border border-border bg-card p-5">
        <div className="flex flex-wrap items-center gap-2">
          <h2 className="font-display text-xl font-semibold tracking-tight">{t.name}</h2>
          <Pill tone={statusTone(t.status)}>{statusLabel(t.status)}</Pill>
          {isDemoCode(t.code) ? <Pill tone="muted">Demo</Pill> : null}
        </div>
        <p className="mt-0.5 font-mono text-xs text-muted-foreground">{t.code}</p>
        <p className="mt-2 text-sm text-muted-foreground">
          {t.owner_email ? (
            <>
              Looked after by{" "}
              <span className="text-foreground">{t.owner_name ?? t.owner_email}</span>
              {t.owner_since ? ` since ${day(t.owner_since)}` : ""}.
            </>
          ) : (
            "No platform owner looks after it yet."
          )}{" "}
          On Clove ERP since {day(t.provisioned_at ?? t.created_at)}.
          {t.pending_transfer_to ? ` An offer to hand it to ${t.pending_transfer_to} is open.` : ""}
        </p>
        <div className="mt-4">
          <OrganisationActions tenant={t} role={role} inside={inside} size="full" />
        </div>
      </section>

      <div className="grid gap-5 lg:grid-cols-2">
        <People tenant={t} inside={inside} />
        <Subscription code={t.code} />
      </div>

      <Setup tenantId={t.id} />
      <Contract code={t.code} />
    </div>
  );
}

/**
 * Console text is not tenant terminology: nothing here goes through ui(), so
 * the prop is `caption` rather than `label`, which supabase/ci/screen_strings.sh
 * reads as a string a tenant can rename.
 */
function Figure({ caption, value, hint }: { caption: string; value: string; hint?: string }) {
  return (
    <div className="rounded-lg border border-border/60 p-3">
      <div className="text-xs text-muted-foreground">{caption}</div>
      <div className="mt-1 text-lg font-semibold tabular-nums">{value}</div>
      {hint ? <div className="mt-0.5 text-xs text-muted-foreground">{hint}</div> : null}
    </div>
  );
}

function People({ tenant: t, inside }: { tenant: PlatformTenant; inside: boolean }) {
  return (
    <Card title="People and structure" icon={<Users className="size-4 text-primary" />}>
      <div className="grid grid-cols-2 gap-3">
        <Figure caption="People" value={String(t.principals)} />
        <Figure
          caption="Open invitations"
          value={String(t.open_invitations)}
          {...(t.open_invitations > 0 ? { hint: "sent, and not yet accepted" } : {})}
        />
        <Figure caption="Companies" value={String(t.entities)} />
        <Figure caption="Sites" value={String(t.sites)} />
      </div>
      <Seats tenantId={t.id} />
      {inside ? (
        <p className="mt-3 text-xs text-muted-foreground">
          You are inside this organisation, and hold a role there until you leave.
        </p>
      ) : null}
    </Card>
  );
}

function Subscription({ code }: { code: string }) {
  const q = useQuery({
    queryKey: ["erp_platform_plans"],
    queryFn: () => callErp<PlatformPlans>("erp_platform_plans"),
  });

  return (
    <Card
      title="Plan and subscription"
      icon={<CreditCard className="size-4 text-primary" />}
      action={
        <ConsoleLink section="catalogue" view="plans" className={LINK_BUTTON}>
          All plans
        </ConsoleLink>
      }
    >
      {q.isPending ? (
        <p className="text-sm text-muted-foreground">Loading…</p>
      ) : q.error ? (
        <Fail error={q.error} />
      ) : (
        (() => {
          const subs = (q.data?.subscriptions ?? []).filter((s) => s.tenant_code === code);
          const current = subs.find((s) => s.status === "active") ?? subs[0];
          if (!current) {
            return (
              <p className="text-sm text-muted-foreground">
                It holds no subscription, so it is on the default plan.
              </p>
            );
          }
          const plan = (q.data?.plans ?? []).find((p) => p.code === current.plan_code);
          return (
            <div className="flex flex-col gap-3">
              <div className="flex flex-wrap items-center gap-2">
                <span className="text-base font-semibold">{plan?.name ?? current.plan_code}</span>
                <span className="font-mono text-xs text-muted-foreground">{current.plan_code}</span>
                <Pill tone={current.status === "active" ? "ok" : "warn"}>
                  {statusLabel(current.status)}
                </Pill>
              </div>
              <p className="text-sm text-muted-foreground">
                {day(current.term_start)} to {day(current.term_end)}
                {current.currency ? `, in ${current.currency}` : ""};{" "}
                {current.renews ? "renews" : "does not renew"}.
                {current.note ? ` ${current.note}` : ""}
              </p>
              {plan && plan.entitlements.length > 0 ? (
                <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-0.5 text-xs">
                  {plan.entitlements.map((e) => (
                    <div key={e.entitlement_code} className="contents">
                      <dt className="text-muted-foreground">{e.title ?? e.entitlement_code}</dt>
                      <dd className="tabular-nums">
                        {e.limit_value != null
                          ? `${e.limit_value.toLocaleString()} ${e.unit ?? ""}`
                          : "Unlimited"}
                      </dd>
                    </div>
                  ))}
                </dl>
              ) : null}
              {subs.length > 1 ? (
                <p className="text-xs text-muted-foreground">
                  {subs.length - 1} earlier {subs.length - 1 === 1 ? "term" : "terms"} under Plans
                  and subscriptions.
                </p>
              ) : null}
            </div>
          );
        })()
      )}
    </Card>
  );
}

function Setup({ tenantId }: { tenantId: string }) {
  const q = useQuery({
    queryKey: ["erp_platform_tenant_configuration"],
    queryFn: () => callErp<TenantConfiguration[]>("erp_platform_tenant_configuration"),
  });
  const c = (q.data ?? []).find((x) => x.tenant_id === tenantId);

  return (
    <Card title="How it is set up" icon={<Settings2 className="size-4 text-primary" />}>
      {q.isPending ? (
        <p className="text-sm text-muted-foreground">Loading…</p>
      ) : q.error ? (
        <Fail error={q.error} />
      ) : !c ? (
        <p className="text-sm text-muted-foreground">Nothing is recorded about its setup.</p>
      ) : (
        <div className="flex flex-col gap-3">
          <div className="flex flex-wrap items-center gap-2 text-sm">
            <Pill tone={c.is_live ? "ok" : "warn"}>{c.is_live ? "Live" : "In setup"}</Pill>
            <span className="text-muted-foreground">
              {c.modules_installed.length === 0
                ? "No module is installed yet."
                : `Installed: ${c.modules_installed.join(", ")}.`}
            </span>
          </div>
          <div className="grid gap-3 sm:grid-cols-3 lg:grid-cols-5">
            <Figure caption="Accounts" value={String(c.accounts)} />
            <Figure caption="Document types" value={String(c.document_types)} />
            <Figure caption="Posting rules" value={String(c.posting_rules)} />
            <Figure caption="Scheduled jobs" value={String(c.jobs)} />
            <Figure caption="Changes waiting" value={String(c.change_sets_awaiting)} />
          </div>
          {c.determination_findings > 0 ? (
            <p className="text-sm text-destructive">
              {c.determination_findings}{" "}
              {c.determination_findings === 1 ? "posting has" : "postings have"} no account rule and
              would be refused.
            </p>
          ) : null}
        </div>
      )}
    </Card>
  );
}

function Contract({ code }: { code: string }) {
  const q = useQuery({
    queryKey: ["erp_platform_contracts"],
    queryFn: () => callErp<{ contracts: ContractSummary[] }>("erp_platform_contracts"),
  });
  const contracts = (q.data?.contracts ?? []).filter((c) => c.tenant_code === code);

  const invoices = useQueries({
    queries: contracts.map((c) => ({
      queryKey: ["erp_platform_invoices", { p_contract_id: c.id }],
      queryFn: () => callErp<Invoice[]>("erp_platform_invoices", { p_contract_id: c.id }),
    })),
  });

  const today = new Date().toISOString().slice(0, 10);

  return (
    <>
      <Card
        title="Contract"
        icon={<FileSignature className="size-4 text-primary" />}
        action={
          <ConsoleLink section="sales" view="contracts" className={LINK_BUTTON}>
            Open contracts
          </ConsoleLink>
        }
      >
        {q.isPending ? (
          <p className="text-sm text-muted-foreground">Loading…</p>
        ) : q.error ? (
          <Fail error={q.error} />
        ) : contracts.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            No contract has been made with this organisation. A contract is made from an accepted
            quote, under Contracts.
          </p>
        ) : (
          <ul className="flex flex-col gap-3">
            {contracts.map((c) => (
              <li key={c.id} className="rounded-lg border border-border/60 p-3">
                <div className="flex flex-wrap items-center gap-2">
                  <span className="text-sm font-semibold">{c.customer_legal_name}</span>
                  <Pill tone={contractTone(c.status)}>{statusLabel(c.status)}</Pill>
                </div>
                <p className="mt-1 text-sm text-muted-foreground">
                  {formatMinorWhole(c.annual_value_minor, c.currency)} a year on{" "}
                  <span className="font-mono text-xs">{c.plan_code}</span>, from{" "}
                  {day(c.commencement)} to {day(c.current_term_end)};{" "}
                  {RENEWAL[c.renewal_kind] ?? c.renewal_kind}
                  {c.notice_deadline ? `, with notice due by ${day(c.notice_deadline)}` : ""}.
                </p>
                {c.amendments > 0 ? (
                  <p className="mt-1 text-xs text-muted-foreground">
                    {c.amendments} {c.amendments === 1 ? "amendment" : "amendments"}
                    {c.unsigned_amendments > 0 ? `, ${c.unsigned_amendments} not yet signed` : ""}.
                  </p>
                ) : null}
              </li>
            ))}
          </ul>
        )}
      </Card>

      {contracts.length > 0 ? (
        <Card title="Invoices" icon={<Receipt className="size-4 text-primary" />}>
          <div className="flex flex-col gap-4">
            {contracts.map((c, n) => {
              const iq = invoices[n];
              if (!iq || iq.isPending) {
                return (
                  <p key={c.id} className="text-sm text-muted-foreground">
                    Loading…
                  </p>
                );
              }
              if (iq.error) return <Fail key={c.id} error={iq.error} />;
              const rows = iq.data ?? [];
              return (
                <div key={c.id}>
                  {contracts.length > 1 ? (
                    <h3 className="mb-1 text-xs font-medium uppercase tracking-wide text-muted-foreground">
                      {c.customer_legal_name}
                    </h3>
                  ) : null}
                  {rows.length === 0 ? (
                    <p className="text-sm text-muted-foreground">Nothing is scheduled yet.</p>
                  ) : (
                    <Table columns={["Reference", "Period", "Due", "Total", "State"]}>
                      {rows.map((i) => {
                        const overdue = i.status === "issued" && i.due_on < today;
                        return (
                          <tr key={i.id} className="border-b border-border/50 last:border-0">
                            <td className="py-1.5 pr-4 font-mono text-xs">{i.reference}</td>
                            <td className="py-1.5 pr-4 text-xs">
                              {day(i.period_start)} to {day(i.period_end)}
                            </td>
                            <td className="py-1.5 pr-4 text-xs">{day(i.due_on)}</td>
                            <td className="py-1.5 pr-4 text-sm tabular-nums">
                              {formatMinorWhole(i.total_minor, i.currency)}
                            </td>
                            <td className="py-1.5">
                              <Pill
                                tone={
                                  i.status === "paid"
                                    ? "ok"
                                    : overdue
                                      ? "bad"
                                      : i.status === "issued"
                                        ? "warn"
                                        : "muted"
                                }
                              >
                                {overdue
                                  ? "Overdue"
                                  : i.status === "issued"
                                    ? "Awaiting payment"
                                    : statusLabel(i.status)}
                              </Pill>
                            </td>
                          </tr>
                        );
                      })}
                    </Table>
                  )}
                </div>
              );
            })}
            <p className="text-xs text-muted-foreground">
              Invoices are issued, and payments recorded, on the contract under Contracts.
            </p>
          </div>
        </Card>
      ) : null}
    </>
  );
}
