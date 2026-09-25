/**
 * The counter's worklist, as data (PR10 M3b).
 *
 * public.erp_count_tasks says where every count task stands
 * (20260927400000): the sheet and line it is on, the adjustment its post
 * wrote, whether the system posted it, why an approved count waits, and
 * whether the reader counted it. The screen walks that list the way the paper
 * is walked — sheet by sheet, line by line — and puts what is not simply
 * waiting to be counted in a table of its own.
 *
 * Everything here is pure so that `bun test` can hold it: which rows are work,
 * in what order, which are exceptions, why a held count waits, and which verbs
 * a row may be offered. The last is the X4 rule in one place: a control is
 * drawn only where the person can complete it. The database refuses
 * regardless; this only keeps the screen from offering refusals.
 */

export type CountStatus =
  "open" | "counted" | "pending_approval" | "approved" | "rejected" | "posted" | "cancelled";

/**
 * One row of erp_count_tasks. A key the database does not return is `null`,
 * never missing: a client newer than the database it talks to reads the keys
 * 20260927400000 added as absent, and `normalise` turns that into null so the
 * screen degrades (no sheet, no reason, no Print) rather than throws.
 */
export type CountTaskRow = {
  task_id: string;
  item: string;
  item_name: string | null;
  batch: string | null;
  /**
   * The stock status the count is of (20260928100000): available,
   * quarantine and so on. Null from a database older than that, and for a
   * count raised before it whose status is not known, which its held reason
   * says (`status_unknown`).
   */
  stock_status: string | null;
  site: string | null;
  site_id: string | null;
  location: string | null;
  programme: string | null;
  expected: number | null;
  counted: number | null;
  variance: number | null;
  within_tolerance: boolean | null;
  status: string;
  counted_at: string | null;
  posted_at: string | null;
  document_id: string | null;
  document_number: string | null;
  sheet_line_no: number | null;
  adjustment_document_id: string | null;
  adjustment_number: string | null;
  posted_by_system: boolean;
  post_held_reason: string | null;
  counted_by_me: boolean;
  /**
   * Whether erp_post_count would refuse this reader: they counted a non-zero
   * difference and the organisation is live, so somebody else posts it
   * (CLOVEERP_COUNT_SELF_POSTING). The door works it out (20260927400000).
   */
  post_refused_to_me: boolean;
};

const text = (v: unknown): string | null =>
  typeof v === "string" && v !== "" ? v : typeof v === "number" ? String(v) : null;

const num = (v: unknown): number | null => {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string" && v.trim() !== "" && Number.isFinite(Number(v))) return Number(v);
  return null;
};

const bool = (v: unknown): boolean | null => (typeof v === "boolean" ? v : null);

/** A row as the door answers it, whatever age the door is. */
export function normalise(raw: Record<string, unknown>): CountTaskRow {
  return {
    task_id: text(raw["task_id"]) ?? "",
    item: text(raw["item"]) ?? "",
    item_name: text(raw["item_name"]),
    batch: text(raw["batch"]),
    stock_status: text(raw["stock_status"]),
    site: text(raw["site"]),
    site_id: text(raw["site_id"]),
    location: text(raw["location"]),
    programme: text(raw["programme"]),
    expected: num(raw["expected"]),
    counted: num(raw["counted"]),
    variance: num(raw["variance"]),
    within_tolerance: bool(raw["within_tolerance"]),
    status: text(raw["status"]) ?? "open",
    counted_at: text(raw["counted_at"]),
    posted_at: text(raw["posted_at"]),
    document_id: text(raw["document_id"]),
    document_number: text(raw["document_number"]),
    sheet_line_no: num(raw["sheet_line_no"]),
    adjustment_document_id: text(raw["adjustment_document_id"]),
    adjustment_number: text(raw["adjustment_number"]),
    posted_by_system: bool(raw["posted_by_system"]) ?? false,
    post_held_reason: text(raw["post_held_reason"]),
    counted_by_me: bool(raw["counted_by_me"]) ?? false,
    post_refused_to_me: bool(raw["post_refused_to_me"]) ?? false,
  };
}

// ── Why a count waits ───────────────────────────────────────────────────────

