import { friendlyError } from "@/lib/errors";
import { useQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { Fragment, useState, type ReactNode } from "react";

import { Gate } from "../../components/erp/gate";
import { PageHeader, Prose, TOUCH } from "../../components/erp/page";
import { Pill, Table } from "../../components/erp/panel";
import { useErpSession } from "../../components/erp/session-context";
import { callErp, hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";

/**
 * The organisation's own agreement, in one read. Specification v1.5 §17.11, D38.
 *
 * §18.2 requires an organisation to see what it is entitled to and how much
 * of it is used, continuously, not on request. §17.11 widens that to the whole
 * agreement: the contract and the documents that constitute it, the
 * entitlement in the contract's own terms, live usage, each invoice with the
 * metering behind it, the renewal date, the notice deadline, the uplift rule,
 * and the sub-processor list with every change to it. erp_my_agreement() is
 * one call that answers all of it, scoped to the caller's organisation.
 *
 * Nothing here is editable. The contract is the source; what this screen does
 * is make its consequences visible before any of them bites.
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
};

type Contract = {
  id: string;
  status: string;
  customer_legal_name: string;
  platform_legal_name: string;
  quote_number: string;
  quote_version: number;
  plan_code: string;
  plan_name: string | null;
  support_severity_code: string | null;
  term_kind: string;
  currency: string;
  annual_value_minor: number;
  billing_frequency: string;
  commencement: string;
  initial_term_months: number;
  current_term_start: string;
  current_term_end: string;
  renewal_kind: string;
  notice_days: number;
  governing_law: string;
  uplift_rule: { kind: string; pct?: number; index_code?: string; cap_pct?: number };
  termination_terms: Record<string, unknown>;
  review_date: string | null;
  signed_at: string | null;
  key_dates: { kind: string; due_on: string; days_left: number }[];
  capabilities: { capability_code: string; in_force: boolean }[];
};

type InvoiceLine =
  | { kind: "subscription"; net_minor: number; description: string }
  | {
      kind: "overage";
      entitlement_code: string;
      unit: string;
      month: string;
      used: number;
      limit_value: number | null;
      over: number;
      unit_minor: number | null;
      band: string | null;
      net_minor: number;
      unpriced: boolean;
    };

type Agreement = {
  contract: Contract | null;
  documents: {
    id: string;
    kind: string;
    version: number;
    title: string;
    checksum: string;
    signed_at: string | null;
    superseded_by: string | null;
    byte_size: number;
    created_at: string;
  }[];
  entitlements: {
    entitlement_code: string;
    title: string;
    unit: string;
    limit_value: number | null;
    used: number;
    remaining: number | null;
    breached: boolean;
    source: "contract" | "plan";
  }[];
  capabilities: string[];
  meters: {
    meter_code: string;
    title: string | null;
    unit: string | null;
    period_start: string;
    period_end: string;
    quantity: number;
    measured_at: string;
  }[];
  invoices: {
    id: string;
    reference: string;
    period_start: string;
    period_end: string;
    due_on: string;
    currency: string;
    subscription_minor: number;
    overage_minor: number;
    total_minor: number;
    status: string;
    issued_at: string | null;
    paid_at: string | null;
    lines: InvoiceLine[];
  }[];
  renewal: {
    term_start: string;
    term_end: string;
    uplift_pct: number;
    proposed_annual_value_minor: number;
    currency: string;
    notice_deadline: string | null;
    status: string;
  } | null;
  subscription: {
    plan_code: string;
    term_start: string;
    term_end: string | null;
    renews: boolean;
    currency: string | null;
    status: string;
  } | null;
  sub_processors: {
    code: string;
    name: string;
    purpose: string;
    location: string;
    added_at: string;
    notified_at: string | null;
    withdrawn_at: string | null;
  }[];
  service_commitments: {
    code: string;
    title: string;
    commitment: string;
    derived_from: string;
    remedy: string;
  }[];
};

function day(value: string | null | undefined) {
  return value ? new Date(value).toLocaleDateString() : "—";
}

function money(minor: number | null | undefined, currency?: string) {
  if (minor == null) return "—";
  return `${(minor / 100).toLocaleString(undefined, {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  })}${currency ? ` ${currency}` : ""}`;
}

function upliftText(rule: Contract["uplift_rule"]) {
  switch (rule.kind) {
    case "none":
      return "No uplift on renewal.";
    case "fixed_pct":
      return `${rule.pct}% on renewal.`;
    case "index":
      return `${rule.index_code} for the period, on renewal.`;
    case "capped":
      return `${rule.index_code} for the period, capped at ${rule.cap_pct}%, on renewal.`;
    default:
      return JSON.stringify(rule);
  }
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
  const { ui } = useT();
  const { session } = useErpSession();
  const allowed = hasPermission(session, "administration.read");
  const [shownDoc, setShownDoc] = useState<string | null>(null);
  const [openInvoice, setOpenInvoice] = useState<string | null>(null);

  const summary = useQuery({
    queryKey: ["erp_commercial_summary", {}],
    queryFn: () => callErp<Summary>("erp_commercial_summary", {}),
    enabled: allowed,
  });
  const { data, isPending, error } = useQuery({
    queryKey: ["erp_my_agreement"],
    queryFn: () => callErp<Agreement>("erp_my_agreement"),
    refetchInterval: 60_000,
    enabled: allowed,
  });
  const doc = useQuery({
    queryKey: ["erp_my_contract_document", { p_document_id: shownDoc }],
    queryFn: () =>
      callErp<{ title: string; content: string; checksum: string; signature_meaning: string }>(
        "erp_my_contract_document",
        { p_document_id: shownDoc },
      ),
    enabled: Boolean(shownDoc),
  });

  const plan = summary.data?.plan ?? null;

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={ui("Your agreement")}>
        {ui(
          "What this organisation is entitled to, what it is using, what it will pay next and when its term ends, without asking. The contract is the source; the entitlement enforced is derived from it.",
        )}
      </PageHeader>

      {!allowed ? (
        <p className="rounded-xl border border-border bg-card p-4 text-sm text-muted-foreground sm:p-5">
          This account does not hold <code className="font-mono text-xs">administration.read</code>,
          so the agreement is not offered. Absence of a grant is a refusal, not a default.
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
            title={ui("Subscription")}
            description="The plan the current subscription names. Without a contract the organisation is on the platform's default plan, which is deliberately the smallest."
          >
            <div className="flex flex-wrap items-start gap-x-8 gap-y-3">
              <div>
                <div className="text-lg font-semibold">
                  {data.contract?.plan_name ?? plan?.name ?? data.subscription?.plan_code ?? "—"}
                </div>
                <div className="mt-0.5 font-mono text-xs text-muted-foreground">
                  {data.contract?.plan_code ?? plan?.code ?? data.subscription?.plan_code ?? ""}
                </div>
                {plan?.description ? (
                  <p className="mt-2 max-w-prose text-sm text-muted-foreground">
                    {plan.description}
                  </p>
                ) : null}
              </div>
              {data.subscription ? (
                <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
                  <dt className="text-muted-foreground">{ui("Term")}</dt>
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
                </dl>
              ) : (
                <p className="text-sm text-muted-foreground">
                  {ui(
                    "No contract is recorded for this organisation yet. The plan below is the platform's default until one is signed.",
                  )}
                </p>
              )}
            </div>
          </Section>

          {data.contract ? (
            <Section
              title={ui("Your agreement")}
              description={`Between ${data.contract.customer_legal_name} and ${data.contract.platform_legal_name}, from quote ${data.contract.quote_number} v${data.contract.quote_version}. ${data.contract.governing_law}.`}
            >
              <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
                <dt className="text-muted-foreground">State</dt>
                <dd>
                  <Pill tone={data.contract.status === "active" ? "ok" : "warn"}>
                    {data.contract.status}
                  </Pill>
                  {data.contract.signed_at ? (
                    <span className="ml-2 text-xs text-muted-foreground">
                      signed {day(data.contract.signed_at)}
                    </span>
                  ) : null}
                </dd>
                <dt className="text-muted-foreground">Annual value</dt>
                <dd className="tabular-nums">
                  {money(data.contract.annual_value_minor, data.contract.currency)} · billed{" "}
                  {data.contract.billing_frequency}
                </dd>
                <dt className="text-muted-foreground">{ui("Term")}</dt>
                <dd>
                  {day(data.contract.commencement)} for {data.contract.initial_term_months} months;
                  current term {day(data.contract.current_term_start)} →{" "}
                  {day(data.contract.current_term_end)}
                </dd>
                <dt className="text-muted-foreground">{ui("Renewal")}</dt>
                <dd>
                  {data.contract.renewal_kind.replace(/_/g, " ")} · {data.contract.notice_days}{" "}
                  days' notice
                </dd>
                <dt className="text-muted-foreground">{ui("Notice deadline")}</dt>
                <dd>
                  {(() => {
                    const k = data.contract.key_dates.find((d) => d.kind === "notice_deadline");
                    return k ? (
                      <>
                        {day(k.due_on)}{" "}
                        <Pill tone={k.days_left < 0 ? "muted" : k.days_left <= 30 ? "warn" : "ok"}>
                          {k.days_left < 0 ? "passed" : `${k.days_left} days left`}
                        </Pill>
                      </>
                    ) : (
                      "—"
                    );
                  })()}
                </dd>
                <dt className="text-muted-foreground">{ui("Uplift rule")}</dt>
                <dd>{upliftText(data.contract.uplift_rule)}</dd>
                {data.contract.support_severity_code ? (
                  <>
                    <dt className="text-muted-foreground">Support</dt>
                    <dd className="font-mono text-xs">{data.contract.support_severity_code}</dd>
                  </>
                ) : null}
                {data.contract.review_date ? (
                  <>
                    <dt className="text-muted-foreground">Review</dt>
                    <dd>{day(data.contract.review_date)}</dd>
                  </>
                ) : null}
              </dl>
              {data.renewal ? (
                <div className="mt-4 rounded-lg border border-border/60 p-3 text-sm">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="font-medium">{ui("Renewal")}</span>
                    <Pill
                      tone={
                        data.renewal.status === "accepted"
                          ? "ok"
                          : data.renewal.status === "declined" || data.renewal.status === "lapsed"
                            ? "bad"
                            : "warn"
                      }
                    >
                      {data.renewal.status}
                    </Pill>
                  </div>
                  <p className="mt-1 text-xs text-muted-foreground">
                    {day(data.renewal.term_start)} → {day(data.renewal.term_end)} at{" "}
                    {money(data.renewal.proposed_annual_value_minor, data.renewal.currency)} a year,
                    an uplift of {data.renewal.uplift_pct}%. Notice by{" "}
                    {day(data.renewal.notice_deadline)}.
                  </p>
                </div>
              ) : null}
            </Section>
          ) : null}

          {data.contract ? (
            <Section
              title={ui("Documents")}
              description={ui(
                "Every document that constitutes the agreement, versioned and signed, with the checksum of what was signed.",
              )}
            >
              {data.documents.length === 0 ? (
                <p className="text-sm text-muted-foreground">{ui("None is listed.")}</p>
              ) : (
                <Table columns={["Document", "Kind", "Version", "Signed", "Checksum", ""]}>
                  {data.documents.map((d) => (
                    <Fragment key={d.id}>
                      <tr className="border-b border-border/50 align-top last:border-0">
                        <td className="py-2 pr-4 text-sm">
                          {d.title}
                          {d.superseded_by ? (
                            <span className="ml-2 text-xs text-muted-foreground">superseded</span>
                          ) : null}
                        </td>
                        <td className="py-2 pr-4 text-xs">{d.kind.replace(/_/g, " ")}</td>
                        <td className="py-2 pr-4 text-sm tabular-nums">{d.version}</td>
                        <td className="py-2 pr-4 text-xs">
                          {d.signed_at ? day(d.signed_at) : <Pill tone="warn">unsigned</Pill>}
                        </td>
                        <td className="py-2 pr-4 font-mono text-xs text-muted-foreground">
                          {d.checksum.slice(0, 12)}…
                        </td>
                        <td className="py-2">
                          <button
                            type="button"
                            className={`${TOUCH} inline-flex items-center rounded-md border border-input px-3 text-xs font-medium`}
                            onClick={() => setShownDoc(shownDoc === d.id ? null : d.id)}
                          >
                            {shownDoc === d.id ? "Close" : ui("Open")}
                          </button>
                        </td>
                      </tr>
                      {shownDoc === d.id ? (
                        <tr className="border-b border-border/50 last:border-0">
                          <td colSpan={6} className="pb-3">
                            {doc.isPending ? (
                              <p className="text-xs text-muted-foreground">Loading…</p>
                            ) : doc.error ? (
                              <p className="text-xs text-destructive">
                                {friendlyError(doc.error).title}
                              </p>
                            ) : doc.data ? (
                              <div>
                                <p className="text-xs text-muted-foreground">
                                  {doc.data.signature_meaning
                                    ? `Signed to mean: ${doc.data.signature_meaning}. `
                                    : ""}
                                  Checksum <span className="font-mono">{doc.data.checksum}</span>
                                </p>
                                <pre className="mt-2 max-h-96 overflow-auto whitespace-pre-wrap rounded bg-muted p-3 text-xs">
                                  {doc.data.content}
                                </pre>
                              </div>
                            ) : null}
                          </td>
                        </tr>
                      ) : null}
                    </Fragment>
                  ))}
                </Table>
              )}
            </Section>
          ) : null}

          <Section
            title="Entitlements"
            description="Each limit, against what has been used. A contract band overrides the plan's figure and says so. Remaining is empty where no limit is set. A breached entitlement is one the database is already refusing on."
          >
            {data.entitlements.length === 0 ? (
              <p className="text-sm text-muted-foreground">No limit is set.</p>
            ) : (
              <Table columns={["Entitlement", "Used", "Limit", "Remaining", "From", "State"]}>
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
                      {e.used != null ? e.used.toLocaleString() : "—"} {e.unit}
                    </td>
                    <td className="py-2 pr-4 text-sm tabular-nums">
                      {e.limit_value != null ? e.limit_value.toLocaleString() : "Unlimited"}
                    </td>
                    <td className="py-2 pr-4 text-sm tabular-nums">
                      {e.remaining != null ? e.remaining.toLocaleString() : "—"}
                    </td>
                    <td className="py-2 pr-4 text-xs">
                      <Pill tone={e.source === "contract" ? "ok" : "muted"}>{e.source}</Pill>
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
            title={ui("What you will pay next")}
            description={ui(
              "Each invoice in the schedule, and the metering behind any overage. A scheduled invoice shows the overage it would carry today, from the same meters you see above.",
            )}
          >
            {data.invoices.length === 0 ? (
              <p className="text-sm text-muted-foreground">{ui("Nothing is scheduled.")}</p>
            ) : (
              <Table
                columns={[
                  "Reference",
                  "Period",
                  "Due",
                  ui("Subscription"),
                  ui("Overage"),
                  "Total",
                  "State",
                ]}
              >
                {data.invoices.map((i) => {
                  const overage =
                    i.status === "scheduled"
                      ? i.lines
                          .filter((l) => l.kind === "overage")
                          .reduce((a, l) => a + l.net_minor, 0)
                      : i.overage_minor;
                  const total =
                    i.status === "scheduled" ? i.subscription_minor + overage : i.total_minor;
                  return (
                    <Fragment key={i.id}>
                      <tr className="border-b border-border/50 align-top last:border-0">
                        <td className="py-2 pr-4">
                          <button
                            type="button"
                            className="font-mono text-xs underline underline-offset-2"
                            onClick={() => setOpenInvoice(openInvoice === i.id ? null : i.id)}
                          >
                            {i.reference}
                          </button>
                        </td>
                        <td className="py-2 pr-4 text-xs">
                          {day(i.period_start)} → {day(i.period_end)}
                        </td>
                        <td className="py-2 pr-4 text-xs">{day(i.due_on)}</td>
                        <td className="py-2 pr-4 text-sm tabular-nums">
                          {money(i.subscription_minor, i.currency)}
                        </td>
                        <td className="py-2 pr-4 text-sm tabular-nums">
                          {money(overage, i.currency)}
                          {i.lines.some((l) => l.kind === "overage" && l.unpriced) ? (
                            <Pill tone="bad">unpriced</Pill>
                          ) : null}
                        </td>
                        <td className="py-2 pr-4 text-sm tabular-nums">
                          {money(total, i.currency)}
                        </td>
                        <td className="py-2">
                          <Pill
                            tone={
                              i.status === "paid" ? "ok" : i.status === "issued" ? "warn" : "muted"
                            }
                          >
                            {i.status}
                          </Pill>
                        </td>
                      </tr>
                      {openInvoice === i.id ? (
                        <tr className="border-b border-border/50 last:border-0">
                          <td colSpan={7} className="pb-3">
                            {i.lines.length === 0 ? (
                              <p className="text-xs text-muted-foreground">
                                No overage; the subscription alone.
                              </p>
                            ) : (
                              <Table columns={["Line", "Used", "Limit", "Over", "Unit", "Net"]}>
                                {i.lines.map((l, n) => (
                                  <tr key={n} className="border-b border-border/50 last:border-0">
                                    {l.kind === "subscription" ? (
                                      <>
                                        <td className="py-1.5 pr-4 text-xs" colSpan={5}>
                                          {l.description}
                                        </td>
                                        <td className="py-1.5 text-sm tabular-nums">
                                          {money(l.net_minor, i.currency)}
                                        </td>
                                      </>
                                    ) : (
                                      <>
                                        <td className="py-1.5 pr-4 text-xs">
                                          {l.entitlement_code.replace(/_/g, " ")} · {day(l.month)}
                                        </td>
                                        <td className="py-1.5 pr-4 text-xs tabular-nums">
                                          {l.used.toLocaleString()}
                                        </td>
                                        <td className="py-1.5 pr-4 text-xs tabular-nums">
                                          {l.limit_value == null
                                            ? "—"
                                            : l.limit_value.toLocaleString()}
                                        </td>
                                        <td className="py-1.5 pr-4 text-xs tabular-nums">
                                          {l.over.toLocaleString()}
                                        </td>
                                        <td className="py-1.5 pr-4 text-xs tabular-nums">
                                          {l.unit_minor == null ? (
                                            <Pill tone="bad">unpriced</Pill>
                                          ) : (
                                            `${l.unit_minor}p · ${l.band ?? ""}`
                                          )}
                                        </td>
                                        <td className="py-1.5 text-sm tabular-nums">
                                          {money(l.net_minor, i.currency)}
                                        </td>
                                      </>
                                    )}
                                  </tr>
                                ))}
                              </Table>
                            )}
                          </td>
                        </tr>
                      ) : null}
                    </Fragment>
                  );
                })}
              </Table>
            )}
          </Section>

          <Section
            title="Features the agreement allows"
            description="A feature outside this list cannot be switched on for the organisation, whatever pack or preset asks for it. The contract may add features beyond the plan."
          >
            {data.capabilities.length === 0 ? (
              <p className="text-sm text-muted-foreground">
                The plan names no features, so every one the product has is available.
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
                      {m.quantity != null ? m.quantity.toLocaleString() : "—"} {m.unit ?? ""}
                    </td>
                    <td className="py-2 text-xs text-muted-foreground">
                      {new Date(m.measured_at).toLocaleString()}
                    </td>
                  </tr>
                ))}
              </Table>
            )}
          </Section>

          <Section
            title={ui("Sub-processors")}
            description={ui(
              "Who processes your data on the platform's behalf, when each was added, and when you were told. A sub-processor is notified before it is added.",
            )}
          >
            {data.sub_processors.length === 0 ? (
              <p className="text-sm text-muted-foreground">{ui("None is listed.")}</p>
            ) : (
              <Table columns={["Sub-processor", "Purpose", "Location", "Added", "Notified"]}>
                {data.sub_processors.map((s) => (
                  <tr
                    key={s.code}
                    className={`border-b border-border/50 align-top last:border-0 ${s.withdrawn_at ? "opacity-60" : ""}`}
                  >
                    <td className="py-2 pr-4 text-sm">
                      {s.name}
                      {s.withdrawn_at ? (
                        <span className="ml-2 text-xs text-muted-foreground">
                          withdrawn {day(s.withdrawn_at)}
                        </span>
                      ) : null}
                    </td>
                    <td className="py-2 pr-4 text-xs">{s.purpose}</td>
                    <td className="py-2 pr-4 text-xs">{s.location}</td>
                    <td className="py-2 pr-4 text-xs">{day(s.added_at)}</td>
                    <td className="py-2 text-xs">
                      {s.notified_at ? day(s.notified_at) : <Pill tone="bad">not notified</Pill>}
                    </td>
                  </tr>
                ))}
              </Table>
            )}
          </Section>

          <Section
            title={ui("Service commitments")}
            description="What the platform commits to, where each figure comes from, and the remedy when it is missed."
          >
            {data.service_commitments.length === 0 ? (
              <p className="text-sm text-muted-foreground">{ui("None is listed.")}</p>
            ) : (
              <Table columns={["Commitment", "Level", "Derived from", "Remedy"]}>
                {data.service_commitments.map((s) => (
                  <tr key={s.code} className="border-b border-border/50 align-top last:border-0">
                    <td className="py-2 pr-4 text-sm">{s.title}</td>
                    <td className="py-2 pr-4 text-xs">{s.commitment}</td>
                    <td className="py-2 pr-4 text-xs text-muted-foreground">{s.derived_from}</td>
                    <td className="py-2 text-xs text-muted-foreground">{s.remedy}</td>
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
