import { parseCsv, type CsvRecord } from "./import/csv";
import { normaliseHeading } from "./import/headers";
import { parseMinor, parseUkDate } from "./import/values";

/**
 * A bank statement file, read in the browser and sent to
 * public.erp_import_bank_statement (20261013020000) as lines the database
 * checks again.
 *
 * Bank reconciliation, pull request 2 (owner, 13 October 2026). The owner chose
 * the big four (Barclays, Lloyds, NatWest/RBS, HSBC), the challengers
 * (Starling, Monzo, Tide), any other CSV mapped once, and OFX for any bank that
 * offers it. The layouts below are the ones these banks' online banking
 * exports; a file whose headings match none of them is read through a mapping
 * the person makes, and remembered for that bank account.
 *
 * Everything here is pure, so `bun test` holds it. Money is in exact minor
 * units, positive in and negative out, as the statement reads to the account
 * holder. Dates are ISO, read day first.
 */

/** One line of a statement, as it goes to the door. */
export type StatementLine = {
  /** The file's line, for the person reading a finding. */
  line: number;
  bookedOn: string;
  /** Minor units: positive is money in, negative money out. */
  amountMinor: number;
  description: string;
  reference: string | null;
  /** OFX's own identifier for the transaction: exact duplicate detection. */
  fitid: string | null;
  /** The running balance after this line, where the bank prints one. */
  balanceMinor: number | null;
};

export type Finding = { line: number | null; message: string };

export type ParsedStatement = {
  format: "csv" | "ofx";
  /** The layout read: a bank's id, "mapped" or "ofx". */
  source: string;
  sourceLabel: string;
  /** Oldest first. */
  lines: StatementLine[];
  startsOn: string | null;
  endsOn: string | null;
  /** Worked out from the bank's running balance, or the OFX ledger balance. */
  openingMinor: number | null;
  closingMinor: number | null;
  findings: Finding[];
  /** The last four digits of the account the file is for, where it says. */
  accountLast4: string | null;
};

/** Which column of a file holds what. Amount, or paid in and out, not both. */
export type ColumnMap = {
  date: number | null;
  description: number | null;
  amount: number | null;
  paidIn: number | null;
  paidOut: number | null;
  balance: number | null;
  reference: number | null;
  /** Some banks print money out as positive in the amount column. */
  amountOutIsPositive?: boolean;
};

export type Layout = {
  id: string;
  label: string;
  /** Normalised headings this layout's file carries, every one. */
  requires: string[];
  /** Normalised heading per role; the first present is read. */
  columns: {
    date: string[];
    description: string[];
    amount?: string[];
    paidIn?: string[];
    paidOut?: string[];
    balance?: string[];
    reference?: string[];
  };
  /** Several description columns are joined, in this order. */
  joinDescription?: string[];
};

/**
 * The layouts the owner chose. Headings are compared normalised (lower case,
 * letters and digits only), so "Paid in" and "PAID IN" are the same.
 */
export const LAYOUTS: readonly Layout[] = [
  {
    id: "barclays",
    label: "Barclays",
    requires: ["number", "date", "account", "amount", "subcategory", "memo"],
    columns: { date: ["date"], description: ["memo"], amount: ["amount"] },
  },
  {
    id: "lloyds",
    label: "Lloyds, Halifax or Bank of Scotland",
    requires: ["transactiondate", "transactiondescription", "debitamount", "creditamount"],
    columns: {
      date: ["transactiondate"],
      description: ["transactiondescription"],
      paidIn: ["creditamount"],
      paidOut: ["debitamount"],
      balance: ["balance"],
    },
  },
  {
    id: "natwest",
    label: "NatWest, RBS or Ulster",
    requires: ["date", "type", "description", "value", "balance"],
    columns: {
      date: ["date"],
      description: ["description"],
      amount: ["value"],
      balance: ["balance"],
    },
  },
  {
    id: "hsbc",
    label: "HSBC",
    requires: ["date", "description", "amount"],
    columns: {
      date: ["date"],
      description: ["description"],
      amount: ["amount"],
      balance: ["balance"],
    },
  },
  {
    id: "starling",
    label: "Starling",
    requires: ["date", "counterparty", "reference", "amountgbp"],
    columns: {
      date: ["date"],
      description: ["counterparty"],
      reference: ["reference"],
      amount: ["amountgbp"],
      balance: ["balancegbp"],
    },
  },
  {
    id: "monzo",
    label: "Monzo",
    requires: ["transactionid", "date", "name", "amount", "currency"],
    columns: {
      date: ["date"],
      description: ["name"],
      reference: ["notesandtags", "description"],
      amount: ["amount"],
    },
  },
  {
    id: "tide",
    label: "Tide",
    requires: ["date", "transactiondescription", "paidin", "paidout"],
    columns: {
      date: ["date"],
      description: ["transactiondescription"],
      reference: ["reference"],
      paidIn: ["paidin"],
      paidOut: ["paidout"],
    },
  },
];

