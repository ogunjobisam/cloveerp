/**
 * A queued notification, as an email somebody can act on.
 *
 * erp.notification carries a subject and a plain body, which is all an in-app
 * notice needs and not enough for an email: "A document is waiting for your
 * approval" and an address. Since 20260914094000 a notification the product
 * writes for email also carries a context — what kind of ask it is, the facts
 * it rests on, the words in the reader's language and the paths of the screens
 * where they act — frozen when the notification was routed. The claim
 * (erp.claim_email_batch) adds the names of the people it mentions, read at
 * that moment rather than frozen, so an erased person is not kept alive in a
 * queue. This file turns that into renderEmail() input.
 *
 * The database decides what is said: which words, in which language, which
 * variant (escalated or not, a document or not), and every link path. This
 * file decides how it looks: dates and money formatted for the reader, rows in
 * a fixed order, links made absolute. Anything it cannot read throws, and the
 * caller sends the plain body instead (composeNotificationEmail), because an
 * email that says too little is better than one that is not sent.
 *
 * Imports only the layout, by a relative path with its extension, so the
 * dispatch worker, the dispatch Edge Function under Deno and the desk can all
 * read it.
 */

import { oneLine, renderEmail, type EmailDetail, type EmailInput } from "./layout.ts";

/** The desk, when nothing configures another. The invite function uses the same. */
export const DEFAULT_APP_ORIGIN = "https://cloveerp.com";

/**
 * The site an email's links open: CLOVEERP_APP_URL's origin, as the invite
 * function reads it, or the product's own address.
 */
export function appOrigin(configured: string | null | undefined): string {
  const value = (configured ?? "").trim();
  if (value !== "") {
    try {
      const url = new URL(value);
      if (url.protocol === "https:" || url.protocol === "http:") return url.origin;
    } catch {
      // Not a URL: the default below.
    }
  }
  return DEFAULT_APP_ORIGIN;
}

export const NOTIFICATION_KINDS = [
  "approval",
  "change_set",
  "job_failed",
  "support_access",
  "incident",
  "digest",
] as const;

export type NotificationKind = (typeof NOTIFICATION_KINDS)[number];

/** What erp.claim_email_batch() returns, as far as an email needs it. */
export type ClaimedNotification = {
  id?: string | null;
  subject: string | null;
  body: string | null;
  context?: unknown;
  organisation_name?: string | null;
  recipient_name?: string | null;
  /**
   * The decision link's token, when the claim minted one (20260914096000): only
   * for an approval task still waiting on the reader. Returned once and never
   * stored, so it goes into the email and nowhere else — never into a log.
   */
  action_token?: string | null;
};

/** What a decision link's token looks like: 32 random bytes, as hex. */
const ACTION_TOKEN = /^[0-9a-f]{64}$/;

/**
 * The page a decision button opens, with the token and the decision in the
 * fragment. A fragment is never sent to a server, so the token reaches no
 * access log, no proxy and no link scanner; src/lib/email-action.ts reads it.
 */
export function actionLink(origin: string, token: string, decision: "approve" | "reject"): string {
  return `${origin.replace(/\/+$/, "")}/act#t=${encodeURIComponent(token)}&d=${decision}`;
}

export type NotificationEmail = { subject: string; text: string; html: string };

/** A context this file cannot make an email of. The message says what was wrong. */
export class NotificationContextError extends Error {}

type Dict = Record<string, unknown>;

type Context = {
  kind: NotificationKind;
  locale: string;
  timeZone: string;
  mandatory: boolean;
  words: Record<string, string>;
  labels: Record<string, string>;
  links: Record<string, string>;
  fields: Dict;
  names: Record<string, string>;
};

