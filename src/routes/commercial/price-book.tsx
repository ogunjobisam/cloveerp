import { friendlyError } from "@/lib/errors";
import { useQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import type { ReactNode } from "react";

import { ActionDialog } from "../../components/erp/action";
import { Gate } from "../../components/erp/gate";
import { PageHeader, Prose, TOUCH } from "../../components/erp/page";
import { Pill, Table } from "../../components/erp/panel";
import { useErpSession } from "../../components/erp/session-context";
import { callErp, hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";

/**
 * The platform's price book. Specification v1.5 §17.5 and §17.6.
 *
 * Kept inside the platform's own organisation on its own primitives: a price
 * item is a product with a commercial shape, a price book is a configuration
 * object, the rate card is per currency and term, and the cost model sits
 * beside each rate so margin is visible while quoting (D36). Any other
 * organisation that reaches this path is told whose screen it is.
 */

export const Route = createFileRoute("/commercial/price-book")({
  head: () => ({
    meta: [
      { title: "Price book — Clove ERP" },
      {
        name: "description",
        content: "Effective-dated price books, entitlement kinds and customer-specific pricing.",
      },
      { property: "og:title", content: "Price book — Clove ERP" },
      {
        property: "og:description",
        content: "Effective-dated price books, entitlement kinds and customer-specific pricing.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <PriceBook />
    </Gate>
  ),
});

type Rate = {
  price_book_code: string;
  term_kind: string;
  currency: string;
  amount_minor: number;
  valid_from: string;
  valid_to: string | null;
  unit_cost_minor: number | null;
  margin_pct: number | null;
};

type Cost = {
  currency: string;
  infrastructure_minor: number;
  support_minor: number;
  pass_through_minor: number;
  unit_cost_minor: number;
  basis: string | null;
  effective_from: string;
};

type Item = {
  code: string;
  name: string;
  kind: string;
  status: string;
  plan_code: string | null;
  capability_code: string | null;
  entitlement_code: string | null;
  band_from: number | null;
  band_to: number | null;
  legislation_pack_code: string | null;
  support_severity_code: string | null;
  description: string | null;
  rates: Rate[];
  costs: Cost[];
};

type Book = {
  code: string;
  name: string;
  note: string | null;
  currencies: string[];
  version: number;
  effective_from: string;
  effective_to: string | null;
  status: string;
};

type PriceBookReport = {
  is_platform_organisation: boolean;
  books: Book[];
  items: Item[];
  plans: { code: string; name: string }[];
  entitlement_kinds: { code: string; title: string; unit: string }[];
  capabilities: string[];
  severities: { code: string; name: string }[];
  legislation_packs: { code: string; jurisdiction: string }[];
  findings: { finding: string; reference: string; detail: string }[];
};

const KINDS = [
  { value: "plan_tier", label: "Plan tier" },
  { value: "capability_addon", label: "Feature add-on" },
  { value: "user_band", label: "User band" },
  { value: "company_band", label: "Company band" },
  { value: "site_band", label: "Site band" },
  { value: "volume_band", label: "Volume band" },
  { value: "storage_band", label: "Storage band" },
  { value: "retention_band", label: "Retention band" },
  { value: "environment", label: "Environment" },
  { value: "support_tier", label: "Support tier" },
  { value: "service", label: "Fixed-price service" },
  { value: "legislation_pack", label: "Legislation pack" },
];

const TERMS = [
  { value: "annual", label: "Annual" },
  { value: "multi_year", label: "Multi-year" },
  { value: "monthly", label: "Monthly" },
];

function money(minor: number | null | undefined, currency?: string) {
  if (minor == null) return "—";
  const major = minor / 100;
  return `${major.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}${
    currency ? ` ${currency}` : ""
  }`;
}

function day(value: string | null) {
  return value ? new Date(value).toLocaleDateString() : "—";
}

function Section({
  title,
  description,
  action,
  children,
}: {
  title: string;
  description?: string;
  action?: ReactNode;
  children: ReactNode;
}) {
  return (
    <section className="min-w-0 rounded-xl border border-border bg-card">
      <header className="flex flex-wrap items-start justify-between gap-3 border-b border-border px-4 py-4 sm:px-5">
        <div>
          <h2 className="text-sm font-semibold">{title}</h2>
          {description ? (
            <Prose className="mt-0.5 text-xs text-muted-foreground">{description}</Prose>
          ) : null}
        </div>
        {action}
      </header>
      <div className="px-4 py-4 sm:px-5">{children}</div>
    </section>
  );
}

function PriceBook() {
  const { ui } = useT();
  const { session } = useErpSession();
  const mayPrice = hasPermission(session, "sales.price");

  const q = useQuery({
    queryKey: ["erp_price_book"],
    queryFn: () => callErp<PriceBookReport>("erp_price_book"),
    refetchInterval: 60_000,
  });

  const currencies = Array.from(new Set((q.data?.books ?? []).flatMap((b) => b.currencies)));

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={ui("Price book")}>
        {ui(
          "Each price item is a product of this organisation with a commercial shape: a plan tier, a feature add-on, a band of an entitlement, an environment, a support tier, a fixed-price service, or a legislation pack at nil. Rates are maintained per currency and term; the cost beside each rate is what makes margin visible while quoting.",
        )}
      </PageHeader>

      {q.isPending ? (
        <p className="text-sm text-muted-foreground">Loading…</p>
      ) : q.error ? (
        <div role="alert" className="rounded-xl border border-border bg-card p-4 sm:p-5">
          <p className="text-sm font-medium text-destructive">This did not load.</p>
          <p className="mt-1 text-xs text-muted-foreground">{friendlyError(q.error).title}</p>
        </div>
      ) : !q.data ? null : !q.data.is_platform_organisation ? (
        <p className="rounded-xl border border-border bg-card p-4 text-sm text-muted-foreground sm:p-5">
          {ui(
            "This organisation is not the platform's. The price book, quotes and contracts belong to the organisation a platform owner designates as the platform; every other organisation sees its own agreement under Plan and usage.",
          )}
        </p>
      ) : (
        <>
          {q.data.findings.length > 0 ? (
            <ul
              className="flex flex-col gap-1 rounded-xl border border-destructive/40 bg-card p-4"
              role="alert"
            >
              {q.data.findings.map((f, i) => (
                <li key={`${f.finding}-${i}`} className="text-xs text-destructive">
                  <span className="font-medium">{f.finding}</span> · {f.reference}: {f.detail}
                </li>
              ))}
            </ul>
          ) : null}

          <Section
            title={ui("Price books")}
            description={ui(
              "A price book is a configuration object: versioned, effective-dated, per currency. A quote names the version in force when it was raised, so a historical quote can always be explained.",
            )}
            action={
              mayPrice ? (
                <ActionDialog
                  trigger={
                    <span
                      className={`${TOUCH} inline-flex items-center rounded-md bg-primary px-3 text-sm font-semibold text-primary-foreground`}
                    >
                      {ui("Open a price book")}
                    </span>
                  }
                  title={ui("Open a price book")}
                  permission="sales.price"
                  fn="erp_open_price_book"
                  fields={[
                    { kind: "text", name: "p_code", label: "Code", required: true },
                    { kind: "text", name: "p_name", label: "Name", required: true },
                    {
                      kind: "text",
                      name: "p_currencies",
                      label: ui("Currencies"),
                      required: true,
                      hint: "Three-letter codes separated by commas, for example GBP, EUR.",
                    },
                    { kind: "date", name: "p_effective_from", label: ui("Effective from") },
                    { kind: "text", name: "p_note", label: "Note" },
                  ]}
                  mapArgs={(v) => ({
                    p_code: v["p_code"],
                    p_name: v["p_name"],
                    p_currencies: (v["p_currencies"] ?? "")
                      .split(",")
                      .map((c) => c.trim().toUpperCase())
                      .filter(Boolean),
                    p_effective_from: v["p_effective_from"] || null,
                    p_note: v["p_note"] || null,
                  })}
                  invalidates={["erp_price_book"]}
                  submitLabel={ui("Open a price book")}
                />
              ) : null
            }
          >
            {q.data.books.length === 0 ? (
              <p className="text-sm text-muted-foreground">{ui("No price book is open.")}</p>
            ) : (
              <Table
                columns={[
                  "Code",
                  "Name",
                  ui("Currencies"),
                  "Version",
                  ui("Effective from"),
                  "State",
                ]}
              >
                {q.data.books.map((b) => (
                  <tr
                    key={`${b.code}-${b.version}`}
                    className="border-b border-border/50 align-top last:border-0"
                  >
                    <td className="py-2 pr-4 font-mono text-xs">{b.code}</td>
                    <td className="py-2 pr-4 text-sm">
                      {b.name}
                      {b.note ? (
                        <div className="text-xs text-muted-foreground">{b.note}</div>
                      ) : null}
                    </td>
                    <td className="py-2 pr-4 font-mono text-xs">{b.currencies.join(", ")}</td>
                    <td className="py-2 pr-4 text-sm tabular-nums">{b.version}</td>
                    <td className="py-2 pr-4 text-xs text-muted-foreground">
                      {day(b.effective_from)}
                      {b.effective_to ? ` → ${day(b.effective_to)}` : ""}
                    </td>
                    <td className="py-2">
                      <Pill tone={b.status === "active" ? "ok" : "muted"}>{b.status}</Pill>
                    </td>
                  </tr>
                ))}
              </Table>
            )}
          </Section>

          <Section
            title={ui("What is sold")}
            description={ui(
              "Legislation packs are priced at nil. Charging annually for a jurisdiction is the practice this product exists to end, and the zero on the book makes that visible rather than tacit.",
            )}
            action={
              mayPrice ? (
                <div className="flex flex-wrap gap-2">
                  <ActionDialog
                    trigger={
                      <span
                        className={`${TOUCH} inline-flex items-center rounded-md bg-primary px-3 text-sm font-semibold text-primary-foreground`}
                      >
                        {ui("Add a price item")}
                      </span>
                    }
                    title={ui("Add a price item")}
                    permission="sales.price"
                    fn="erp_upsert_price_item"
                    fields={[
                      { kind: "text", name: "p_code", label: "Code", required: true },
                      { kind: "text", name: "p_name", label: "Name", required: true },
                      {
                        kind: "choice",
                        name: "p_kind",
                        label: ui("Kind"),
                        required: true,
                        choices: KINDS,
                      },
                      {
                        kind: "choice",
                        name: "p_plan_code",
                        label: ui("Plan"),
                        choices: q.data.plans.map((p) => ({ value: p.code, label: p.name })),
                      },
                      {
                        kind: "choice",
                        name: "p_capability_code",
                        label: ui("Feature"),
                        choices: q.data.capabilities.map((c) => ({ value: c, label: c })),
                      },
                      {
                        kind: "choice",
                        name: "p_entitlement_code",
                        label: ui("Entitlement"),
                        choices: q.data.entitlement_kinds.map((k) => ({
                          value: k.code,
                          label: `${k.title} (${k.unit})`,
                        })),
                      },
                      { kind: "number", name: "p_band_from", label: ui("Band from") },
                      { kind: "number", name: "p_band_to", label: ui("Band to") },
                      {
                        kind: "choice",
                        name: "p_legislation_pack_code",
                        label: ui("Legislation pack"),
                        choices: q.data.legislation_packs.map((l) => ({
                          value: l.code,
                          label: `${l.code} · ${l.jurisdiction}`,
                        })),
                      },
                      {
                        kind: "choice",
                        name: "p_support_severity_code",
                        label: ui("Severity"),
                        choices: q.data.severities.map((s) => ({ value: s.code, label: s.name })),
                      },
                      { kind: "text", name: "p_description", label: "Description" },
                    ]}
                    mapArgs={(v) => ({
                      p_code: v["p_code"],
                      p_name: v["p_name"],
                      p_kind: v["p_kind"],
                      p_plan_code: v["p_plan_code"] || null,
                      p_capability_code: v["p_capability_code"] || null,
                      p_entitlement_code: v["p_entitlement_code"] || null,
                      p_band_from: v["p_band_from"] ? Number(v["p_band_from"]) : null,
                      p_band_to: v["p_band_to"] ? Number(v["p_band_to"]) : null,
                      p_legislation_pack_code: v["p_legislation_pack_code"] || null,
                      p_support_severity_code: v["p_support_severity_code"] || null,
                      p_description: v["p_description"] || null,
                    })}
                    invalidates={["erp_price_book"]}
                    submitLabel={ui("Add a price item")}
                  />
                  <ActionDialog
                    trigger={
                      <span
                        className={`${TOUCH} inline-flex items-center rounded-md border border-input px-3 text-sm font-medium`}
                      >
                        {ui("Set a rate")}
                      </span>
                    }
                    title={ui("Set a rate")}
                    permission="sales.price"
                    fn="erp_set_rate"
                    fields={[
                      {
                        kind: "choice",
                        name: "p_price_book_code",
                        label: ui("Price book"),
                        required: true,
                        choices: Array.from(new Set(q.data.books.map((b) => b.code))).map((c) => ({
                          value: c,
                          label: c,
                        })),
                      },
                      {
                        kind: "choice",
                        name: "p_item_code",
                        label: "Product",
                        required: true,
                        choices: q.data.items.map((i) => ({
                          value: i.code,
                          label: `${i.code} · ${i.name}`,
                        })),
                      },
                      {
                        kind: "choice",
                        name: "p_currency",
                        label: "Currency",
                        required: true,
                        choices: currencies.map((c) => ({ value: c, label: c })),
                      },
                      {
                        kind: "choice",
                        name: "p_term_kind",
                        label: ui("Term"),
                        required: true,
                        choices: TERMS,
                      },
                      {
                        kind: "number",
                        name: "p_amount",
                        label: ui("Rate"),
                        required: true,
                        hint: "In major units per term, for example 12000 for twelve thousand a year.",
                      },
                    ]}
                    mapArgs={(v) => ({
                      p_price_book_code: v["p_price_book_code"],
                      p_item_code: v["p_item_code"],
                      p_currency: v["p_currency"],
                      p_term_kind: v["p_term_kind"],
                      p_amount_minor: Math.round(Number(v["p_amount"] ?? 0) * 100),
                    })}
                    invalidates={["erp_price_book"]}
                    submitLabel={ui("Set a rate")}
                  />
                  <ActionDialog
                    trigger={
                      <span
                        className={`${TOUCH} inline-flex items-center rounded-md border border-input px-3 text-sm font-medium`}
                      >
                        {ui("Set the cost")}
                      </span>
                    }
                    title={ui("Set the cost")}
                    permission="sales.price"
                    fn="erp_set_cost_model"
                    fields={[
                      {
                        kind: "choice",
                        name: "p_item_code",
                        label: "Product",
                        required: true,
                        choices: q.data.items.map((i) => ({
                          value: i.code,
                          label: `${i.code} · ${i.name}`,
                        })),
                      },
                      {
                        kind: "choice",
                        name: "p_currency",
                        label: "Currency",
                        required: true,
                        choices: currencies.map((c) => ({ value: c, label: c })),
                      },
                      { kind: "number", name: "p_infrastructure", label: ui("Infrastructure") },
                      { kind: "number", name: "p_support", label: ui("Support load") },
                      { kind: "number", name: "p_pass_through", label: ui("Pass-through") },
                      { kind: "text", name: "p_basis", label: ui("Basis") },
                    ]}
                    mapArgs={(v) => ({
                      p_item_code: v["p_item_code"],
                      p_currency: v["p_currency"],
                      p_infrastructure_minor: Math.round(Number(v["p_infrastructure"] ?? 0) * 100),
                      p_support_minor: Math.round(Number(v["p_support"] ?? 0) * 100),
                      p_pass_through_minor: Math.round(Number(v["p_pass_through"] ?? 0) * 100),
                      p_basis: v["p_basis"] || null,
                    })}
                    invalidates={["erp_price_book"]}
                    submitLabel={ui("Set the cost")}
                  />
                </div>
              ) : null
            }
          >
            {q.data.items.length === 0 ? (
              <p className="text-sm text-muted-foreground">
                {ui("Nothing is on the price book yet.")}
              </p>
            ) : (
              <ul className="flex flex-col gap-5">
                {q.data.items.map((item) => (
                  <li
                    key={item.code}
                    className="border-b border-border/60 pb-5 last:border-0 last:pb-0"
                  >
                    <div className="flex flex-wrap items-center gap-2">
                      <span className="text-sm font-semibold">{item.name}</span>
                      <span className="font-mono text-xs text-muted-foreground">{item.code}</span>
                      <Pill tone="muted">
                        {KINDS.find((k) => k.value === item.kind)?.label ?? item.kind}
                      </Pill>
                      {item.plan_code ? <Pill tone="ok">{item.plan_code}</Pill> : null}
                      {item.capability_code ? <Pill tone="ok">{item.capability_code}</Pill> : null}
                      {item.entitlement_code ? (
                        <Pill tone="ok">
                          {item.entitlement_code} {item.band_from ?? 0}–{item.band_to}
                        </Pill>
                      ) : null}
                      {item.support_severity_code ? (
                        <Pill tone="ok">{item.support_severity_code}</Pill>
                      ) : null}
                      {item.legislation_pack_code ? (
                        <Pill tone="warn">
                          {item.legislation_pack_code} · {ui("Priced at nil")}
                        </Pill>
                      ) : null}
                    </div>
                    {item.description ? (
                      <p className="mt-1 text-sm text-muted-foreground">{item.description}</p>
                    ) : null}
                    <div className="mt-2 grid gap-4 md:grid-cols-2">
                      <div>
                        <h3 className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
                          {ui("Rate")}
                        </h3>
                        {item.rates.length === 0 ? (
                          <p className="mt-1 text-xs text-muted-foreground">{ui("No rate")}</p>
                        ) : (
                          <Table
                            columns={[
                              ui("Price book"),
                              ui("Term"),
                              ui("Rate"),
                              ui("Cost"),
                              ui("Margin"),
                            ]}
                          >
                            {item.rates.map((r) => (
                              <tr
                                key={`${r.price_book_code}-${r.term_kind}-${r.currency}`}
                                className="border-b border-border/50 last:border-0"
                              >
                                <td className="py-1.5 pr-3 font-mono text-xs">
                                  {r.price_book_code}
                                </td>
                                <td className="py-1.5 pr-3 text-xs">
                                  {TERMS.find((t) => t.value === r.term_kind)?.label ?? r.term_kind}
                                </td>
                                <td className="py-1.5 pr-3 text-xs tabular-nums">
                                  {money(r.amount_minor, r.currency)}
                                </td>
                                <td className="py-1.5 pr-3 text-xs tabular-nums">
                                  {money(r.unit_cost_minor)}
                                </td>
                                <td className="py-1.5 text-xs tabular-nums">
                                  {r.margin_pct == null ? (
                                    <Pill
                                      tone={item.kind === "legislation_pack" ? "muted" : "warn"}
                                    >
                                      {item.kind === "legislation_pack" ? "nil" : ui("No cost")}
                                    </Pill>
                                  ) : (
                                    <Pill
                                      tone={
                                        r.margin_pct < 0 ? "bad" : r.margin_pct < 20 ? "warn" : "ok"
                                      }
                                    >
                                      {r.margin_pct}%
                                    </Pill>
                                  )}
                                </td>
                              </tr>
                            ))}
                          </Table>
                        )}
                      </div>
                      <div>
                        <h3 className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
                          {ui("Cost")}
                        </h3>
                        {item.costs.length === 0 ? (
                          <p className="mt-1 text-xs text-muted-foreground">{ui("No cost")}</p>
                        ) : (
                          <Table
                            columns={[
                              "Currency",
                              ui("Infrastructure"),
                              ui("Support load"),
                              ui("Pass-through"),
                              ui("Basis"),
                            ]}
                          >
                            {item.costs.map((c) => (
                              <tr
                                key={c.currency}
                                className="border-b border-border/50 last:border-0"
                              >
                                <td className="py-1.5 pr-3 font-mono text-xs">{c.currency}</td>
                                <td className="py-1.5 pr-3 text-xs tabular-nums">
                                  {money(c.infrastructure_minor)}
                                </td>
                                <td className="py-1.5 pr-3 text-xs tabular-nums">
                                  {money(c.support_minor)}
                                </td>
                                <td className="py-1.5 pr-3 text-xs tabular-nums">
                                  {money(c.pass_through_minor)}
                                </td>
                                <td className="py-1.5 text-xs text-muted-foreground">
                                  {c.basis ?? "—"}
                                </td>
                              </tr>
                            ))}
                          </Table>
                        )}
                      </div>
                    </div>
                  </li>
                ))}
              </ul>
            )}
          </Section>
        </>
      )}
    </div>
  );
}
