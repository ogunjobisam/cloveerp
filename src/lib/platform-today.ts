import { formatMinorWhole } from "./money";
import type { SectionKey, ViewKey } from "./platform-console";

/**
 * Today: what needs the person running the platform, decided from what the
 * console already reads.
 *
 * Every card here is computed from a door another tab already calls, with the
 * same arguments, so the figure on Today and the tab it opens can never
 * disagree. Nothing is queried specially for a dashboard.
 *
 * Each door is read on its own and each yields its own cards, so a door that
 * fails costs its own cards and nobody else's. Pure, so the choice of what
 * deserves attention is tested without a browser.
 */

export type TodayTarget = { section: SectionKey; view: ViewKey; org?: string };

export type TodayCard = {
  key: string;
  /** The headline: a count, or an amount where the door has no count to give. */
  figure: string;
  title: string;
  /** One plain sentence saying what the figure means. */
  sentence: string;
  tone: "warn" | "bad";
  /** The button's words. */
  action: string;
  target: TodayTarget;
};

/* -------------------------------------------------------------------------- */
/* What each door answers, as far as Today needs it.                          */
/* -------------------------------------------------------------------------- */

export type AssuranceCheck = { code: string; title?: string | undefined; ok: boolean | null };
export type EnquiryRow = {
  submitted_at: string;
  status: string;
  /** Set when a member of staff recorded what was done about it. */
  handled_at?: string | null;
};
export type RevenueRead = {
  renewals: { status: string; tenant_code: string }[];
  revenue_at_risk: { tenant_code: string; annual_value_minor: number }[];
  revenue_at_risk_minor: number;
  invoices: { issued_minor: number };
  gross_margin: { currency: string }[];
};
export type IncidentRow = { code: string; title: string; state: string; overdue: boolean };
export type TransferRow = { status: string; is_mine_to_answer: boolean };
export type SellingRead = {
  platform_organisation: { tenant_code: string; name: string | null } | null;
  price_items: number;
  selling: { installed: boolean; price_book: unknown; waiting: boolean } | null;
};
export type TenantRow = {
  code: string;
  name: string;
  status: string;
  /** Set when deletion was requested or the organisation was marked ended. */
  deleted_at?: string | null;
};
export type OpenInvoiceRow = {
  reference: string;
  tenant_code: string;
  customer_legal_name: string;
  currency: string;
  total_minor: number;
  due_on: string;
  overdue: boolean;
  days_overdue: number;
  /** How far the chase has got (20260915040000). */
  reminders_sent?: number | null;
  last_reminder_at?: string | null;
};

/** What erp_platform_email_delivery answers, as far as Today needs it. */
export type EmailDeliveryRead = {
  trouble: {
    event_id: string;
    state: string;
    occurred_at: string;
    to_address: string | null;
    matched: string;
    suppressed: boolean;
    tenant_code?: string | null;
    detail?: string | null;
  }[];
  suppressed: { address: string; reason: string; suppressed_at: string; note?: string | null }[];
  recent?: Record<string, number> | null;
};
/** What erp_platform_billing_details answers: whether payment details are set, and them. */
export type BillingDetailsRead = {
  set: boolean;
  legal_name?: string | null;
  registered_address?: string | null;
  company_number?: string | null;
  bank_account_name?: string | null;
  sort_code?: string | null;
  account_number?: string | null;
  payment_reference_guidance?: string | null;
  updated_at?: string | null;
  updated_by?: string | null;
};
export type SupportWindowRow = {
  tenant_code: string;
  tenant_name: string;
  staff_email: string;
  is_write_access: boolean;
  expires_at: string;
};

/* -------------------------------------------------------------------------- */
/* Words.                                                                     */
/* -------------------------------------------------------------------------- */

function plural(n: number, one: string, many: string): string {
  return n === 1 ? one : many;
}

/** "A", "A and B", "A, B and 3 others". */
export function listNames(names: string[], shown = 2): string {
  if (names.length === 0) return "";
  if (names.length === 1) return names[0]!;
  if (names.length <= shown + 1) {
    return `${names.slice(0, -1).join(", ")} and ${names[names.length - 1]}`;
  }
  const rest = names.length - shown;
  return `${names.slice(0, shown).join(", ")} and ${rest} ${plural(rest, "other", "others")}`;
}

/* -------------------------------------------------------------------------- */
/* The cards, door by door.                                                   */
/* -------------------------------------------------------------------------- */

