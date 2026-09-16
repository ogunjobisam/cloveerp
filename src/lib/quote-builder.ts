/**
 * The console's quote builder, as plain functions over what the doors return.
 *
 * On 14 September the platform owner asked where a quote is built. The answer
 * was a desk screen inside another organisation that asked for price item codes
 * by hand. The console builds one from choices instead: a plan, how many users
 * beyond it, extras, onboarding and support. These are the rules for turning
 * the price book and a quote into those choices, kept here so they can be tested
 * without a screen or a database.
 */

export type TermKind = "annual" | "monthly" | "multi_year";

export type Rate = {
  price_book_code: string;
  term_kind: string;
  currency: string;
  amount_minor: number;
};

export type PriceItem = {
  code: string;
  name: string;
  kind: string;
  status: string;
  plan_code: string | null;
  entitlement_code: string | null;
  support_severity_code: string | null;
  description: string | null;
  included_users: number | null;
  charge: string | null;
  percent_of_recurring: number | null;
  rates: Rate[];
};

export type QuoteLine = {
  line_id: string;
  line_no: number;
  item_code: string;
  name: string;
  kind: string | null;
  quantity: number;
  list_minor: number;
  discount_pct: number | null;
  quoted_unit_minor: number;
  quoted_minor: number;
  margin_pct: number | null;
  below_cost: boolean;
  plan_code: string | null;
  entitlement_code: string | null;
  charge: string | null;
};

/**
 * The rate for a term, or null when the book has none.
 *
 * The currency is named by the caller and has no default. It used to default
 * to GBP, and every call site in the console took the default — so the builder
 * read GBP rates off the book whatever currency the quote was in, while
 * erp.add_quote_line priced the line from the quote's own currency. The screen
 * and the charge disagreed, silently, and a default is what let them.
 */
export function rateFor(
  item: PriceItem,
  book: string,
  term: string,
  currency: string,
): number | null {
  const rate = item.rates.find(
    (r) => r.price_book_code === book && r.term_kind === term && r.currency === currency,
  );
  return rate ? rate.amount_minor : null;
}

const PLAN_ORDER = ["starter", "standard", "enterprise"];

/** The plans on the book, in the order they are sold. */
export function planItems(items: readonly PriceItem[]): PriceItem[] {
  return items
    .filter((i) => i.kind === "plan_tier" && i.status === "active")
    .sort((a, b) => {
      const ra = PLAN_ORDER.indexOf(a.plan_code ?? "");
      const rb = PLAN_ORDER.indexOf(b.plan_code ?? "");
      return (ra < 0 ? 99 : ra) - (rb < 0 ? 99 : rb) || a.code.localeCompare(b.code);
    });
}

/** The full or light user priced for a plan. */
export function userItemFor(
  items: readonly PriceItem[],
  kind: "full_user" | "light_user",
  plan: string | null,
): PriceItem | null {
  if (!plan) return null;
  return (
    items.find((i) => i.kind === kind && i.plan_code === plan && i.status === "active") ?? null
  );
}

/** An extra that adds to a plan's limit: companies or sites. */
export function extraItemFor(items: readonly PriceItem[], entitlement: string): PriceItem | null {
  return (
    items.find(
      (i) => i.kind === "service" && i.entitlement_code === entitlement && i.status === "active",
    ) ?? null
  );
}

/** One-off services with no limit to raise: onboarding, implementation, a pilot. */
export function oneOffItems(items: readonly PriceItem[]): PriceItem[] {
  return items.filter((i) => i.charge === "one_off" && i.status === "active");
}

/** Support sold as a tier. */
export function supportItems(items: readonly PriceItem[]): PriceItem[] {
  return items.filter((i) => i.kind === "support_tier" && i.status === "active");
}

/** The line on a quote for an item, if it carries one. */
export function lineFor(lines: readonly QuoteLine[], itemCode: string | null | undefined) {
  if (!itemCode) return null;
  return lines.find((l) => l.item_code === itemCode) ?? null;
}

/** The plan a quote sells, from its lines. */
export function quotePlan(lines: readonly QuoteLine[]): string | null {
  return lines.find((l) => l.kind === "plan_tier")?.plan_code ?? null;
}

/**
 * A business partner code for a prospect, from their name.
 *
 * The quote door reuses a partner with the same code, so two prospects whose
 * names start alike must not share one: a short suffix keeps them apart.
 */
