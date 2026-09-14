/**
 * Where the platform console is, as the address bar says it.
 *
 * The console held its section and tab in component state, so a link could
 * only open a section's first tab, Back left the console altogether, and
 * nothing could be bookmarked. The place is in the URL now —
 * `/platform?section=customers&view=organisations&org=demo-cbb10384` — and this
 * file is the one reading of it: which sections and tabs exist, what a search
 * string means, and what to do with one that means nothing.
 *
 * Pure, so the reading is tested without a browser. Nothing here imports the
 * Supabase client or a component; the route maps each view to its panel.
 */

export type ConsoleView = { key: string; label: string; group?: string };

export type ConsoleSection = {
  key: string;
  label: string;
  blurb: string;
  views: readonly ConsoleView[];
};

/**
 * The console's jobs, in the order somebody running the business meets them.
 *
 * A view's key is what the URL carries, so a key, once shipped, is a bookmark
 * somebody holds: rename a label freely, a key never.
 */
export const CONSOLE_SECTIONS = [
  {
    key: "today",
    label: "Today",
    blurb: "What needs you now, across every organisation.",
    views: [{ key: "today", label: "Today" }],
  },
  {
    key: "customers",
    label: "Customers",
    blurb: "The organisations on this deployment, with a page for each one.",
    views: [
      { key: "organisations", label: "All organisations" },
      { key: "ownership", label: "Ownership transfers" },
    ],
  },
  {
    key: "sales",
    label: "Sales",
    blurb:
      "Who has asked about Clove ERP, the quotes they were sent, and the contracts that came of it.",
    views: [
      { key: "enquiries", label: "Enquiries" },
      { key: "quotes", label: "Quotes" },
      { key: "contracts", label: "Contracts" },
    ],
  },
  {
    key: "catalogue",
    label: "Catalogue",
    blurb: "What Clove ERP sells: the price list behind every quote, and the plans.",
    views: [
      { key: "selling", label: "Selling setup" },
      { key: "plans", label: "Plans and subscriptions" },
    ],
  },
  {
    key: "billing",
    label: "Billing",
    blurb: "What the contracts add up to, and which ones are coming up for renewal.",
    views: [{ key: "revenue", label: "Revenue and renewals" }],
  },
  {
    key: "platform",
    label: "Platform",
    blurb: "Whether this deployment is sound, who works on it, and what they did.",
    views: [
      { key: "health", label: "Summary", group: "Health" },
      { key: "diagnostics", label: "Diagnostics", group: "Health" },
      { key: "queue", label: "Jobs and queue", group: "Health" },
      { key: "deployment", label: "Deployment", group: "Health" },
      { key: "incidents", label: "Incidents and notices", group: "Health" },
      { key: "staff", label: "Staff", group: "Governance" },
      { key: "activity", label: "Activity", group: "Governance" },
      { key: "decisions", label: "Decisions", group: "Governance" },
    ],
  },
] as const satisfies readonly ConsoleSection[];

export type SectionKey = (typeof CONSOLE_SECTIONS)[number]["key"];
export type ViewKey = (typeof CONSOLE_SECTIONS)[number]["views"][number]["key"];

/** What `/platform`'s search string holds once it has been read. */
export type ConsoleSearch = { section?: SectionKey; view?: ViewKey; org?: string };

/** Where the console is: always somewhere, never undefined. */
export type ConsoleLocation = {
  section: (typeof CONSOLE_SECTIONS)[number];
  view: ConsoleView & { key: ViewKey };
  /** The organisation whose page is open, by code; only ever under All organisations. */
  org: string | null;
};

/** The longest organisation code the URL is trusted with. Codes are short. */
const MAX_ORG_CODE = 100;

function sectionOf(key: unknown) {
  return CONSOLE_SECTIONS.find((s) => s.key === key);
}

/**
 * The router's default parser turns `?org=123` into the number 123, so a code
 * that happens to look like a number arrives as one.
 */
function asCode(value: unknown): string | null {
  const text = typeof value === "string" ? value : typeof value === "number" ? String(value) : null;
  if (text === null) return null;
  const code = text.trim();
  return code !== "" && code.length <= MAX_ORG_CODE ? code : null;
}

/**
 * The search string, read strictly.
 *
 * An unknown section, or a view that is not one of the section's, is Today:
 * the console never guesses at a place it does not have. A section without a
 * view opens its first. An organisation is kept only where there is a page to
 * show it on, All organisations, so it cannot leak into another tab's links.
 */
export function parseConsoleSearch(raw: Record<string, unknown>): ConsoleSearch {
  const section = sectionOf(raw["section"]);
  if (!section || section.key === "today") return {};

  const asked = raw["view"];
  const view =
    asked === undefined || asked === null || asked === ""
      ? section.views[0]
      : (section.views as readonly ConsoleView[]).find((v) => v.key === asked);
  if (!view) return {};

  const out: ConsoleSearch = { section: section.key, view: view.key as ViewKey };
  const org = asCode(raw["org"]);
  if (org !== null && section.key === "customers" && view.key === "organisations") out.org = org;
  return out;
}

/** The place a read search string names. */
export function locate(search: ConsoleSearch): ConsoleLocation {
  const parsed = parseConsoleSearch(search);
  const section = sectionOf(parsed.section) ?? CONSOLE_SECTIONS[0];
  const views = section.views as readonly (ConsoleView & { key: ViewKey })[];
  const view = views.find((v) => v.key === parsed.view) ?? views[0]!;
  return { section, view, org: parsed.org ?? null };
}

/**
 * The search string for a place, for a link. Today is the bare `/platform`, so
 * the address people type is the one they land on.
 */
export function consoleSearch(section: SectionKey, view?: ViewKey, org?: string): ConsoleSearch {
  if (section === "today") return {};
  return parseConsoleSearch({ section, view, org });
}

/** A demonstration organisation: seeded by erp_seed_demo, and coded `demo-…`. */
export function isDemoCode(code: string | null | undefined): boolean {
  return typeof code === "string" && code.startsWith("demo-");
}