/** The headings a mapping offers for each role, for the person who maps one. */
export const MAPPABLE: readonly { key: keyof ColumnMap; label: string; required: boolean }[] = [
  { key: "date", label: "Date", required: true },
  { key: "description", label: "Description", required: true },
  { key: "amount", label: "Amount (money in positive, out negative)", required: false },
  { key: "paidIn", label: "Paid in", required: false },
  { key: "paidOut", label: "Paid out", required: false },
  { key: "balance", label: "Balance", required: false },
  { key: "reference", label: "Reference", required: false },
];

function indexOf(headings: readonly string[], names: readonly string[] | undefined): number | null {
  for (const n of names ?? []) {
    const i = headings.indexOf(n);
    if (i >= 0) return i;
  }
  return null;
}

/** The layout a file's heading row matches best, and its column map. */
export function detectLayout(
  headingRow: readonly string[],
): { layout: Layout; map: ColumnMap } | null {
  const headings = headingRow.map(normaliseHeading);
  // The most specific layout first: Barclays and Monzo both carry "amount".
  const ordered = [...LAYOUTS].sort((a, b) => b.requires.length - a.requires.length);
  for (const layout of ordered) {
    if (!layout.requires.every((r) => headings.includes(r))) continue;
    return {
      layout,
      map: {
        date: indexOf(headings, layout.columns.date),
        description: indexOf(headings, layout.columns.description),
        amount: indexOf(headings, layout.columns.amount),
        paidIn: indexOf(headings, layout.columns.paidIn),
        paidOut: indexOf(headings, layout.columns.paidOut),
        balance: indexOf(headings, layout.columns.balance),
        reference: indexOf(headings, layout.columns.reference),
      },
    };
  }
  return null;
}

/** Whether a mapping can read a statement: a date, a description, and money. */
export function mapIsComplete(map: ColumnMap): boolean {
  return (
    map.date !== null &&
    map.description !== null &&
    (map.amount !== null || (map.paidIn !== null && map.paidOut !== null))
  );
}

/** The row of a file that carries its headings: the first a layout or a date column names. */
export function findHeadingRow(records: readonly CsvRecord[], scan = 15): number {
  for (let i = 0; i < Math.min(records.length, scan); i++) {
    const fields = records[i]?.fields ?? [];
    if (detectLayout(fields)) return i;
    const norm = fields.map(normaliseHeading);
    if (norm.some((h) => h === "date" || h === "transactiondate" || h === "postingdate")) return i;
  }
  return 0;
}

function money(text: string | undefined): number | null {
  const t = (text ?? "").trim();
  if (t === "") return null;
  const parsed = parseMinor(t);
  return parsed.ok ? parsed.minor : null;
}

/**
 * The statement a CSV file holds, read through a column map. Rows that carry
 * no date and no money (blank lines, a footer) are passed over; a row that
 * carries one and not the other is a finding.
 */
export function readCsvStatement(
  text: string,
  map: ColumnMap,
  source: { id: string; label: string },
): ParsedStatement {
  const findings: Finding[] = [];
  const parsed = parseCsv(text);
  if (parsed.unterminatedAt !== null) {
    findings.push({ line: parsed.unterminatedAt, message: "A quote opens here and never closes." });
  }
  const headingAt = findHeadingRow(parsed.records);
  const body = parsed.records.slice(headingAt + 1);
  const lines: StatementLine[] = [];
  for (const r of body) {
    const f = r.fields;
    const cell = (i: number | null) => (i === null ? "" : (f[i] ?? "").trim());
    const dateText = cell(map.date);
    let amount: number | null = null;
    if (map.amount !== null) {
      const a = money(cell(map.amount));
      amount = a === null ? null : map.amountOutIsPositive ? -a : a;
    } else {
      const inn = money(cell(map.paidIn)) ?? 0;
      const out = money(cell(map.paidOut)) ?? 0;
      const any = cell(map.paidIn) !== "" || cell(map.paidOut) !== "";
      amount = any ? Math.abs(inn) - Math.abs(out) : null;
    }
    if (dateText === "" && amount === null) continue;
    const bookedOn = parseUkDate(dateText);
    if (!bookedOn) {
      findings.push({ line: r.line, message: `“${dateText}” is not a date.` });
      continue;
    }
    if (amount === null) {
      findings.push({ line: r.line, message: "This line carries no amount." });
      continue;
    }
    if (amount === 0) continue;
    const description = cell(map.description);
    lines.push({
      line: r.line,
      bookedOn,
      amountMinor: amount,
      description: description === "" ? "(no description)" : description,
      reference: cell(map.reference) === "" ? null : cell(map.reference),
      fitid: null,
      balanceMinor: money(cell(map.balance)),
    });
  }
  return finish("csv", source.id, source.label, lines, null, null, findings, null);
}

/**
 * Oldest first, keeping the bank's order within a day; and the opening and
 * closing balances from the running balance where the bank prints one.
 */