function isDict(value: unknown): value is Dict {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function strings(value: unknown): Record<string, string> {
  const out: Record<string, string> = {};
  if (!isDict(value)) return out;
  for (const [k, v] of Object.entries(value)) {
    if (typeof v === "string" && v.trim() !== "") out[k] = v;
  }
  return out;
}

function readContext(raw: unknown): Context {
  const value = typeof raw === "string" ? (JSON.parse(raw) as unknown) : raw;
  if (!isDict(value)) throw new NotificationContextError("the context is not an object");
  const kind = value["kind"];
  if (typeof kind !== "string" || !(NOTIFICATION_KINDS as readonly string[]).includes(kind)) {
    throw new NotificationContextError(
      `the context names no kind this sender knows: ${String(kind)}`,
    );
  }
  const locale = typeof value["locale"] === "string" ? value["locale"] : "en";
  const timeZone = typeof value["time_zone"] === "string" ? value["time_zone"] : "UTC";
  return {
    kind: kind as NotificationKind,
    locale,
    timeZone,
    mandatory: value["mandatory"] === true,
    words: strings(value["words"]),
    labels: strings(value["labels"]),
    links: strings(value["links"]),
    fields: isDict(value["fields"]) ? value["fields"] : {},
    names: strings(value["names"]),
  };
}

/* -------------------------------------------------------------------------- */
/* Formatting for the reader                                                  */
/* -------------------------------------------------------------------------- */

/** Intl reads "en" as American; the product writes British English. */
function formattingLocale(locale: string): string {
  const tag = locale.trim() === "" || locale === "en" ? "en-GB" : locale;
  try {
    return Intl.getCanonicalLocales(tag)[0] ?? "en-GB";
  } catch {
    return "en-GB";
  }
}

/**
 * "14 September 2026, 10:15 BST", in the reader's time zone; UTC when that zone
 * is unknown.
 *
 * The date and the time are formatted apart and joined, with the month in full:
 * engines ship different ICU data, and a short month ("Sep" or "Sept") or the
 * joining word ("at" or a comma) would otherwise differ between the worker under
 * Bun and the dispatch function under Deno.
 */
export function formatInstant(value: unknown, locale: string, timeZone: string): string | null {
  if (typeof value !== "string" || value.trim() === "") return null;
  // Postgres writes microseconds; not every engine parses more than three digits.
  const iso = value.trim().replace(/(\.\d{3})\d+/, "$1");
  const when = new Date(iso);
  if (Number.isNaN(when.getTime())) return null;
  const tag = formattingLocale(locale);
  const format = (zone: string) =>
    `${new Intl.DateTimeFormat(tag, { day: "numeric", month: "long", year: "numeric", timeZone: zone }).format(when)}, ` +
    new Intl.DateTimeFormat(tag, {
      hour: "2-digit",
      minute: "2-digit",
      hourCycle: "h23",
      timeZoneName: "short",
      timeZone: zone,
    }).format(when);
  try {
    return format(timeZone);
  } catch {
    return format("UTC");
  }
}

/** Minor units as money: 420000 GBP with 2 minor units is "£4,200.00". */
export function formatMinor(
  minor: unknown,
  currency: unknown,
  minorUnits: unknown,
  locale: string,
): string | null {
  const amount = typeof minor === "string" ? Number(minor) : minor;
  if (typeof amount !== "number" || !Number.isFinite(amount)) return null;
  if (typeof currency !== "string" || !/^[A-Z]{3}$/.test(currency)) return null;
  const digits =
    typeof minorUnits === "number" &&
    Number.isInteger(minorUnits) &&
    minorUnits >= 0 &&
    minorUnits <= 4
      ? minorUnits
      : 2;
  return new Intl.NumberFormat(formattingLocale(locale), {
    style: "currency",
    currency,
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  }).format(amount / 10 ** digits);
}

function text(value: unknown): string | null {
  if (typeof value === "string") return value.trim() === "" ? null : value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return null;
}

/**
 * The words with their {placeholders} filled. A placeholder nothing supplies
 * is a defect in the words or the context, and sending "{number}" to a person
 * is worse than sending the plain body, so it throws.
 */
export function fill(template: string, values: Readonly<Record<string, string | null>>): string {
  return template.replace(/\{([a-z_]+)\}/g, (_, name: string) => {
    const value = values[name];
    if (value === null || value === undefined || value.trim() === "") {
      throw new NotificationContextError(`the words ask for {${name}} and the context has none`);
    }
    return oneLine(value, 160);
  });
}

function link(origin: string, path: string | undefined): string | null {
  if (path === undefined) return null;
  // A path on this site and nothing else: no scheme, no second slash, no
  // backslash a browser would read as one.
  if (!/^\/(?![/\\])[^\s]*$/.test(path)) {
    throw new NotificationContextError(`the context's link is not a path on the site: ${path}`);
  }
  return `${origin.replace(/\/+$/, "")}${path}`;
}

/* -------------------------------------------------------------------------- */
/* Each kind: its placeholders and its rows                                   */
/* -------------------------------------------------------------------------- */

type Shape = {
  values: Record<string, string | null>;
  details: EmailDetail[];
  quote: string | null;
};

function detail(
  c: Context,
  key: string,
  value: string | null,
  extra: Partial<EmailDetail> = {},
): EmailDetail | null {
  if (value === null || value.trim() === "") return null;
  const label = c.labels[key];
  if (label === undefined) {
    throw new NotificationContextError(`the context has no label for ${key}`);
  }
  return { label, value, ...extra };
}

function rows(list: ReadonlyArray<EmailDetail | null>): EmailDetail[] {
  return list.filter((d): d is EmailDetail => d !== null);
}

function shapeOf(c: Context): Shape {
  const f = c.fields;
  const at = (key: string) => formatInstant(f[key], c.locale, c.timeZone);
  switch (c.kind) {
    case "approval": {
      const value = formatMinor(f["value_minor"], f["currency"], f["minor_units"], c.locale);
      return {
        values: {
          number: text(f["document_number"]),
          value,
          document_type: text(f["document_type"]),
          step: text(f["step"]),
        },
        details: rows([
          detail(c, "document_type", text(f["document_type"])),
          detail(c, "number", text(f["document_number"])),
          detail(c, "partner", text(f["partner"])),
          detail(c, "value", value),
          detail(c, "step", text(f["step"])),
          detail(c, "requested_by", c.names["requested_by"] ?? null),
          detail(c, "requested_at", at("requested_at")),
          detail(c, "due_at", at("due_at")),
          detail(c, "delegated_from", c.names["delegated_from"] ?? null),
          detail(c, "escalated_from", c.names["escalated_from"] ?? null),
        ]),
        quote: null,
      };
    }
    case "change_set":
      return {
        values: { count: text(f["item_count"]), code: text(f["code"]) },
        details: rows([
          detail(c, "name", text(f["name"])),
          detail(c, "code", text(f["code"])),
          detail(c, "item_count", text(f["item_count"])),
          detail(c, "submitted_by", c.names["submitted_by"] ?? null),
          detail(c, "submitted_at", at("submitted_at")),
        ]),
        quote: null,
      };
    case "job_failed": {
      const code = text(f["job_code"]);
      const name = text(f["job_name"]);
      return {
        values: { job: code, count: text(f["consecutive_failures"]) },
        details: rows([
          detail(c, "job", name && code && name !== code ? `${name} (${code})` : (name ?? code)),
          detail(c, "handler", text(f["handler_name"]) ?? text(f["handler"])),
          detail(c, "failures", text(f["consecutive_failures"])),
          detail(c, "failed_at", at("failed_at")),
          detail(c, "error", text(f["error"]), { monospace: true }),
        ]),
        quote: null,
      };
    }
    case "support_access":
      return {
        values: { expires: at("expires_at"), role: text(f["staff_role"]) },
        details: rows([
          detail(c, "staff", c.names["staff"] ?? null),
          detail(c, "role", text(f["staff_role"])),
          detail(c, "reason", text(f["reason"])),
          detail(c, "access", c.words["access"] ?? null),
          detail(c, "granted_at", at("granted_at")),
          detail(c, "expires_at", at("expires_at")),
        ]),
        quote: null,
      };
    case "incident": {
      const components = Array.isArray(f["components"])
        ? f["components"].filter((x): x is string => typeof x === "string" && x.trim() !== "")
        : [];
      return {
        values: {
          code: text(f["code"]),
          severity: text(f["severity"]),
          next_update: at("next_update_at"),
        },
        details: rows([
          detail(c, "incident", text(f["title"])),
          detail(c, "code", text(f["code"])),
          detail(c, "severity", text(f["severity"])),
          detail(c, "components", components.length > 0 ? components.join(", ") : null),
          detail(c, "declared_at", at("declared_at")),
          detail(c, "next_update_at", at("next_update_at")),
        ]),
        quote: text(f["body"]),
      };
    }
    case "digest": {
      const items = Array.isArray(f["items"]) ? f["items"] : [];
      return {
        values: { count: text(f["count"]), more: text(f["more"]) },
        details: items.flatMap((item): EmailDetail[] => {
          if (!isDict(item)) return [];
          const subject = text(item["subject"]);
          const when = formatInstant(item["at"], c.locale, c.timeZone);
          return subject ? [{ label: when ?? "", value: subject }] : [];
        }),
        quote: null,
      };
    }
  }
}

/**
 * The email a context describes. Throws NotificationContextError, or whatever
 * Intl throws for a currency or locale it cannot format, when the context
 * cannot be read; composeNotificationEmail() is the caller that catches.
 */
export function renderNotificationEmail(
  row: ClaimedNotification,
  origin: string,
): NotificationEmail {
  const c = readContext(row.context);
  const shape = shapeOf(c);
  const values: Record<string, string | null> = {
    ...shape.values,
    organisation: oneLine(row.organisation_name) || null,
    name: oneLine(row.recipient_name) || null,
  };
  const need = (slot: string): string => {
    const words = c.words[slot];
    if (words === undefined)
      throw new NotificationContextError(`the context has no words for ${slot}`);
    return fill(words, values);
  };
  const maybe = (slot: string): string | null =>
    c.words[slot] === undefined ? null : fill(c.words[slot] ?? "", values);

  const primaryUrl = link(origin, c.links["primary"]);
  if (primaryUrl === null) throw new NotificationContextError("the context has no primary link");
  const secondaryUrl = link(origin, c.links["secondary"]);
  const preferencesUrl = link(origin, c.links["preferences"]);

  // Approve and Reject, when the claim minted a link and the context carries
  // their words. They open a page where the person signs in and confirms: the
  // email decides nothing. The task and the document become plain links below.
  const token =
    c.kind === "approval" &&
    typeof row.action_token === "string" &&
    ACTION_TOKEN.test(row.action_token)
      ? row.action_token
      : null;
  const acting =
    token !== null && c.words["approve"] !== undefined && c.words["reject"] !== undefined;

  const subject = oneLine(need("subject"), 150);
  const input: EmailInput = {
    organisation: row.organisation_name ?? null,
    title: subject,
    lang: c.locale,
    preheader: need("preheader"),
    greeting: values["name"] ? maybe("greeting") : null,
    heading: need("heading"),
    intro: need("intro"),
    details: shape.details,
    quote: shape.quote,
    primary:
      acting && token
        ? { label: need("approve"), url: actionLink(origin, token, "approve") }
        : { label: need("primary"), url: primaryUrl },
    secondary:
      acting && token
        ? { label: need("reject"), url: actionLink(origin, token, "reject") }
        : secondaryUrl && c.words["secondary"] !== undefined
          ? { label: need("secondary"), url: secondaryUrl }
          : null,
    links: acting
      ? [
          { label: maybe("open_task") ?? need("primary"), url: primaryUrl },
          ...(secondaryUrl && c.words["secondary"] !== undefined
            ? [{ label: need("secondary"), url: secondaryUrl }]
            : []),
        ]
      : null,
    note: acting ? (maybe("note_actions") ?? maybe("note")) : maybe("note"),
    reason: need("reason"),
    preferencesUrl,
    mandatory: c.mandatory ? need("mandatory") : null,
    footer: values["organisation"] ? maybe("footer") : null,
    words: {
      ...(c.words["fallback"] ? { fallback: c.words["fallback"] } : {}),
      ...(c.words["preferences"] ? { preferences: c.words["preferences"] } : {}),
    },
  };
  const rendered = renderEmail(input);
  return { subject, text: rendered.text, html: rendered.html };
}

export type ComposedEmail = {
  subject: string;
  /** The text part: the rendered text, or the notification's own body. */
  body: string;
  html: string | null;
  /** Why the plain body went instead of the rendered email, when it did. */
  fallback: string | null;
};

/**
 * What the drain sends for one claimed notification.
 *
 * The rendered email when the notification has a context and it renders; the
 * subject and body the notification was written with otherwise, which is what
 * every email said before contexts existed. A context that does not render is
 * reported in `fallback` for the caller to log, and never stops the send.
 */
export function composeNotificationEmail(row: ClaimedNotification, origin: string): ComposedEmail {
  const plain = { subject: row.subject ?? "", body: row.body ?? "", html: null };
  if (row.context === null || row.context === undefined) return { ...plain, fallback: null };
  try {
    const email = renderNotificationEmail(row, origin);
    return { subject: email.subject, body: email.text, html: email.html, fallback: null };
  } catch (err) {
    const reason = err instanceof Error ? err.message : String(err);
    return { ...plain, fallback: reason || "the context could not be rendered" };
  }
}