/**
 * The codes erp.count_post_hold_reason() and erp.record_count() write, as
 * `code: English text`, and `status_unknown`, which the backfill of
 * 20260928100000 writes on a count raised before a count knew its stock
 * status, at a place that held more than one. `unknown` keeps anything else, so a code added later
 * still reaches the screen in the database's own words.
 */
export type HoldCode =
  | "held_by_policy"
  | "held_own_count"
  | "held_cumulative"
  | "post_refused"
  | "status_unknown"
  | "unknown";

export type HeldReason = {
  code: HoldCode;
  /**
   * What follows the code: the arithmetic of a cumulative hold, the SQLSTATE
   * and message of a refused post, or the whole text of a code not known
   * here. Null where the words for the code say everything.
   */
  detail: string | null;
};

const KNOWN: readonly HoldCode[] = [
  "held_by_policy",
  "held_own_count",
  "held_cumulative",
  "post_refused",
  "status_unknown",
];

export function heldReason(raw: string | null): HeldReason | null {
  if (raw === null || raw.trim() === "") return null;
  const at = raw.indexOf(":");
  const head = at < 0 ? raw.trim() : raw.slice(0, at).trim();
  const rest = at < 0 ? "" : raw.slice(at + 1).trim();
  const code = KNOWN.find((k) => k === head);
  if (!code) return { code: "unknown", detail: raw.trim() };
  // The policy's own two say nothing the words for them do not.
  if (code === "held_by_policy" || code === "held_own_count") return { code, detail: null };
  return { code, detail: rest === "" ? null : rest };
}

// ── The order of the walk ───────────────────────────────────────────────────

const byText = (a: string | null, b: string | null) => {
  if (a === b) return 0;
  if (a === null) return 1;
  if (b === null) return -1;
  return a.localeCompare(b, undefined, { numeric: true });
};

/**
 * Sheet by sheet, and down each sheet by its line, which is the order on the
 * paper. A count raised with no sheet (before inventory-operations 7) comes
 * after every sheet, by place and then product.
 */
export function worklistOrder<T extends CountTaskRow>(rows: readonly T[]): T[] {
  return [...rows].sort(
    (a, b) =>
      byText(a.document_number, b.document_number) ||
      (a.sheet_line_no ?? Number.MAX_SAFE_INTEGER) - (b.sheet_line_no ?? Number.MAX_SAFE_INTEGER) ||
      byText(a.location, b.location) ||
      byText(a.item, b.item) ||
      a.task_id.localeCompare(b.task_id),
  );
}

export type SheetGroup<T extends CountTaskRow = CountTaskRow> = {
  /** Null for the counts raised with no sheet. */
  document_id: string | null;
  document_number: string | null;
  rows: T[];
};

/** The ordered rows, one group per sheet, the counts with no sheet last. */
export function groupBySheet<T extends CountTaskRow>(rows: readonly T[]): SheetGroup<T>[] {
  const groups: SheetGroup<T>[] = [];
  for (const row of worklistOrder(rows)) {
    const last = groups[groups.length - 1];
    if (last && last.document_number === row.document_number) last.rows.push(row);
    else
      groups.push({
        document_id: row.document_id,
        document_number: row.document_number,
        rows: [row],
      });
  }
  return groups;
}

// ── Work and exceptions ─────────────────────────────────────────────────────

/** Waiting on somebody, and not simply on a counter. */
const EXCEPTIONAL: ReadonlySet<string> = new Set([
  "approved",
  "counted",
  "rejected",
  "pending_approval",
]);

/**
 * `toCount` is every open count, and every count recorded from this screen
 * since it opened, whatever became of it: the counter sees beside the place
 * what their figure did. `exceptions` is every count that waits on something
 * other than a counter: held, agreed, outside tolerance, refused or with its
 * approver. Posted and cancelled counts are neither; the balances below the
 * worklist already show what they did.
 */
export function splitWorklist<T extends CountTaskRow>(
  rows: readonly T[],
  recordedHere: ReadonlySet<string> = new Set(),
): { toCount: T[]; exceptions: T[] } {
  const toCount = worklistOrder(
    rows.filter((r) => r.status === "open" || recordedHere.has(r.task_id)),
  );
  const exceptions = worklistOrder(rows.filter((r) => EXCEPTIONAL.has(r.status)));
  return { toCount, exceptions };
}

/**
 * A count held because nobody knows which stock status it is of
 * (20260928100000). It is not recorded; it is cancelled and raised again.
 */