export function assuranceCards(checks: AssuranceCheck[]): TodayCard[] {
  const failing = checks.filter((c) => c.ok === false);
  if (failing.length === 0) return [];
  const names = failing.map((c) => c.title ?? c.code);
  return [
    {
      key: "checks",
      figure: String(failing.length),
      title: plural(failing.length, "Check failing", "Checks failing"),
      sentence:
        failing.length === 1
          ? `The ${names[0]} check is failing on this deployment; Diagnostics shows what it found.`
          : `${listNames(names)} are failing on this deployment; Diagnostics shows what each found.`,
      tone: "bad",
      action: "Open diagnostics",
      target: { section: "platform", view: "diagnostics" },
    },
  ];
}

/** The green state, when nothing else is wrong. */
export function healthSummary(checks: AssuranceCheck[]): {
  passing: number;
  failing: number;
  needOrganisation: number;
} {
  return {
    passing: checks.filter((c) => c.ok === true).length,
    failing: checks.filter((c) => c.ok === false).length,
    needOrganisation: checks.filter((c) => c.ok === null).length,
  };
}

const DAY = 24 * 60 * 60 * 1000;
/** How recent an enquiry is to count as new. There is no "read" flag to go by. */
export const NEW_ENQUIRY_DAYS = 7;
/**
 * The notification is attempted in the request that stores an enquiry, so one
 * still unsent a quarter of an hour later is a pipeline that stopped. The same
 * fifteen minutes erp.unanswered_enquiry_report() uses.
 */
const STUCK_MINUTES = 15;

export function enquiryCards(rows: EnquiryRow[], now: Date): TodayCard[] {
  // Erased is gone, and handled has had somebody deal with it: neither needs
  // anybody today, whatever the mail did.
  const live = rows.filter((e) => e.status !== "erased" && !e.handled_at);
  const at = now.getTime();
  const recent = live.filter(
    (e) => at - new Date(e.submitted_at).getTime() <= NEW_ENQUIRY_DAYS * DAY,
  );
  const undelivered = live.filter(
    (e) =>
      e.status === "notification_failed" ||
      (e.status === "new" && at - new Date(e.submitted_at).getTime() > STUCK_MINUTES * 60 * 1000),
  );

  const cards: TodayCard[] = [];
  if (recent.length > 0) {
    cards.push({
      key: "enquiries",
      figure: String(recent.length),
      title: plural(recent.length, "New enquiry", "New enquiries"),
      sentence:
        recent.length === 1
          ? "Somebody asked about Clove ERP in the last seven days."
          : `${recent.length} people asked about Clove ERP in the last seven days.`,
      tone: "warn",
      action: "Read enquiries",
      target: { section: "sales", view: "enquiries" },
    });
  }
  if (undelivered.length > 0) {
    cards.push({
      key: "enquiries-undelivered",
      figure: String(undelivered.length),
      title: plural(
        undelivered.length,
        "Enquiry not emailed to you",
        "Enquiries not emailed to you",
      ),
      sentence: `The email about ${plural(undelivered.length, "this enquiry", "these enquiries")} was never sent, so this console is the only place ${plural(undelivered.length, "it", "they")} can be read.`,
      tone: "bad",
      action: "Read enquiries",
      target: { section: "sales", view: "enquiries" },
    });
  }
  return cards;
}

export function revenueCards(revenue: RevenueRead): TodayCard[] {
  const currency = revenue.gross_margin[0]?.currency ?? "GBP";
  const cards: TodayCard[] = [];

  const undecided = revenue.renewals.filter(
    (r) => r.status === "proposed" || r.status === "quoted",
  );
  if (undecided.length > 0) {
    const codes = [...new Set(undecided.map((r) => r.tenant_code))];
    cards.push({
      key: "renewals",
      figure: String(undecided.length),
      title: plural(undecided.length, "Renewal to decide", "Renewals to decide"),
      sentence: `${listNames(codes)} ${plural(codes.length, "is", "are")} due to renew, and nobody has renewed or declined yet.`,
      tone: "warn",
      action: "Open renewals",
      target: { section: "billing", view: "revenue" },
    });
  }

  if (revenue.revenue_at_risk.length > 0) {
    const codes = [...new Set(revenue.revenue_at_risk.map((r) => r.tenant_code))];
    cards.push({
      key: "at-risk",
      figure: String(revenue.revenue_at_risk.length),
      title: plural(revenue.revenue_at_risk.length, "Contract at risk", "Contracts at risk"),
      sentence: `${formatMinorWhole(revenue.revenue_at_risk_minor, currency)} a year from ${listNames(codes)} is near its notice deadline with no renewal agreed.`,
      tone: "bad",
      action: "Open renewals",
      target: { section: "billing", view: "revenue" },
    });
  }

  return cards;
}