export function partyCodeFor(name: string, suffix: string): string {
  const stem = name
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^A-Za-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .toUpperCase()
    .slice(0, 16)
    .replace(/-+$/g, "");
  const tail = suffix
    .replace(/[^A-Za-z0-9]/g, "")
    .toUpperCase()
    .slice(0, 4);
  return `${stem || "PROSPECT"}-${tail || "0000"}`;
}

export type Stage = "draft" | "approval" | "ready" | "sent" | "won" | "closed";

/** Where a quote stands, in the order the pipeline shows them. */
export function stageOf(state: string, supersededBy: string | null | undefined): Stage {
  if (supersededBy || state === "superseded") return "closed";
  switch (state) {
    case "draft":
      return "draft";
    case "pending_approval":
      return "approval";
    case "approved":
      return "ready";
    case "issued":
      return "sent";
    case "accepted":
      return "won";
    default:
      return "closed";
  }
}

export const STAGES: { key: Stage; label: string; hint: string }[] = [
  { key: "draft", label: "Being built", hint: "Still being put together." },
  { key: "approval", label: "Waiting for approval", hint: "A discount above 10% needs approving." },
  { key: "ready", label: "Ready to send", hint: "Approved. Issue the order form." },
  { key: "sent", label: "Sent", hint: "With the customer. Record their answer." },
  { key: "won", label: "Accepted", hint: "Make the contract." },
  { key: "closed", label: "Closed", hint: "Declined, expired or replaced by a newer version." },
];

/** What a term's rate is per. */
export function termUnit(term: string): string {
  return term === "monthly" ? "a month" : "a year";
}

export function termLabel(term: string, months?: number | null): string {
  if (term === "monthly") return "Month to month";
  if (term === "multi_year") return months ? `${Math.round(months / 12)} years` : "Several years";
  return "Annual";
}

/**
 * An amount, with pence only where there are any.
 *
 * The currency is named by the caller for the same reason `rateFor` names it:
 * a default of GBP made every unnamed figure on the quote screen a pound
 * figure, whatever the quote was actually in.
 */
export function money(minor: number | null | undefined, currency: string): string {
  if (minor == null || !Number.isFinite(minor)) return "—";
  const major = minor / 100;
  const whole = Number.isInteger(major);
  const text = major.toLocaleString("en-GB", {
    minimumFractionDigits: whole ? 0 : 2,
    maximumFractionDigits: 2,
  });
  return currency === "GBP" ? `£${text}` : `${text} ${currency}`;
}

/**
 * The total an issued order form states, in minor units.
 *
 * A form issued since 20260914093000 carries its price as
 * `pricing.totals.net_minor`. One issued before carried the quote's margin
 * totals instead, whose `quoted_minor` is the same figure. Anything else has
 * no total to show.
 */
export function orderFormTotal(content: unknown): number | null {
  const at = (value: unknown, key: string): unknown =>
    typeof value === "object" && value !== null && !Array.isArray(value)
      ? (value as Record<string, unknown>)[key]
      : undefined;
  const figure = (value: unknown): number | null =>
    typeof value === "number" && Number.isFinite(value) ? value : null;
  return (
    figure(at(at(at(content, "pricing"), "totals"), "net_minor")) ??
    figure(at(at(at(content, "margin"), "totals"), "quoted_minor"))
  );
}

/** The largest discount a quote may carry: 35% for a founding customer, 25% otherwise. */
export function discountCeiling(programme: string | null | undefined): number {
  return programme === "founding" ? 35 : 25;
}

/**
 * What the contract form starts from, given the accepted quote.
 *
 * A month-to-month quote bills monthly; everything else annually. The term is
 * the quote's. Renewal increases follow the owner's rule: CPI, capped at 5%.
 */
export function contractDefaults(quote: {
  party_name: string | null;
  customer_tenant_code: string | null;
  term_kind: string;
  term_months: number;
}) {
  return {
    customerTenantCode: quote.customer_tenant_code ?? "",
    customerLegalName: quote.party_name ?? "",
    initialTermMonths: String(quote.term_months || 12),
    billingFrequency: quote.term_kind === "monthly" ? "monthly" : "annual",
    upliftRule: { kind: "capped", index_code: "CPI", cap_pct: 5 },
  };
}