function finish(
  format: "csv" | "ofx",
  source: string,
  sourceLabel: string,
  raw: StatementLine[],
  opening: number | null,
  closing: number | null,
  findings: Finding[],
  accountLast4: string | null,
): ParsedStatement {
  // Banks export newest first or oldest first. Read which from the dates and
  // keep the order within a day as the bank printed it.
  const first = raw[0]?.bookedOn ?? "";
  const last = raw[raw.length - 1]?.bookedOn ?? "";
  const lines = first > last ? [...raw].reverse() : [...raw];
  let openingMinor = opening;
  let closingMinor = closing;
  const head = lines[0];
  const tail = lines[lines.length - 1];
  if (openingMinor === null && head && head.balanceMinor !== null) {
    openingMinor = head.balanceMinor - head.amountMinor;
  }
  if (closingMinor === null && tail && tail.balanceMinor !== null) {
    closingMinor = tail.balanceMinor;
  }
  if (openingMinor !== null && closingMinor !== null) {
    const total = lines.reduce((s, l) => s + l.amountMinor, 0);
    if (openingMinor + total !== closingMinor) {
      findings.push({
        line: null,
        message:
          "The lines do not add up from the opening balance to the closing balance. A line may be missing, or the file is not in the bank's order.",
      });
    }
  }
  return {
    format,
    source,
    sourceLabel,
    lines,
    startsOn: head?.bookedOn ?? null,
    endsOn: tail?.bookedOn ?? null,
    openingMinor,
    closingMinor,
    findings,
    accountLast4,
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// OFX
// ─────────────────────────────────────────────────────────────────────────────

/** A tag's value in OFX, 1.x (SGML, no closing tags) or 2.x (XML). */
function tagValue(block: string, tag: string): string | null {
  const m = new RegExp(`<${tag}>([^<\\r\\n]*)`, "i").exec(block);
  const v = m?.[1]?.trim();
  return v === undefined || v === "" ? null : v;
}

/** OFX's 20261013120000[0:GMT] as an ISO date. */
export function ofxDate(text: string | null): string | null {
  const m = /^(\d{4})(\d{2})(\d{2})/.exec(text ?? "");
  return m ? `${m[1]}-${m[2]}-${m[3]}` : null;
}

function decodeEntities(text: string): string {
  return text
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'");
}

/** Whether a file is OFX (or QBO, which is OFX under another name). */
export function isOfx(text: string): boolean {
  return /<OFX>/i.test(text) || /^\s*OFXHEADER:/i.test(text);
}

export function readOfxStatement(text: string): ParsedStatement {
  const findings: Finding[] = [];
  const raw: StatementLine[] = [];
  const blocks = text.split(/<STMTTRN>/i).slice(1);
  blocks.forEach((b, i) => {
    const block = b.split(/<\/STMTTRN>/i)[0] ?? b;
    const bookedOn = ofxDate(tagValue(block, "DTPOSTED"));
    const amountText = tagValue(block, "TRNAMT");
    const amount = amountText === null ? null : money(amountText);
    if (!bookedOn || amount === null) {
      findings.push({
        line: i + 1,
        message: "A transaction without a date or an amount was passed over.",
      });
      return;
    }
    if (amount === 0) return;
    const name = tagValue(block, "NAME");
    const memo = tagValue(block, "MEMO");
    const description = decodeEntities([name, memo].filter(Boolean).join(" ").trim());
    raw.push({
      line: i + 1,
      bookedOn,
      amountMinor: amount,
      description: description === "" ? "(no description)" : description,
      reference: tagValue(block, "CHECKNUM") ?? tagValue(block, "REFNUM"),
      fitid: tagValue(block, "FITID"),
      balanceMinor: null,
    });
  });
  const ledger = text.split(/<LEDGERBAL>/i)[1] ?? "";
  const closing = money(tagValue(ledger, "BALAMT") ?? undefined);
  const acct = tagValue(text, "ACCTID");
  const last4 = acct && /\d{4}$/.test(acct) ? acct.slice(-4) : null;
  // OFX lists transactions in any order: sort oldest first, keeping file order
  // within a day.
  const sorted = raw
    .map((l, i) => ({ l, i }))
    .sort((a, b) =>
      a.l.bookedOn < b.l.bookedOn ? -1 : a.l.bookedOn > b.l.bookedOn ? 1 : a.i - b.i,
    )
    .map((x) => x.l);
  const total = sorted.reduce((s, l) => s + l.amountMinor, 0);
  const opening = closing === null ? null : closing - total;
  const parsed = finish("ofx", "ofx", "OFX", sorted, opening, closing, findings, last4);
  return {
    ...parsed,
    startsOn: ofxDate(tagValue(text, "DTSTART")) ?? parsed.startsOn,
    endsOn: ofxDate(tagValue(text, "DTEND")) ?? parsed.endsOn,
  };
}

/** The lines as the door takes them. */
export function doorLines(lines: readonly StatementLine[]) {
  return lines.map((l) => ({
    booked_on: l.bookedOn,
    amount_minor: l.amountMinor,
    description: l.description,
    reference: l.reference,
    fitid: l.fitid,
    balance_minor: l.balanceMinor,
  }));
}

/** The file's SHA-256, hex: the same file imported twice is refused by it. */
export async function fileSha256(text: string): Promise<string> {
  const bytes = new TextEncoder().encode(text);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
