import { friendlyError } from "@/lib/errors";
import { useQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useState, type ReactNode } from "react";

import { ActionDialog, ErrorNote, useErpAction } from "../../components/erp/action";
import { Gate } from "../../components/erp/gate";
import { PageHeader, Prose, TOUCH } from "../../components/erp/page";
import { Pill, Table } from "../../components/erp/panel";
import { useErpSession } from "../../components/erp/session-context";
import { callErp, hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";

/**
 * The quote and pricing builder. Specification v1.5 §17.7.
 *
 * A quote is a quotation document of the platform organisation. Its lines are
 * price items at the rate card price; margin is read live per line and in
 * total (D36); a discount beyond the threshold is routed through the approval
 * engine; every version is retained; the order form is the quote rendered.
 */

export const Route = createFileRoute("/commercial/quotes")({
  head: () => ({
    meta: [
      { title: "Quotes — Clove ERP" },
      { name: "description", content: "Quotations, versions and conversion into customer orders." },
      { property: "og:title", content: "Quotes — Clove ERP" },
      { property: "og:description", content: "Quotations, versions and conversion into customer orders." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <Quotes />
    </Gate>
  ),
});

type QuoteRow = {
  document_id: string;
  document_number: string;
  version: number;
  party_code: string | null;
  party_name: string | null;
  customer_tenant_code: string | null;
  price_book: string;
  term_kind: string;
  term_months: number;
  currency: string;
  valid_until: string;
  state: string;
  supersedes: string | null;
  superseded_by: string | null;
  issued_at: string | null;
  total_minor: number | null;
  margin_pct: number | null;
  created_at: string;
};

type QuotesReport = {
  is_platform_organisation: boolean;
  installed: boolean;
  threshold_pct: number | null;
  quotes: QuoteRow[];
  price_books: string[];
  price_items: { code: string; name: string; kind: string }[];
};

type MarginLine = {
  line_id: string;
  line_no: number;
  item_code: string;
  name: string;
  kind: string | null;
  quantity: number;
  list_minor: number;
  discount_pct: number;
  quoted_unit_minor: number;
  quoted_minor: number;
  cost_unit_minor: number | null;
  cost_minor: number | null;
  margin_minor: number | null;
  margin_pct: number | null;
  below_cost: boolean;
};

type QuoteDetail = {
  document_id: string;
  document_number: string;
  version: number;
  party_code: string | null;
  party_name: string | null;
  customer_tenant_code: string | null;
  price_book_code: string;
  price_book_version: number;
  term_kind: string;
  term_months: number;
  currency: string;
  valid_until: string;
  notes: string | null;
  state: string;
  supersedes: string | null;
  superseded_by: string | null;
  margin: {
    currency: string;
    threshold_pct: number | null;
    lines: MarginLine[];
    totals: {
      list_minor: number;
      quoted_minor: number;
      cost_minor: number;
      margin_minor: number;
      margin_pct: number | null;
      max_discount_pct: number;
      below_cost_lines: number;
      uncosted_lines: number;
    };
  };
  approval: {
    status: string;
    chain_code: string | null;
    outstanding: number;
    requested_at: string;
    decided_at: string | null;
  } | null;
  order_form: {
    render_id: string;
    checksum: string;
    rendered_at: string;
    byte_size: number;
    content: unknown;
  } | null;
  transitions: { code: string; name: string; to_state: string; permitted: boolean }[];
};

const TERMS = [
  { value: "annual", label: "Annual" },
  { value: "multi_year", label: "Multi-year" },
  { value: "monthly", label: "Monthly" },
];

function money(minor: number | null | undefined, currency?: string) {
  if (minor == null) return "—";
  return `${(minor / 100).toLocaleString(undefined, {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  })}${currency ? ` ${currency}` : ""}`;
}

function day(value: string | null) {
  return value ? new Date(value).toLocaleDateString() : "—";
}

function stateTone(state: string): "ok" | "warn" | "bad" | "muted" {
  if (state === "accepted" || state === "approved" || state === "issued") return "ok";
  if (state === "pending_approval" || state === "draft") return "warn";
  if (state === "declined" || state === "expired") return "bad";
  return "muted";
}

function marginTone(pct: number | null, belowCost = false): "ok" | "warn" | "bad" | "muted" {
  if (belowCost) return "bad";
  if (pct == null) return "muted";
  return pct < 0 ? "bad" : pct < 20 ? "warn" : "ok";
}

function Section({
  title,
  description,
  action,
  children,
}: {
  title: string;
  description?: string | undefined;
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

const button = (primary = false) =>
  `${TOUCH} inline-flex items-center rounded-md px-3 text-sm font-medium ${
    primary ? "bg-primary font-semibold text-primary-foreground" : "border border-input"
  }`;

function Quotes() {
  const { ui } = useT();
  const { session } = useErpSession();
  const mayQuote = hasPermission(session, "sales.order");
  const mayConfigure = hasPermission(session, "administration.configure");
  const [selected, setSelected] = useState<string | null>(null);

  const q = useQuery({
    queryKey: ["erp_commercial_quotes"],
    queryFn: () => callErp<QuotesReport>("erp_commercial_quotes"),
    refetchInterval: 60_000,
  });

  const install = useErpAction({
    fn: "erp_configure_commercial",
    invalidates: ["erp_commercial_quotes"],
  });

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={ui("Quotes")}>
        {ui(
          "A quote is assembled from price items, not typed. Margin shows live per line and in total against the cost model; a discount beyond the threshold is routed for approval; every version is retained; the order form is the quote rendered, not re-keyed.",
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
      ) : !q.data.installed ? (
        <div className="rounded-xl border border-border bg-card p-4 sm:p-5">
          <p className="text-sm text-muted-foreground">
            {ui(
              "The commercial module is not installed. Installing it is a configuration change: the quote lifecycle, the discount approval chain with its threshold, the order form template and the expiry job.",
            )}
          </p>
          {mayConfigure ? (
            <ActionDialog
              trigger={
                <span className={`${button(true)} mt-4`}>
                  {ui("Install the commercial module")}
                </span>
              }
              title={ui("Install the commercial module")}
              permission="administration.configure"
              fn="erp_configure_commercial"
              fields={[
                {
                  kind: "number",
                  name: "p_discount_threshold_pct",
                  label: ui("Discount threshold"),
                  hint: "A discount above this percentage on any line is routed for approval.",
                },
              ]}
              mapArgs={(v) => ({
                p_discount_threshold_pct: v["p_discount_threshold_pct"]
                  ? Number(v["p_discount_threshold_pct"])
                  : 10,
              })}
              invalidates={["erp_commercial_quotes"]}
              submitLabel={ui("Install the commercial module")}
            />
          ) : null}
          {install.error ? <ErrorNote error={install.error} /> : null}
        </div>
      ) : selected ? (
        <QuoteDetailPanel
          documentId={selected}
          priceItems={q.data.price_items}
          onBack={() => setSelected(null)}
          onOpen={(id) => setSelected(id)}
        />
      ) : (
        <>
          <Section
            title={ui("Quotes")}
            description={`${ui("Threshold")}: ${q.data.threshold_pct ?? "—"}%`}
            action={
              mayQuote ? (
                <ActionDialog
                  trigger={<span className={button(true)}>{ui("Open a quote")}</span>}
                  title={ui("Open a quote")}
                  permission="sales.order"
                  fn="erp_open_commercial_quote"
                  fields={[
                    {
                      kind: "text",
                      name: "p_party_code",
                      label: ui("Business partner code"),
                      required: true,
                    },
                    {
                      kind: "text",
                      name: "p_party_name",
                      label: ui("Business partner name"),
                      required: true,
                    },
                    {
                      kind: "choice",
                      name: "p_price_book_code",
                      label: ui("Price book"),
                      required: true,
                      choices: q.data.price_books.map((c) => ({ value: c, label: c })),
                    },
                    {
                      kind: "choice",
                      name: "p_term_kind",
                      label: ui("Term"),
                      required: true,
                      choices: TERMS,
                    },
                    { kind: "number", name: "p_term_months", label: ui("Term months") },
                    {
                      kind: "text",
                      name: "p_currency",
                      label: "Currency",
                      required: true,
                      hint: "GBP, EUR…",
                    },
                    { kind: "number", name: "p_valid_days", label: ui("Valid for days") },
                    {
                      kind: "text",
                      name: "p_customer_tenant_code",
                      label: ui("Customer organisation code"),
                    },
                    { kind: "text", name: "p_notes", label: "Notes" },
                  ]}
                  mapArgs={(v) => ({
                    p_party_code: v["p_party_code"],
                    p_party_name: v["p_party_name"],
                    p_price_book_code: v["p_price_book_code"],
                    p_term_kind: v["p_term_kind"] || "annual",
                    p_term_months: v["p_term_months"] ? Number(v["p_term_months"]) : 12,
                    p_currency: (v["p_currency"] || "GBP").toUpperCase(),
                    p_valid_days: v["p_valid_days"] ? Number(v["p_valid_days"]) : 30,
                    p_customer_tenant_code: v["p_customer_tenant_code"] || null,
                    p_notes: v["p_notes"] || null,
                  })}
                  invalidates={["erp_commercial_quotes"]}
                  submitLabel={ui("Open a quote")}
                  onDone={(result) => {
                    if (typeof result === "string") setSelected(result);
                  }}
                />
              ) : null
            }
          >
            {q.data.quotes.length === 0 ? (
              <p className="text-sm text-muted-foreground">{ui("No quote has been raised.")}</p>
            ) : (
              <Table
                columns={[
                  "Number",
                  ui("Version"),
                  "Business partner",
                  ui("Price book"),
                  ui("Term"),
                  ui("Totals"),
                  ui("Margin"),
                  ui("Valid until"),
                  "State",
                ]}
              >
                {q.data.quotes.map((row) => (
                  <tr
                    key={row.document_id}
                    className="border-b border-border/50 align-top last:border-0"
                  >
                    <td className="py-2 pr-4">
                      <button
                        type="button"
                        className="font-mono text-xs underline underline-offset-2"
                        onClick={() => setSelected(row.document_id)}
                      >
                        {row.document_number}
                      </button>
                    </td>
                    <td className="py-2 pr-4 text-sm tabular-nums">{row.version}</td>
                    <td className="py-2 pr-4 text-sm">
                      {row.party_name ?? row.party_code ?? "—"}
                      {row.customer_tenant_code ? (
                        <div className="font-mono text-xs text-muted-foreground">
                          {row.customer_tenant_code}
                        </div>
                      ) : null}
                    </td>
                    <td className="py-2 pr-4 font-mono text-xs">{row.price_book}</td>
                    <td className="py-2 pr-4 text-xs">
                      {TERMS.find((t) => t.value === row.term_kind)?.label ?? row.term_kind} ·{" "}
                      {row.term_months}
                    </td>
                    <td className="py-2 pr-4 text-sm tabular-nums">
                      {money(row.total_minor, row.currency)}
                    </td>
                    <td className="py-2 pr-4">
                      <Pill tone={marginTone(row.margin_pct)}>
                        {row.margin_pct == null ? "—" : `${row.margin_pct}%`}
                      </Pill>
                    </td>
                    <td className="py-2 pr-4 text-xs text-muted-foreground">
                      {day(row.valid_until)}
                    </td>
                    <td className="py-2">
                      <Pill tone={stateTone(row.state)}>{row.state}</Pill>
                    </td>
                  </tr>
                ))}
              </Table>
            )}
          </Section>
          <Renewals mayQuote={mayQuote} onOpen={(id) => setSelected(id)} />
        </>
      )}
    </div>
  );
}

type RenewalRow = {
  id: string;
  tenant_code: string;
  customer_legal_name: string;
  term_start: string;
  term_end: string;
  uplift_pct: number;
  previous_annual_value_minor: number;
  proposed_annual_value_minor: number;
  currency: string;
  notice_deadline: string | null;
  status: string;
  quote_document_id: string | null;
};

/**
 * §17.10: renewals proposed by the sweep at each contract's lead time. Raising
 * the quote here copies the contract's lines with the uplift applied into the
 * same builder, so the renewal quote has margin, approval and an order form
 * like any other.
 */
function Renewals({ mayQuote, onOpen }: { mayQuote: boolean; onOpen: (id: string) => void }) {
  const { ui } = useT();
  const q = useQuery({
    queryKey: ["erp_commercial_renewals"],
    queryFn: () => callErp<RenewalRow[]>("erp_commercial_renewals"),
    refetchInterval: 60_000,
  });
  const raise = useErpAction({
    fn: "erp_open_renewal_quote",
    invalidates: ["erp_commercial_renewals", "erp_commercial_quotes"],
    onDone: (result) => {
      if (typeof result === "string") onOpen(result);
    },
  });

  return (
    <Section
      title={ui("Renewals")}
      description={ui(
        "Generated at the notice lead time from the contract with its uplift rule applied. Raise the quote here; it goes through the same builder, approval and order form as any other.",
      )}
    >
      {raise.error ? <ErrorNote error={raise.error} /> : null}
      {q.isPending ? (
        <p className="text-sm text-muted-foreground">Loading…</p>
      ) : q.error ? (
        <p className="text-xs text-muted-foreground">{friendlyError(q.error).title}</p>
      ) : !q.data || q.data.length === 0 ? (
        <p className="text-sm text-muted-foreground">{ui("No renewal is proposed.")}</p>
      ) : (
        <Table
          columns={[
            "Business partner",
            ui("Term"),
            ui("Previous value"),
            ui("Proposed value"),
            ui("Uplift"),
            ui("Notice deadline"),
            "State",
            "",
          ]}
        >
          {q.data.map((r) => (
            <tr key={r.id} className="border-b border-border/50 align-top last:border-0">
              <td className="py-2 pr-4 text-sm">
                {r.customer_legal_name}
                <div className="font-mono text-xs text-muted-foreground">{r.tenant_code}</div>
              </td>
              <td className="py-2 pr-4 text-xs">
                {day(r.term_start)} → {day(r.term_end)}
              </td>
              <td className="py-2 pr-4 text-sm tabular-nums">
                {money(r.previous_annual_value_minor, r.currency)}
              </td>
              <td className="py-2 pr-4 text-sm tabular-nums">
                {money(r.proposed_annual_value_minor, r.currency)}
              </td>
              <td className="py-2 pr-4 text-sm tabular-nums">{r.uplift_pct}%</td>
              <td className="py-2 pr-4 text-xs text-muted-foreground">{day(r.notice_deadline)}</td>
              <td className="py-2 pr-4">
                <Pill tone={r.status === "quoted" ? "ok" : "warn"}>{r.status}</Pill>
              </td>
              <td className="py-2">
                {r.status === "quoted" && r.quote_document_id ? (
                  <button
                    type="button"
                    className={button()}
                    onClick={() => onOpen(r.quote_document_id as string)}
                  >
                    {ui("Open")}
                  </button>
                ) : mayQuote && r.status === "proposed" ? (
                  <button
                    type="button"
                    className={button(true)}
                    disabled={raise.isPending}
                    onClick={() => raise.mutate({ p_renewal_id: r.id })}
                  >
                    {ui("Raise the renewal quote")}
                  </button>
                ) : null}
              </td>
            </tr>
          ))}
        </Table>
      )}
    </Section>
  );
}

function QuoteDetailPanel({
  documentId,
  priceItems,
  onBack,
  onOpen,
}: {
  documentId: string;
  priceItems: { code: string; name: string; kind: string }[];
  onBack: () => void;
  onOpen: (id: string) => void;
}) {
  const { ui } = useT();
  const { session } = useErpSession();
  const mayQuote = hasPermission(session, "sales.order");
  const key = ["erp_commercial_quote", { p_document_id: documentId }];

  const q = useQuery({
    queryKey: key,
    queryFn: () => callErp<QuoteDetail>("erp_commercial_quote", { p_document_id: documentId }),
    refetchInterval: 30_000,
  });

  const invalidates = ["erp_commercial_quote", "erp_commercial_quotes"];
  const submit = useErpAction({ fn: "erp_submit_quote", invalidates });
  const approve = useErpAction({ fn: "erp_approve_quote", invalidates });
  const issue = useErpAction({ fn: "erp_issue_quote", invalidates });
  const revise = useErpAction({
    fn: "erp_revise_quote",
    invalidates,
    onDone: (result) => {
      if (typeof result === "string") onOpen(result);
    },
  });
  const transition = useErpAction({ fn: "erp_quote_transition", invalidates });
  const removeLine = useErpAction({ fn: "erp_remove_quote_line", invalidates });
  const discount = useErpAction({ fn: "erp_set_quote_line_discount", invalidates });

  const errors = [submit, approve, issue, revise, transition, removeLine, discount]
    .map((a) => a.error)
    .filter(Boolean);

  if (q.isPending) return <p className="text-sm text-muted-foreground">Loading…</p>;
  if (q.error || !q.data) {
    return (
      <div role="alert" className="rounded-xl border border-border bg-card p-4 sm:p-5">
        <p className="text-sm font-medium text-destructive">This did not load.</p>
        {q.error ? (
          <p className="mt-1 text-xs text-muted-foreground">{friendlyError(q.error).title}</p>
        ) : null}
        <button type="button" className={`${button()} mt-3`} onClick={onBack}>
          {ui("Back to quotes")}
        </button>
      </div>
    );
  }

  const d = q.data;
  const draft = d.state === "draft";
  const totals = d.margin.totals;
  const threshold = d.margin.threshold_pct;
  const beyond = threshold != null && totals.max_discount_pct > threshold;

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <div className="flex flex-wrap items-center gap-2">
        <button type="button" className={button()} onClick={onBack}>
          {ui("Back to quotes")}
        </button>
        <span className="font-mono text-sm">{d.document_number}</span>
        <Pill tone="muted">
          {ui("Version")} {d.version}
        </Pill>
        <Pill tone={stateTone(d.state)}>{d.state}</Pill>
        {d.supersedes ? (
          <button
            type="button"
            className="text-xs underline underline-offset-2"
            onClick={() => onOpen(d.supersedes!)}
          >
            {ui("Supersedes")} v{d.version - 1}
          </button>
        ) : null}
        {d.superseded_by ? (
          <button
            type="button"
            className="text-xs underline underline-offset-2"
            onClick={() => onOpen(d.superseded_by!)}
          >
            {ui("Superseded by")} v{d.version + 1}
          </button>
        ) : null}
      </div>

      <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 rounded-xl border border-border bg-card p-4 text-sm sm:p-5">
        <dt className="text-muted-foreground">Business partner</dt>
        <dd>
          {d.party_name ?? d.party_code ?? "—"}
          {d.customer_tenant_code ? (
            <span className="ml-2 font-mono text-xs text-muted-foreground">
              {d.customer_tenant_code}
            </span>
          ) : null}
        </dd>
        <dt className="text-muted-foreground">{ui("Price book")}</dt>
        <dd className="font-mono text-xs">
          {d.price_book_code} v{d.price_book_version}
        </dd>
        <dt className="text-muted-foreground">{ui("Term")}</dt>
        <dd>
          {TERMS.find((t) => t.value === d.term_kind)?.label ?? d.term_kind} · {d.term_months} ·{" "}
          {d.currency}
        </dd>
        <dt className="text-muted-foreground">{ui("Valid until")}</dt>
        <dd>{day(d.valid_until)}</dd>
        {d.notes ? (
          <>
            <dt className="text-muted-foreground">Notes</dt>
            <dd className="text-muted-foreground">{d.notes}</dd>
          </>
        ) : null}
      </dl>

      <Section
        title={ui("Margin")}
        description={
          threshold == null
            ? undefined
            : beyond
              ? ui("Beyond the threshold: routed for approval.")
              : ui("Within the threshold, nobody is needed.")
        }
        action={
          mayQuote && draft ? (
            <ActionDialog
              trigger={<span className={button(true)}>{ui("Add a line")}</span>}
              title={ui("Add a line")}
              permission="sales.order"
              fn="erp_add_quote_line"
              fields={[
                {
                  kind: "choice",
                  name: "p_item_code",
                  label: "Product",
                  required: true,
                  choices: priceItems.map((i) => ({
                    value: i.code,
                    label: `${i.code} · ${i.name}`,
                  })),
                },
                { kind: "number", name: "p_quantity", label: "Quantity" },
                { kind: "number", name: "p_discount_pct", label: ui("Discount") },
              ]}
              mapArgs={(v) => ({
                p_document_id: documentId,
                p_item_code: v["p_item_code"],
                p_quantity: v["p_quantity"] ? Number(v["p_quantity"]) : 1,
                p_discount_pct: v["p_discount_pct"] ? Number(v["p_discount_pct"]) : 0,
              })}
              invalidates={invalidates}
              submitLabel={ui("Add a line")}
            />
          ) : null
        }
      >
        {d.margin.lines.length === 0 ? (
          <p className="text-sm text-muted-foreground">{ui("Nothing is on the price book yet.")}</p>
        ) : (
          <Table
            columns={[
              "#",
              "Product",
              "Quantity",
              ui("List"),
              ui("Discount"),
              ui("Quoted"),
              ui("Cost"),
              ui("Margin"),
              "",
            ]}
          >
            {d.margin.lines.map((l) => (
              <tr key={l.line_id} className="border-b border-border/50 align-top last:border-0">
                <td className="py-2 pr-3 text-xs tabular-nums">{l.line_no}</td>
                <td className="py-2 pr-3">
                  <div className="text-sm">{l.name}</div>
                  <div className="font-mono text-xs text-muted-foreground">
                    {l.item_code}
                    {l.kind ? ` · ${l.kind}` : ""}
                  </div>
                </td>
                <td className="py-2 pr-3 text-sm tabular-nums">{l.quantity}</td>
                <td className="py-2 pr-3 text-sm tabular-nums">{money(l.list_minor)}</td>
                <td className="py-2 pr-3 text-sm tabular-nums">
                  {mayQuote && draft && l.kind !== "legislation_pack" ? (
                    <label className="flex items-center gap-1">
                      <span className="sr-only">{ui("Discount")}</span>
                      <input
                        type="number"
                        min={0}
                        max={100}
                        step={0.5}
                        defaultValue={l.discount_pct}
                        className={`${TOUCH} w-20 rounded-md border border-input bg-background px-2 text-sm tabular-nums`}
                        onBlur={(e) => {
                          const value = Number(e.target.value);
                          if (Number.isFinite(value) && value !== l.discount_pct) {
                            discount.mutate({ p_line_id: l.line_id, p_discount_pct: value });
                          }
                        }}
                      />
                      <span className="text-xs">%</span>
                    </label>
                  ) : (
                    `${l.discount_pct}%`
                  )}
                </td>
                <td className="py-2 pr-3 text-sm tabular-nums">{money(l.quoted_minor)}</td>
                <td className="py-2 pr-3 text-sm tabular-nums">
                  {l.cost_minor == null ? (
                    <span
                      className="text-xs text-muted-foreground"
                      title={ui(
                        "No cost is recorded for this line, so its margin is invisible; set the cost on the price book.",
                      )}
                    >
                      {l.kind === "legislation_pack" ? "nil" : ui("No cost")}
                    </span>
                  ) : (
                    money(l.cost_minor)
                  )}
                </td>
                <td className="py-2 pr-3">
                  <Pill tone={marginTone(l.margin_pct, l.below_cost)}>
                    {l.below_cost
                      ? ui("Below cost")
                      : l.margin_pct == null
                        ? "—"
                        : `${l.margin_pct}%`}
                  </Pill>
                </td>
                <td className="py-2">
                  {mayQuote && draft ? (
                    <button
                      type="button"
                      className={`${TOUCH} rounded-md border border-input px-2 text-xs`}
                      onClick={() => removeLine.mutate({ p_line_id: l.line_id })}
                    >
                      {ui("Remove")}
                    </button>
                  ) : null}
                </td>
              </tr>
            ))}
          </Table>
        )}
        <dl className="mt-4 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
          <dt className="text-muted-foreground">{ui("Totals")}</dt>
          <dd className="tabular-nums">
            {ui("List")} {money(totals.list_minor, d.currency)} · {ui("Quoted")}{" "}
            {money(totals.quoted_minor, d.currency)} · {ui("Cost")}{" "}
            {money(totals.cost_minor, d.currency)}
          </dd>
          <dt className="text-muted-foreground">{ui("Margin")}</dt>
          <dd>
            <Pill tone={marginTone(totals.margin_pct, totals.below_cost_lines > 0)}>
              {money(totals.margin_minor, d.currency)} ·{" "}
              {totals.margin_pct == null ? "—" : `${totals.margin_pct}%`}
            </Pill>
            {totals.below_cost_lines > 0 ? (
              <span className="ml-2 text-xs text-destructive">
                {totals.below_cost_lines} {ui("Below cost")}
              </span>
            ) : null}
          </dd>
          <dt className="text-muted-foreground">{ui("Threshold")}</dt>
          <dd className="tabular-nums">
            {totals.max_discount_pct}% / {threshold ?? "—"}%
          </dd>
        </dl>
      </Section>

      <Section title={ui("Approval")}>
        {d.approval ? (
          <p className="text-sm">
            <Pill
              tone={
                d.approval.status === "approved"
                  ? "ok"
                  : d.approval.status === "pending"
                    ? "warn"
                    : "bad"
              }
            >
              {d.approval.status}
            </Pill>
            <span className="ml-2 text-xs text-muted-foreground">
              {d.approval.chain_code} · {d.approval.outstanding} outstanding ·{" "}
              {day(d.approval.requested_at)}
              {d.approval.decided_at ? ` → ${day(d.approval.decided_at)}` : ""}
            </span>
          </p>
        ) : (
          <p className="text-sm text-muted-foreground">
            {ui("Within the threshold, nobody is needed.")}
          </p>
        )}
        {mayQuote ? (
          <div className="mt-3 flex flex-wrap gap-2">
            {draft ? (
              <button
                type="button"
                className={button(true)}
                onClick={() => submit.mutate({ p_document_id: documentId })}
              >
                {ui("Submit")}
              </button>
            ) : null}
            {d.state === "pending_approval" ? (
              <button
                type="button"
                className={button(true)}
                onClick={() => approve.mutate({ p_document_id: documentId })}
              >
                {ui("Approve")}
              </button>
            ) : null}
            {d.state === "approved" ? (
              <button
                type="button"
                className={button(true)}
                onClick={() => issue.mutate({ p_document_id: documentId })}
              >
                {ui("Issue")}
              </button>
            ) : null}
            {d.state === "issued" ? (
              <>
                <button
                  type="button"
                  className={button(true)}
                  onClick={() =>
                    transition.mutate({ p_document_id: documentId, p_transition_code: "accept" })
                  }
                >
                  {ui("Accept")}
                </button>
                <button
                  type="button"
                  className={button()}
                  onClick={() =>
                    transition.mutate({ p_document_id: documentId, p_transition_code: "decline" })
                  }
                >
                  {ui("Decline")}
                </button>
              </>
            ) : null}
            {["draft", "approved", "issued", "pending_approval"].includes(d.state) &&
            !d.superseded_by ? (
              <button
                type="button"
                className={button()}
                onClick={() => revise.mutate({ p_document_id: documentId })}
              >
                {ui("Revise")}
              </button>
            ) : null}
          </div>
        ) : null}
        {errors.map((e, i) => (
          <ErrorNote key={i} error={e} />
        ))}
      </Section>

      {d.order_form ? (
        <Section
          title={ui("Order form")}
          description={`${d.order_form.checksum} · ${day(d.order_form.rendered_at)}`}
        >
          <pre className="max-h-96 overflow-auto rounded-md bg-muted p-3 text-xs">
            {JSON.stringify(d.order_form.content, null, 2)}
          </pre>
        </Section>
      ) : null}
    </div>
  );
}