/**
 * Invoices past their due date. An invoice issued and not yet due needs
 * nobody: the customer has until the date on it. One that is late needs a
 * reminder, so it is the serious kind of card.
 */
export function invoiceCards(rows: OpenInvoiceRow[]): TodayCard[] {
  const late = rows.filter((i) => i.overdue);
  if (late.length === 0) return [];
  const customers = [...new Set(late.map((i) => i.customer_legal_name))];
  const codes = [...new Set(late.map((i) => i.tenant_code))];
  const currencies = [...new Set(late.map((i) => i.currency))];
  const oldest = Math.max(...late.map((i) => i.days_overdue));
  const amount =
    currencies.length === 1
      ? formatMinorWhole(
          late.reduce((sum, i) => sum + i.total_minor, 0),
          currencies[0]!,
        )
      : null;
  const what = amount
    ? `${amount} from ${listNames(customers)}`
    : `${late.length} invoices from ${listNames(customers)}`;
  // What the chase has already done about it, so that "nobody has told them"
  // and "they have been told four times" are not the same card.
  const chased = late.reduce((sum, i) => sum + (i.reminders_sent ?? 0), 0);
  const last = late
    .map((i) => i.last_reminder_at)
    .filter((when): when is string => typeof when === "string" && when !== "")
    .sort()
    .at(-1);
  const chase =
    chased === 0
      ? " No reminder has gone yet."
      : ` ${chased} ${plural(chased, "reminder has", "reminders have")} gone${
          last ? `, the last on ${new Date(last).toLocaleDateString("en-GB")}` : ""
        }.`;
  return [
    {
      key: "overdue-invoices",
      figure: String(late.length),
      title: plural(late.length, "Invoice overdue", "Invoices overdue"),
      sentence: `${what} ${plural(late.length, "is", "are")} past the due date; the oldest is ${oldest} ${plural(oldest, "day", "days")} late.${chase}`,
      tone: "bad",
      action: codes.length === 1 ? "Open the organisation" : "Open contracts",
      target:
        codes.length === 1
          ? { section: "customers", view: "organisations", org: codes[0]! }
          : { section: "sales", view: "contracts" },
    },
  ];
}

/**
 * Email the provider could not deliver, or that somebody marked as spam.
 *
 * A bounce is a fact rather than a failure — nothing is retried for it — but
 * somebody has to know, because an invoice nobody received is an invoice
 * nobody pays. A complaint matters more: the address is suppressed, so the
 * next message to it is cancelled rather than sent.
 */
export function emailDeliveryCards(read: EmailDeliveryRead): TodayCard[] {
  const trouble = read.trouble ?? [];
  const bounced = trouble.filter((t) => t.state === "bounced");
  const complained = trouble.filter((t) => t.state === "complained");
  if (bounced.length === 0 && complained.length === 0) return [];
  const addresses = [...new Set(trouble.map((t) => t.to_address).filter(Boolean))] as string[];
  const stopped = (read.suppressed ?? []).length;
  const words = [
    bounced.length > 0
      ? `${bounced.length} ${plural(bounced.length, "email", "emails")} bounced`
      : null,
    complained.length > 0 ? `${complained.length} was marked as spam` : null,
  ].filter(Boolean) as string[];
  return [
    {
      key: "email-not-delivered",
      figure: String(bounced.length + complained.length),
      title: complained.length > 0 ? "An email was marked as spam" : "An email bounced",
      sentence:
        `${words.join(" and ")}: ${listNames(addresses.slice(0, 3))}` +
        (addresses.length > 3 ? ` and ${addresses.length - 3} more` : "") +
        `. ${stopped === 0 ? "No address is suppressed." : `${stopped} ${plural(stopped, "address is", "addresses are")} suppressed, so nothing more is sent to ${plural(stopped, "it", "them")} until an operator clears ${plural(stopped, "it", "them")}.`}`,
      tone: complained.length > 0 || stopped > 0 ? "bad" : "warn",
      action: "Open jobs and queue",
      target: { section: "platform", view: "queue" },
    },
  ];
}

function closesIn(ms: number): string {
  const minutes = Math.max(1, Math.round(ms / 60_000));
  if (minutes < 90) return `${minutes} ${plural(minutes, "minute", "minutes")}`;
  const hours = Math.round(minutes / 60);
  return `${hours} ${plural(hours, "hour", "hours")}`;
}

