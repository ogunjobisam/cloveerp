import { parseMinor, type MinorParse } from "../values";
import { cell, type Finding, type MappedRecord } from "../types";

/** Why an amount was refused, in the words a finding uses. */
export function minorProblem(label: string, text: string, parsed: MinorParse): string | null {
  if (parsed.ok) return null;
  switch (parsed.reason) {
    case "blank":
      return `${label} is blank`;
    case "not_a_number":
      return `${label} is not an amount: ${text}`;
    case "too_many_places":
      return `${label} has more than two decimal places: ${text}`;
    case "too_large":
      return `${label} is too large: ${text}`;
  }
}

/** An amount in minor units, or a finding on the line saying why not. */
export function readMinor(
  record: MappedRecord,
  key: string,
  label: string,
  findings: Finding[],
): number | null {
  const text = cell(record, key);
  const parsed = parseMinor(text);
  if (parsed.ok) return parsed.minor;
  const problem = minorProblem(label, text, parsed);
  if (problem) findings.push({ line: record.line, severity: "error", message: problem });
  return null;
}

/** A blank amount is nought here: a report leaves the empty side of a line blank. */
export function readMinorOrZero(
  record: MappedRecord,
  key: string,
  label: string,
  findings: Finding[],
): number | null {
  return cell(record, key) === "" ? 0 : readMinor(record, key, label, findings);
}

/**
 * The columns a file carried that no door can take yet. Named once each, with
 * the change that brings them, so nothing reads as silently dropped.
 */
export function deferredColumns(
  records: readonly MappedRecord[],
  columns: readonly { key: string; label: string }[],
  arrives: string,
): string[] {
  return columns
    .filter((c) => records.some((r) => cell(r, c.key) !== ""))
    .map((c) => `${c.label} — ${arrives}`);
}

export function isTruthy(text: string): boolean {
  return /^(y|yes|true|1|t)$/i.test(text.trim());
}

/** A subtotal or grand-total line in a printed report. */
export function isTotalLabel(text: string): boolean {
  return /^(grand\s+)?total\b/i.test(text.trim());
}

/** Sterling as a finding prints it: v1 imports load GBP only. */
export function gbp(minor: number | bigint): string {
  const v = BigInt(minor);
  const neg = v < 0n;
  const abs = (neg ? -v : v).toString().padStart(3, "0");
  const whole = abs.slice(0, -2).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  return `${neg ? "-" : ""}£${whole}.${abs.slice(-2)}`;
}
