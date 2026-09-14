import { useQuery, type UseQueryResult } from "@tanstack/react-query";
import { ArrowRight, CheckCircle2 } from "lucide-react";

import { callErp } from "../../lib/erp";
import type {
  CheckResult,
  OpenInvoice,
  OwnershipTransfer,
  PlatformTenant,
  SupportWindow,
} from "../../lib/platform";
import {
  assuranceCards,
  enquiryCards,
  healthSummary,
  incidentCards,
  invoiceCards,
  organisationCards,
  paymentDetailsCards,
  revenueCards,
  sellingCards,
  summariseToday,
  supportWindowCards,
  transferCards,
  type BillingDetailsRead,
  type EnquiryRow,
  type IncidentRow,
  type RevenueRead,
  type SellingRead,
  type TodayCard,
  type TodaySource,
} from "../../lib/platform-today";
import { Card, ConsoleLink, Fail, LINK_BUTTON } from "./kit";

/**
 * Today: the console's landing page.
 *
 * The owner opened the console and asked for it to make running the platform
 * easy. What that asks of a first screen is not a list of places but a list of
 * things to do: each card is a count, one sentence saying what it means, and a
 * button to the exact tab that deals with it.
 *
 * Every read here is one another tab already makes, under the same query key
 * and with the same arguments, so opening the tab after the card costs nothing
 * and shows the same rows. Each is read on its own: a door that refuses or
 * fails shows its own error in its own card and takes nothing else with it.
 * What deserves a card is decided in src/lib/platform-today.ts, where it is
 * tested.
 */

function source<T>(
  key: string,
  label: string,
  query: UseQueryResult<T>,
  cards: (data: T) => TodayCard[],
): TodaySource {
  if (query.isPending) return { key, label, state: "pending" };
  if (query.isError) return { key, label, state: "error", error: query.error };
  return { key, label, state: "ready", cards: cards(query.data) };
}

