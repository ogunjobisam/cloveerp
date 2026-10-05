/**
 * The VAT returns, as data (PR14 M4).
 *
 * public.erp_vat_obligations answers each company's VAT periods
 * (20261001100000): its dates, when it is due and where it stands, the frozen
 * boxes of a finalised return, and for the rest the boxes finalising it now
 * would take. Since 20261001300000 each row also says what the two doors would
 * take from this reader: can_finalise on the period a company finalises next,
 * with finalise_blocked_by saying why not where it will not, and can_export on
 * a finalised return. public.erp_vat_boxes answers the exceptions to read
 * before finalising, over the same days finalising checks.
 *
 * The cycle is two presses (erp_meta.flow_budget, row vat): Finalise, then
 * Export. Everything here is pure so that `bun test` can hold it. A press is
 * drawn only where the database says its door would take it and the session
 * holds the permission the door asks; the database refuses regardless.
 */

export type VatStatus = "open" | "due" | "overdue" | "finalised";

export type VatBoxes = {
  box1_minor: number;
  box2_minor: number;
  box3_minor: number;
  box4_minor: number;
  /** Never negative: box5_is says which way it goes (D10). */
  box5_minor: number;
  box5_is: "payable" | "repayable";
  box6_pounds: number;
  box7_pounds: number;
  box8_pounds: number;
  box9_pounds: number;
};

export type VatCarriedForward = {
  entries: number;
  net_minor: number;
  tax_minor: number;
  over_threshold: boolean;
};

export type VatObligation = {
  entity_id: string;
  company: string;
  vrn: string;
  /** The company's own currency, which a return is made in. */
  currency: string;
  period_start: string;
  period_end: string;
  due_on: string;
  status: VatStatus;
  return_document_id: string | null;
  return_number: string | null;
  boxes: VatBoxes | null;
  entries: number;
  carried_forward: VatCarriedForward | null;
  /** The period its company finalises next: the earliest not finalised. */
  is_next: boolean;
  /** The first day a return made now would take entries from. */
  take_from: string | null;
  can_finalise: boolean;
  /** Why Finalise is not offered, in the database's words; null where it is. */
  finalise_blocked_by: string | null;
  can_export: boolean;
};

export type VatException = {
  finding: string;
  blocks: boolean;
  reference: string | null;
  detail: string;
};

type Raw = Record<string, unknown>;

const record = (v: unknown): Raw | null =>
  typeof v === "object" && v !== null && !Array.isArray(v) ? (v as Raw) : null;

const text = (v: unknown): string | null =>
  typeof v === "string" && v !== "" ? v : typeof v === "number" ? String(v) : null;

const num = (v: unknown): number => {
  const n = typeof v === "number" ? v : typeof v === "string" ? Number(v) : NaN;
  return Number.isFinite(n) ? n : 0;
};

const bool = (v: unknown): boolean => v === true;

const STATUSES: readonly VatStatus[] = ["open", "due", "overdue", "finalised"];

function boxes(raw: unknown): VatBoxes | null {
  const r = record(raw);
  if (!r) return null;
  return {
    box1_minor: num(r["box1_minor"]),
    box2_minor: num(r["box2_minor"]),
    box3_minor: num(r["box3_minor"]),
    box4_minor: num(r["box4_minor"]),
    box5_minor: Math.abs(num(r["box5_minor"])),
    box5_is: r["box5_is"] === "repayable" ? "repayable" : "payable",
    box6_pounds: num(r["box6_pounds"]),
    box7_pounds: num(r["box7_pounds"]),
    box8_pounds: num(r["box8_pounds"]),
    box9_pounds: num(r["box9_pounds"]),
  };
}

function carried(raw: unknown): VatCarriedForward | null {
  const r = record(raw);
  if (!r) return null;
  return {
    entries: num(r["entries"]),
    net_minor: num(r["net_minor"]),
    tax_minor: num(r["tax_minor"]),
    over_threshold: bool(r["over_threshold"]),
  };
}

function obligation(r: Raw): VatObligation | null {
  const entity = text(r["entity_id"]);
  const end = text(r["period_end"]);
  const status = STATUSES.find((s) => s === r["status"]);
  if (!entity || !end || !status) return null;
  return {
    entity_id: entity,
    company: text(r["company"]) ?? "",
    vrn: text(r["vrn"]) ?? "",
    currency: text(r["currency"]) ?? "GBP",
    period_start: text(r["period_start"]) ?? "",
    period_end: end,
    due_on: text(r["due_on"]) ?? "",
    status,
    return_document_id: text(r["return_document_id"]),
    return_number: text(r["return_number"]),
    boxes: boxes(r["boxes"]),
    entries: num(r["entries"]),
    carried_forward: carried(r["carried_forward"]),
    is_next: bool(r["is_next"]),
    take_from: text(r["take_from"]),
    // A database older than 20261001300000 does not say, and nothing is drawn.
    can_finalise: bool(r["can_finalise"]),
    finalise_blocked_by: text(r["finalise_blocked_by"]),
    can_export: bool(r["can_export"]),
  };
}

/** The obligations as the door answers them, whatever age the door is. */
export function normaliseObligations(raw: unknown): VatObligation[] {
  if (!Array.isArray(raw)) return [];
  return (raw as unknown[])
    .map(record)
    .filter((r): r is Raw => r !== null)
    .map(obligation)
    .filter((o): o is VatObligation => o !== null);
}

/**
 * The exceptions erp_vat_boxes answers for one company, blocking ones first.
 *
 * The door answers one row per company it was asked about, each with its
 * boxes and an `exceptions` array; the screen asks it for one company and
 * reads only the exceptions, because the boxes the return would take are the
 * obligation's own preview.
 */