/**
 * Support windows open anywhere. Nothing is wrong with one, but somebody from
 * the platform is inside a customer's organisation, and whoever runs the
 * platform should know who and for how long.
 */
export function supportWindowCards(rows: SupportWindowRow[], now: Date): TodayCard[] {
  const at = now.getTime();
  const open = rows
    .filter((w) => new Date(w.expires_at).getTime() > at)
    .sort((a, b) => new Date(a.expires_at).getTime() - new Date(b.expires_at).getTime());
  if (open.length === 0) return [];
  const codes = [...new Set(open.map((w) => w.tenant_code))];
  const first = open[0]!;
  const last = open[open.length - 1]!;
  const sentence =
    open.length === 1
      ? `${first.staff_email} is inside ${first.tenant_name}${first.is_write_access ? " with write access" : ""}; the window closes in ${closesIn(new Date(first.expires_at).getTime() - at)}.`
      : `Platform staff are inside ${listNames([...new Set(open.map((w) => w.tenant_name))])}; the last window closes in ${closesIn(new Date(last.expires_at).getTime() - at)}.`;
  return [
    {
      key: "support-windows",
      figure: String(open.length),
      title: plural(open.length, "Support window open", "Support windows open"),
      sentence,
      tone: "warn",
      action: codes.length === 1 ? "Open the organisation" : "Open organisations",
      target:
        codes.length === 1
          ? { section: "customers", view: "organisations", org: codes[0]! }
          : { section: "customers", view: "organisations" },
    },
  ];
}

/**
 * Payment details, before an invoice goes out without them. Every contract
 * invoice is emailed when it is issued, and one sent before these are set tells
 * the customer payment details will follow, which somebody then has to do.
 */
export function paymentDetailsCards(details: BillingDetailsRead): TodayCard[] {
  if (details.set) return [];
  return [
    {
      key: "payment-details",
      figure: "1",
      title: "Add payment details before invoices go out",
      sentence:
        "Invoices are emailed the moment they are issued, and until the bank details are added each one tells the customer payment details will follow.",
      tone: "warn",
      action: "Add payment details",
      target: { section: "billing", view: "payment" },
    },
  ];
}

export function incidentCards(rows: IncidentRow[]): TodayCard[] {
  const open = rows.filter((i) => i.state !== "resolved");
  if (open.length === 0) return [];
  const late = open.filter((i) => i.overdue).length;
  const first = open[0]!;
  const sentence =
    open.length === 1
      ? `${first.title} (${first.code}) is still open${late > 0 ? " and its next update is overdue" : ""}.`
      : `${open.length} incidents are still open${late > 0 ? `, and ${late} ${plural(late, "is", "are")} overdue an update` : ""}.`;
  return [
    {
      key: "incidents",
      figure: String(open.length),
      title: plural(open.length, "Open incident", "Open incidents"),
      sentence,
      tone: "bad",
      action: "Open incidents",
      target: { section: "platform", view: "incidents" },
    },
  ];
}

export function transferCards(rows: TransferRow[]): TodayCard[] {
  const pending = rows.filter((t) => t.status === "pending");
  if (pending.length === 0) return [];
  const mine = pending.filter((t) => t.is_mine_to_answer).length;
  return [
    {
      key: "transfers",
      figure: String(pending.length),
      title: plural(pending.length, "Ownership transfer waiting", "Ownership transfers waiting"),
      sentence:
        mine > 0
          ? `${mine === 1 ? "An organisation has" : `${mine} organisations have`} been offered to you. Accept or decline before the offer lapses.`
          : `${pending.length === 1 ? "An offer" : `${pending.length} offers`} to hand an organisation to another owner ${plural(pending.length, "is", "are")} waiting for an answer.`,
      tone: "warn",
      action: mine > 0 ? "Answer the offer" : "Open transfers",
      target: { section: "customers", view: "ownership" },
    },
  ];
}

/**
 * Whether the price list is on the platform organisation's book: selling is
 * installed, a price book exists, and it holds items. selling.tsx says "Done"
 * on exactly this.
 */
export function priceListLoaded(state: SellingRead): boolean {
  return Boolean(state.selling?.installed && state.selling.price_book && state.price_items > 0);
}