export function Today() {
  const incidents = useQuery({
    queryKey: ["erp_platform_incidents"],
    queryFn: () => callErp<IncidentRow[]>("erp_platform_incidents"),
  });
  // The cheap one: pass or fail for every registered check, no findings.
  const assurance = useQuery({
    queryKey: ["erp_platform_assurance"],
    queryFn: () => callErp<CheckResult[]>("erp_platform_assurance"),
  });
  const revenue = useQuery({
    queryKey: ["erp_platform_revenue"],
    queryFn: () => callErp<RevenueRead>("erp_platform_revenue"),
  });
  const enquiries = useQuery({
    queryKey: ["erp_platform_enquiries"],
    queryFn: () => callErp<EnquiryRow[]>("erp_platform_enquiries", { p_limit: 200 }),
  });
  const transfers = useQuery({
    queryKey: ["erp_platform_ownership_transfers"],
    queryFn: () =>
      callErp<OwnershipTransfer[]>("erp_platform_ownership_transfers", {
        p_tenant_id: null,
        p_limit: 200,
      }),
  });
  const tenants = useQuery({
    queryKey: ["erp_platform_tenants"],
    queryFn: () => callErp<PlatformTenant[]>("erp_platform_tenants"),
  });
  const selling = useQuery({
    queryKey: ["erp_platform_commercial_state"],
    queryFn: () => callErp<SellingRead>("erp_platform_commercial_state"),
  });
  const invoices = useQuery({
    queryKey: ["erp_platform_open_invoices"],
    queryFn: () => callErp<OpenInvoice[]>("erp_platform_open_invoices"),
  });
  const payment = useQuery({
    queryKey: ["erp_platform_billing_details"],
    queryFn: () => callErp<BillingDetailsRead>("erp_platform_billing_details"),
  });
  const windows = useQuery({
    queryKey: ["erp_platform_support_windows"],
    queryFn: () => callErp<SupportWindow[]>("erp_platform_support_windows"),
  });

  const now = new Date();
  const summary = summariseToday([
    source("incidents", "Incidents", incidents, (rows) => incidentCards(rows ?? [])),
    source("assurance", "Checks", assurance, (rows) => assuranceCards(rows ?? [])),
    source("revenue", "Renewals", revenue, (d) => (d ? revenueCards(d) : [])),
    source("invoices", "Invoices", invoices, (rows) => invoiceCards(rows ?? [])),
    source("enquiries", "Enquiries", enquiries, (rows) => enquiryCards(rows ?? [], now)),
    source("transfers", "Ownership transfers", transfers, (rows) => transferCards(rows ?? [])),
    source("organisations", "Organisations", tenants, (rows) => organisationCards(rows ?? [])),
    source("windows", "Support windows", windows, (rows) => supportWindowCards(rows ?? [], now)),
    source("selling", "Selling setup", selling, (d) => (d ? sellingCards(d) : [])),
    source("payment", "Payment details", payment, (d) => (d ? paymentDetailsCards(d) : [])),
  ]);

  const health = assurance.data ? healthSummary(assurance.data) : null;

  return (
    <div className="flex flex-col gap-5">
      {summary.allClear ? (
        <section className="surface-card rounded-xl border border-emerald-500/40 bg-emerald-500/5 p-6">
          <h2 className="flex items-center gap-2 font-display text-lg font-semibold">
            <CheckCircle2 className="size-5 text-emerald-600 dark:text-emerald-400" />
            Nothing needs you today
          </h2>
          <p className="mt-2 text-sm text-muted-foreground">
            {health && health.passing > 0
              ? `All ${health.passing} checks on this deployment pass${
                  health.needOrganisation > 0
                    ? `, and ${health.needOrganisation} more run inside each organisation`
                    : ""
                }.`
              : "Every check on this deployment holds."}{" "}
            No incident is open, no renewal or invoice is waiting, and every organisation is
            running.
          </p>
          <ConsoleLink
            section="platform"
            view="health"
            className={`${LINK_BUTTON} mt-4 bg-background`}
          >
            See the health summary
          </ConsoleLink>
        </section>
      ) : null}

      {summary.cards.length > 0 ? (
        <ul className="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
          {summary.cards.map((card) => (
            <li key={card.key} className="flex">
              <Attention card={card} />
            </li>
          ))}
        </ul>
      ) : null}

      {summary.failed.map((f) => (
        <Card key={f.key} title={`${f.label} could not be read`}>
          <Fail error={f.error} />
        </Card>
      ))}

      {summary.pending.length > 0 ? (
        <p role="status" className="text-sm text-muted-foreground">
          Still checking: {summary.pending.map((p) => p.label.toLowerCase()).join(", ")}…
        </p>
      ) : summary.cards.length === 0 && summary.failed.length > 0 ? (
        <p className="text-sm text-muted-foreground">
          Nothing else needs you today, as far as the rest could be read.
        </p>
      ) : null}
    </div>
  );
}

function Attention({ card }: { card: TodayCard }) {
  const bad = card.tone === "bad";
  return (
    <section
      className={`surface-card flex w-full flex-col rounded-xl border bg-card p-5 ${
        bad ? "border-destructive/40" : "border-amber-500/40"
      }`}
    >
      <div className="flex items-baseline gap-3">
        <span
          className={`font-display text-3xl font-semibold tabular-nums ${
            bad ? "text-destructive" : "text-amber-700 dark:text-amber-400"
          }`}
        >
          {card.figure}
        </span>
        <h2 className="text-sm font-semibold">{card.title}</h2>
      </div>
      <p className="mt-2 flex-1 text-sm text-muted-foreground">{card.sentence}</p>
      <ConsoleLink
        section={card.target.section}
        view={card.target.view}
        org={card.target.org}
        className={`${LINK_BUTTON} mt-4 self-start`}
      >
        {card.action}
        <ArrowRight className="size-4" />
      </ConsoleLink>
    </section>
  );
}
