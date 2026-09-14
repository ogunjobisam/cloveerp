import { toMinor } from "./money";

/**
 * Manual journals, as the desk reads them.
 *
 * A journal typed by hand is raised and submitted by one person and approved
 * and posted by another (supabase/migrations/20260914071000_finance_can_journal_and_close.sql).
 * The database refuses an unbalanced journal, a closed period and an account it
 * may not post to; this file holds the shapes `erp_journals` returns, the line
 * editor's arithmetic, and the arguments `erp_raise_journal` takes. Pure: no
 * React, no Supabase client.
 */

export type JournalState = "draft" | "returned" | "submitted" | "posted" | "reversed";

/** The states the screen filters by, in the order a person works through them. */
export const JOURNAL_STATES: readonly { value: JournalState; label: string }[] = [
  { value: "submitted", label: "Waiting for approval" },
  { value: "returned", label: "Sent back" },
  { value: "draft", label: "Draft" },
  { value: "posted", label: "Posted" },
  { value: "reversed", label: "Reversed" },
];

/** The analysis a line may carry, by the dimension code the statements read. */
export const COST_CENTRE = "COST_CENTRE";

export type JournalLine = {
  line_no: number;
  account_id: string;
  account_code: string;
  account_name: string;
  debit_minor: number;
  credit_minor: number;
  description: string | null;
  dimensions: Record<string, unknown> | null;
};

export type Journal = {
  journal_id: string;
  journal_number: string | null;
  reference: string | null;
  narrative: string | null;
  entity_id: string;
  company: string | null;
  ledger: string | null;
  currency: string;
  posting_date: string;
  period: string | null;
  state: JournalState;
  debit_minor: number;
  credit_minor: number;
  line_count: number;
  raised_by: string | null;
  submitted_by: string | null;
  submitted_at: string | null;
  returned_by: string | null;
  returned_at: string | null;
  return_note: string | null;
  posted_by: string | null;
  posted_at: string | null;
  reverses_journal_id: string | null;
  reverses_number: string | null;
  reversal: { journal_id: string; journal_number: string | null; state: JournalState } | null;
  /** Raised on the Journals screen, rather than loaded as opening balances. */
  raised_here: boolean;
  you_raised: boolean;
  /** Waiting for approval, and not refused to this person as its maker. Permission is separate. */
  you_may_approve: boolean;
  lines: JournalLine[];
};

const STATES = new Set<string>(JOURNAL_STATES.map((s) => s.value));

/** What `erp_journals` returned, keeping only what reads as a journal. */
export function readJournals(data: unknown): Journal[] {
  if (!Array.isArray(data)) return [];
  return data.filter(
    (row): row is Journal =>
      typeof row === "object" &&
      row !== null &&
      typeof (row as Record<string, unknown>)["journal_id"] === "string" &&
      STATES.has(String((row as Record<string, unknown>)["state"])),
  );
}

/** The words for a state. */
export function stateLabel(state: JournalState): string {
  return JOURNAL_STATES.find((s) => s.value === state)?.label ?? state;
}

/** How loudly a state is drawn: waiting on somebody, sent back, or settled. */
export function stateTone(state: JournalState): "ok" | "warn" | "bad" | "muted" {
  if (state === "posted") return "ok";
  if (state === "submitted") return "warn";
  if (state === "returned") return "bad";
  return "muted";
}

/** How a journal is named in a sentence: its number once posted, else its reference or date. */
export function journalName(
  journal: Pick<Journal, "journal_number" | "reference" | "posting_date">,
): string {
  return journal.journal_number ?? journal.reference ?? journal.posting_date;
}

/** One line as the editor holds it: what was typed. */
export type DraftLine = {
  account_id: string;
  description: string;
  debit: string;
  credit: string;
  cost_centre: string;
};

export function emptyLine(): DraftLine {
  return { account_id: "", description: "", debit: "", credit: "", cost_centre: "" };
}

/** A line nobody has touched, which the editor leaves out rather than refuses. */
export function isBlankLine(line: DraftLine): boolean {
  return (
    line.account_id.trim() === "" &&
    line.description.trim() === "" &&
    line.debit.trim() === "" &&
    line.credit.trim() === "" &&
    line.cost_centre.trim() === ""
  );
}

/** What stops a line being sent, first thing first. */
export type LineProblem = "unreadable" | "negative" | "both" | "amount" | "account";