export function sellingCards(state: SellingRead): TodayCard[] {
  const platform = state.platform_organisation;
  if (platform && priceListLoaded(state)) return [];
  const where = platform ? (platform.name ?? platform.tenant_code) : null;
  const sentence = !platform
    ? "Choose the organisation that is Clove ERP itself and load its price list, because no quote or contract can be made until both are done."
    : state.selling?.waiting
      ? `Part of the price list is waiting for a second administrator in ${where} to approve it.`
      : `The price list has not been loaded into ${where}, so there is nothing to quote from.`;
  const steps = platform ? 1 : 2;
  return [
    {
      key: "selling",
      figure: String(steps),
      title: plural(steps, "Step left to set up selling", "Steps left to set up selling"),
      sentence,
      tone: "warn",
      action: "Set up selling",
      target: { section: "catalogue", view: "selling" },
    },
  ];
}

export function organisationCards(tenants: TenantRow[]): TodayCard[] {
  const cards: TodayCard[] = [];
  const pageOrList = (rows: TenantRow[]): TodayTarget =>
    rows.length === 1
      ? { section: "customers", view: "organisations", org: rows[0]!.code }
      : { section: "customers", view: "organisations" };

  // A deletion request suspends the organisation and records when it was asked
  // for; a suspension on its own records nothing of the kind. Different things
  // to do: one is waiting to be let back in, the other to be purged.
  const requested = tenants.filter((t) => t.status === "suspended" && Boolean(t.deleted_at));
  const suspended = tenants.filter((t) => t.status === "suspended" && !t.deleted_at);
  if (suspended.length > 0) {
    cards.push({
      key: "suspended",
      figure: String(suspended.length),
      title: plural(suspended.length, "Suspended organisation", "Suspended organisations"),
      sentence: `Nobody in ${listNames(suspended.map((t) => t.name))} can work while ${plural(suspended.length, "it is", "they are")} suspended.`,
      tone: "warn",
      action: suspended.length === 1 ? "Open the organisation" : "Open organisations",
      target: pageOrList(suspended),
    });
  }

  if (requested.length > 0) {
    cards.push({
      key: "deletion-requested",
      figure: String(requested.length),
      title: plural(requested.length, "Deletion requested", "Deletions requested"),
      sentence: `${listNames(requested.map((t) => t.name))} asked to be deleted. The sweep purges an organisation seven days after the request, or an owner can purge it sooner.`,
      tone: "warn",
      action: requested.length === 1 ? "Open the organisation" : "Open organisations",
      target: pageOrList(requested),
    });
  }

  const ended = tenants.filter((t) => t.status === "deleted");
  if (ended.length > 0) {
    cards.push({
      key: "ended",
      figure: String(ended.length),
      title: plural(
        ended.length,
        "Ended organisation awaiting purge",
        "Ended organisations awaiting purge",
      ),
      sentence: `${listNames(ended.map((t) => t.name))} ${plural(ended.length, "has", "have")} ended, but ${plural(ended.length, "its", "their")} data is still held until somebody purges it.`,
      tone: "warn",
      action: ended.length === 1 ? "Open the organisation" : "Open organisations",
      target: pageOrList(ended),
    });
  }
  return cards;
}

/* -------------------------------------------------------------------------- */
/* The page.                                                                  */
/* -------------------------------------------------------------------------- */

/** One door's contribution to Today, however far it has got. */
export type TodaySource =
  | { key: string; label: string; state: "pending" }
  | { key: string; label: string; state: "error"; error: unknown }
  | { key: string; label: string; state: "ready"; cards: TodayCard[] };

export type TodaySummary = {
  /** What needs somebody, the serious first. */
  cards: TodayCard[];
  /** The doors that could not be read, each to be shown with its own error. */
  failed: { key: string; label: string; error: unknown }[];
  /** The doors still being read. */
  pending: { key: string; label: string }[];
  /** Every door answered and none of them found anything. */
  allClear: boolean;
};

export function summariseToday(sources: TodaySource[]): TodaySummary {
  const cards: TodayCard[] = [];
  const failed: TodaySummary["failed"] = [];
  const pending: TodaySummary["pending"] = [];
  for (const s of sources) {
    if (s.state === "pending") pending.push({ key: s.key, label: s.label });
    else if (s.state === "error") failed.push({ key: s.key, label: s.label, error: s.error });
    else cards.push(...s.cards);
  }
  // Stable within a tone: the order the sources were listed in is the order of
  // importance the page chose.
  const ordered = [
    ...cards.filter((c) => c.tone === "bad"),
    ...cards.filter((c) => c.tone === "warn"),
  ];
  return {
    cards: ordered,
    failed,
    pending,
    allClear: ordered.length === 0 && failed.length === 0 && pending.length === 0,
  };
}
