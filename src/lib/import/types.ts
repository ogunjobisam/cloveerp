/**
 * What a legacy export becomes before any door sees it.
 *
 * A file is turned into rows the existing doors already accept —
 * erp_stage_import for master data, erp_stage_opening_balances for the four
 * migration domains — and nothing else. Everything the file said that those
 * doors cannot take yet is reported, never dropped silently; everything left
 * out of a batch is an exclusion with its value beside it, so the control
 * total a person types from the printed report can be reconciled line by line.
 */

export type Severity = "error" | "warning" | "info";

/** One thing a person should read before staging. `line` is the file's line. */
export type Finding = { line: number | null; severity: Severity; message: string };

/**
 * A line the printed report counts and the batch does not: a foreign-currency
 * invoice, a control account, a negative stock line. The control figure is the
 * printed total less these, and the list is the evidence for it.
 */
export type Exclusion = {
  line: number;
  label: string;
  reason: string;
  /** Minor units, as the report printed the line. Null where it has no value. */
  amountMinor: number | null;
  /** Units, for stock. */
  quantity: string | null;
};

export type StageRow = Record<string, string | number>;

export type MasterTarget = { kind: "master"; objectType: "party" | "item" };
export type OpeningTarget = {
  kind: "opening";
  domain: "stock" | "sales_ledger" | "purchase_ledger" | "nominal";
};
export type Target = MasterTarget | OpeningTarget;

export type ProfileResult = {
  rows: StageRow[];
  /** The file line each staged row came from, index for index. */
  lines: number[];
  findings: Finding[];
  exclusions: Exclusion[];
  /** Columns read and checked that the door cannot take until a later change. */
  deferred: string[];
  /** Legacy name → Clove code, for the ledgers that name parties by name. */
  partyKeys: Record<string, string>;
  /** Sum of the staged rows, in minor units: what the loader will total. */
  stagedTotalMinor: number;
  /** Sum of staged quantities, stock only. */
  stagedQuantity: string | null;
};

/** A row of the file, after its headers were matched to a profile's columns. */
export type MappedRecord = { line: number; values: Readonly<Record<string, string>> };

export type ProfileContext = {
  /**
   * The Clove code for a party the legacy report names by name. PR 1 reads a
   * map kept in the browser from the contacts file; the persisted crosswalk
   * replaces it without the profiles changing.
   */
  partyCode: (name: string) => { code: string; known: boolean };
  /** Stock: the location a row takes when the file names no bin. */
  defaultLocation: string;
};

export type Column = {
  key: string;
  label: string;
  /** Headings this column is known by, compared after normalising. */
  aliases: readonly string[];
  required: boolean;
};

export type Profile = {
  id: string;
  source: "Xero" | "Unleashed";
  title: string;
  /** Where in the legacy system the file comes from. */
  hint: string;
  target: Target;
  columns: readonly Column[];
  /** Report files carry title rows above the heading row. */
  findsHeaderRow: boolean;
  transform: (records: readonly MappedRecord[], ctx: ProfileContext) => ProfileResult;
};

export function emptyResult(): ProfileResult {
  return {
    rows: [],
    lines: [],
    findings: [],
    exclusions: [],
    deferred: [],
    partyKeys: {},
    stagedTotalMinor: 0,
    stagedQuantity: null,
  };
}

/** The trimmed value of a mapped column, or "" where the file had none. */
export function cell(record: MappedRecord, key: string): string {
  return (record.values[key] ?? "").trim();
}