export function exceptionsOf(raw: unknown, entityId: string): VatException[] {
  if (!Array.isArray(raw)) return [];
  const row = (raw as unknown[]).map(record).find((r) => r !== null && r["entity_id"] === entityId);
  const list = row ? row["exceptions"] : null;
  if (!Array.isArray(list)) return [];
  return (list as unknown[])
    .map(record)
    .filter((x): x is Raw => x !== null && text(x["finding"]) !== null)
    .map((x) => ({
      finding: text(x["finding"]) ?? "",
      blocks: bool(x["blocks"]),
      reference: text(x["reference"]),
      detail: text(x["detail"]) ?? "",
    }))
    .sort((a, b) => Number(b.blocks) - Number(a.blocks));
}

/** One line of what to check: a finding that blocks, or every check of one kind. */
export type VatFindingGroup = {
  finding: string;
  blocks: boolean;
  /** The first is drawn on the line; the rest unfold beneath it. */
  items: VatException[];
};

/**
 * The findings as the next return lists them (J-99): each one that blocks the
 * return on a line of its own, then the ones that only ask to be checked,
 * one line per kind of finding in the order the door gave them. A period of
 * weekly purchases from abroad has dozens of the same check; read one by one
 * they pushed Finalise off the screen.
 */
export function groupFindings(list: VatException[]): VatFindingGroup[] {
  const blocking = list
    .filter((x) => x.blocks)
    .map((x) => ({ finding: x.finding, blocks: true, items: [x] }));
  const flags = new Map<string, VatException[]>();
  for (const x of list) {
    if (x.blocks) continue;
    const kind = flags.get(x.finding);
    if (kind) kind.push(x);
    else flags.set(x.finding, [x]);
  }
  return [
    ...blocking,
    ...[...flags].map(([finding, items]) => ({ finding, blocks: false, items })),
  ];
}

// ── The two presses ─────────────────────────────────────────────────────────

/** What both doors ask (D13): the person who closes the books. */
export const VAT_PERMISSION = "finance.close_period";

export type VatPresses = { finalise: boolean; export: boolean };

/**
 * Finalise on the period a company finalises next, once it has ended, where
 * the row says the door would take it; Export on a finalised return, where
 * the row says so. Both only for a session that holds finance.close_period.
 */
export function vatPresses(row: VatObligation, can: (code: string) => boolean): VatPresses {
  const may = can(VAT_PERMISSION);
  return {
    finalise:
      may && row.can_finalise && row.is_next && (row.status === "due" || row.status === "overdue"),
    export: may && row.can_export && row.status === "finalised" && row.return_document_id !== null,
  };
}

/** The row the screen previews and offers Finalise on, per company. */
export function nextReturns(rows: VatObligation[]): VatObligation[] {
  return rows.filter((r) => r.is_next && r.status !== "finalised" && r.status !== "open");
}

// ── Export ──────────────────────────────────────────────────────────────────

export type VatExportFormat = "csv" | "json" | "entries_csv";

/** The three forms erp_vat_return_export makes, in the order they are offered. */
export const VAT_EXPORT_FORMATS: readonly { format: VatExportFormat; label: string }[] = [
  { format: "csv", label: "Nine boxes (CSV)" },
  { format: "json", label: "MTD body (JSON)" },
  { format: "entries_csv", label: "Entries (CSV)" },
];

export type VatExportFile = {
  filename: string;
  mediaType: string;
  body: string;
  sha256: string | null;
};

/**
 * The file the export door handed over, as it handed it over: the body is not
 * reformatted, so the sha256 on the return's vat_return.exported event is the
 * digest of what is saved. Null when the answer carries no body or no name.
 */
export function exportFile(raw: unknown): VatExportFile | null {
  const r = record(raw);
  if (!r) return null;
  const body = typeof r["body"] === "string" ? r["body"] : null;
  const filename = text(r["filename"]);
  if (body === null || !filename) return null;
  return {
    filename,
    mediaType: text(r["media_type"]) ?? "text/plain",
    body,
    sha256: text(r["sha256"]),
  };
}

// ── The nine boxes, as a person reads them ───────────────────────────────────

export type BoxLine = {
  box: number;
  label: string;
  /** Pence for boxes 1 to 5, whole pounds for 6 to 9. */
  minor: number;
  whole: boolean;
};

/**
 * VAT Notice 700/12's nine boxes in order. Box 5 carries no sign: the words
 * beside it say payable or repayable.
 */
export function boxLines(b: VatBoxes): BoxLine[] {
  return [
    { box: 1, label: "VAT due on sales", minor: b.box1_minor, whole: false },
    {
      box: 2,
      label: "VAT due on EU acquisitions, Northern Ireland",
      minor: b.box2_minor,
      whole: false,
    },
    { box: 3, label: "Total VAT due", minor: b.box3_minor, whole: false },
    { box: 4, label: "VAT reclaimed on purchases", minor: b.box4_minor, whole: false },
    { box: 5, label: "Net VAT", minor: b.box5_minor, whole: false },
    { box: 6, label: "Sales excluding VAT", minor: b.box6_pounds * 100, whole: true },
    { box: 7, label: "Purchases excluding VAT", minor: b.box7_pounds * 100, whole: true },
    {
      box: 8,
      label: "Goods supplied to the EU, Northern Ireland",
      minor: b.box8_pounds * 100,
      whole: true,
    },
    {
      box: 9,
      label: "Goods acquired from the EU, Northern Ireland",
      minor: b.box9_pounds * 100,
      whole: true,
    },
  ];
}

/** The status pill's tone. */
export function statusTone(status: VatStatus): "ok" | "warn" | "bad" | "muted" {
  return status === "finalised"
    ? "ok"
    : status === "overdue"
      ? "bad"
      : status === "due"
        ? "warn"
        : "muted";
}