export function lineAmounts(
  line: DraftLine,
  minorUnits: number,
): { debit_minor: number; credit_minor: number; problem: LineProblem | null } {
  // Blank is nothing on that side. Anything typed goes through toMinor, so
  // 1.005 is a penny and a stray letter is not a zero.
  const debit = line.debit.trim() === "" ? 0 : toMinor(line.debit, minorUnits);
  const credit = line.credit.trim() === "" ? 0 : toMinor(line.credit, minorUnits);
  if (debit === null || credit === null)
    return { debit_minor: 0, credit_minor: 0, problem: "unreadable" };
  if (debit < 0 || credit < 0) return { debit_minor: 0, credit_minor: 0, problem: "negative" };
  if (debit > 0 && credit > 0) return { debit_minor: debit, credit_minor: credit, problem: "both" };
  if (debit === 0 && credit === 0) return { debit_minor: 0, credit_minor: 0, problem: "amount" };
  if (line.account_id.trim() === "")
    return { debit_minor: debit, credit_minor: credit, problem: "account" };
  return { debit_minor: debit, credit_minor: credit, problem: null };
}

/** What a person is told about a line that cannot be sent. */
export const LINE_PROBLEM_TEXT: Record<LineProblem, string> = {
  unreadable: "That amount cannot be read as money.",
  negative: "An amount is never negative: put it on the other side instead.",
  both: "Put the amount in the debit or the credit, not both.",
  amount: "Give the line an amount, debit or credit.",
  account: "Choose the account.",
};

export type JournalTotals = {
  debit_minor: number;
  credit_minor: number;
  /** Debits less credits. */
  difference_minor: number;
  /** Lines with something on them. */
  lines: number;
  /** Of those, the ones that cannot be sent. */
  problems: number;
  /** Every line with something on it can be sent. */
  complete: boolean;
  /** Complete, two lines or more, and the debits equal the credits. */
  balanced: boolean;
};

/** The running totals under the editor, and whether Submit may be pressed. */
export function journalTotals(lines: DraftLine[], minorUnits: number): JournalTotals {
  let debit = 0;
  let credit = 0;
  let filled = 0;
  let problems = 0;
  for (const line of lines) {
    if (isBlankLine(line)) continue;
    filled += 1;
    const amounts = lineAmounts(line, minorUnits);
    if (amounts.problem !== null && amounts.problem !== "account") {
      problems += 1;
      continue;
    }
    if (amounts.problem === "account") problems += 1;
    debit += amounts.debit_minor;
    credit += amounts.credit_minor;
  }
  const complete = filled > 0 && problems === 0;
  return {
    debit_minor: debit,
    credit_minor: credit,
    difference_minor: debit - credit,
    lines: filled,
    problems,
    complete,
    balanced: complete && filled >= 2 && debit === credit && debit > 0,
  };
}

/** One line as `erp_raise_journal` takes it. */
export type JournalLineArg = {
  account_id: string;
  debit_minor?: number;
  credit_minor?: number;
  description?: string;
  dimensions?: Record<string, string>;
};

/** The lines as the door takes them: blank lines left out, amounts in minor units. */
export function journalLinesArg(lines: DraftLine[], minorUnits: number): JournalLineArg[] {
  const out: JournalLineArg[] = [];
  for (const line of lines) {
    if (isBlankLine(line)) continue;
    const amounts = lineAmounts(line, minorUnits);
    const arg: JournalLineArg = { account_id: line.account_id.trim() };
    if (amounts.debit_minor > 0) arg.debit_minor = amounts.debit_minor;
    if (amounts.credit_minor > 0) arg.credit_minor = amounts.credit_minor;
    if (line.description.trim() !== "") arg.description = line.description.trim();
    if (line.cost_centre.trim() !== "") arg.dimensions = { [COST_CENTRE]: line.cost_centre.trim() };
    out.push(arg);
  }
  return out;
}

/** Minor units back to what a person would have typed; nothing for zero. */
export function minorToInput(minor: number, minorUnits: number): string {
  if (!minor) return "";
  return (minor / 10 ** minorUnits).toFixed(minorUnits);
}

/** A saved journal's lines, back in the editor to be changed. */
export function draftLinesOf(journal: Pick<Journal, "lines">, minorUnits: number): DraftLine[] {
  return journal.lines.map((l) => {
    const centre = l.dimensions?.[COST_CENTRE];
    return {
      account_id: l.account_id,
      description: l.description ?? "",
      debit: minorToInput(l.debit_minor, minorUnits),
      credit: minorToInput(l.credit_minor, minorUnits),
      cost_centre: typeof centre === "string" ? centre : "",
    };
  });
}