export function statusUnknown(row: CountTaskRow): boolean {
  return heldReason(row.post_held_reason)?.code === "status_unknown";
}

/** A site chosen in the header narrows the list; no choice, or no site on the row, does not. */
export function inSite<T extends CountTaskRow>(rows: readonly T[], siteId: string): T[] {
  if (!siteId) return [...rows];
  return rows.filter((r) => r.site_id === null || r.site_id === siteId);
}

// ── What a row may be offered ───────────────────────────────────────────────

export type RowActions = {
  record: boolean;
  post: boolean;
  /**
   * Post would be the reader's to press but for having counted it: said in
   * words instead of drawn, because the door refuses the counter's own post.
   */
  postIsSomebodyElses: boolean;
  recount: boolean;
  /** The permission erp_cancel_count_task asks in this state, or null for no Cancel. */
  cancel: "inventory.count" | "inventory.adjust" | null;
};

/**
 * The verbs each state's door accepts, for somebody holding what it asks:
 *
 *   open                 Record (inventory.count), Cancel (inventory.count);
 *                        no Record where its status is not known, which
 *                        the door refuses (CLOVEERP_COUNT_STATUS_UNKNOWN)
 *   counted, rejected    Count it again and Cancel (inventory.adjust); only
 *                        Cancel where its status is not known
 *   approved             Post (inventory.adjust) — not where the door would
 *                        refuse the reader for having counted it
 *                        (post_refused_to_me), nor where its status is not
 *                        known and it found a difference
 *   pending_approval     nothing: the decision is the approver's
 *   posted, cancelled    nothing
 */
export function actionsFor(row: CountTaskRow, can: (code: string) => boolean): RowActions {
  const none: RowActions = {
    record: false,
    post: false,
    postIsSomebodyElses: false,
    recount: false,
    cancel: null,
  };
  switch (row.status) {
    case "open": {
      const count = can("inventory.count");
      return {
        ...none,
        record: count && !statusUnknown(row),
        cancel: count ? "inventory.count" : null,
      };
    }
    case "counted":
    case "rejected": {
      const adjust = can("inventory.adjust");
      return {
        ...none,
        recount: adjust && !statusUnknown(row),
        cancel: adjust ? "inventory.adjust" : null,
      };
    }
    case "approved": {
      // A count of no known status with a difference has no status to post
      // it to; the door refuses it (CLOVEERP_COUNT_STATUS_UNKNOWN).
      const adjust = can("inventory.adjust") && !(statusUnknown(row) && (row.variance ?? 0) !== 0);
      return {
        ...none,
        post: adjust && !row.post_refused_to_me,
        postIsSomebodyElses: adjust && row.post_refused_to_me,
      };
    }
    default:
      return none;
  }
}

// ── The printed sheet ───────────────────────────────────────────────────────

/** One block of a rendered document, as erp.render_output_template() answers it. */
export type RenderedBlock = {
  kind: string;
  label?: string;
  fields?: { field: string; label?: string; value?: unknown }[];
  rows?: Record<string, unknown>[];
  columns?: { field: string; label?: string }[];
};

export type RenderedDocument = {
  template?: string;
  title?: string;
  kind?: string;
  page?: string;
  locale?: string;
  document_id?: string;
  blocks?: RenderedBlock[];
};

/**
 * A rendered value as text. The renderer strips nulls from what it returns,
 * so a key may be missing: that, like null, is a blank on the paper.
 */
export function printed(value: unknown): string {
  if (value === null || value === undefined) return "";
  if (typeof value === "string") return value;
  if (typeof value === "number" || typeof value === "boolean") return String(value);
  // A list, or an object such as an address snapshot: its parts, one to a
  // line, in the order they were written, and never the braces.
  const parts = Array.isArray(value) ? value : Object.values(value as Record<string, unknown>);
  return parts
    .map((p) => printed(p))
    .filter((p) => p !== "")
    .join("\n");
}

/**
 * The paper size a rendered sheet asks for, as a CSS page size, or A4. Only
 * words and digits pass, because it is written into a stylesheet.
 */
export function pageSize(page: unknown): string {
  return typeof page === "string" && /^[A-Za-z0-9]+( (portrait|landscape))?$/.test(page.trim())
    ? page.trim()
    : "A4";
}
