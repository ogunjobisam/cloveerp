import { parseUkDate } from "../values";
import { cell, emptyResult, type Column, type Profile, type ProfileResult } from "../types";
import { isTotalLabel, readMinor } from "./common";

/**
 * Xero: Aged Receivables Detail / Aged Payables Detail, as at the cutover,
 * exported and saved as CSV.
 *
 * The report groups invoices under a line naming the contact, and ends each
 * group and the report with a "Total …" line. A contact column is used where
 * the export has one; otherwise the last group heading names the contact.
 * Heading, subtotal and grand-total lines are skipped. Credit notes and
 * overpayments stay negative. Lines in another currency are held back and
 * listed: v1 loads sterling.
 */

const COLUMNS: Column[] = [
  {
    key: "contact",
    label: "Contact",
    aliases: ["Contact Name", "Customer", "Supplier"],
    required: false,
  },
  {
    key: "document_date",
    label: "Invoice Date",
    aliases: ["Date", "Bill Date", "Transaction Date"],
    required: true,
  },
  {
    key: "reference",
    label: "Invoice Number",
    aliases: ["Number", "Reference", "Invoice Reference", "Bill Number", "Invoice #"],
    required: true,
  },
  { key: "due_date", label: "Due Date", aliases: [], required: false },
  {
    key: "amount",
    label: "Total",
    aliases: ["Due", "Amount Due", "Outstanding", "Balance", "Balance Due", "Total Due"],
    required: true,
  },
  { key: "currency", label: "Currency", aliases: ["Currency Code"], required: false },
  { key: "type", label: "Type", aliases: ["Transaction Type"], required: false },
];

function agedProfile(
  id: string,
  title: string,
  hint: string,
  domain: "sales_ledger" | "purchase_ledger",
): Profile {
  return {
    id,
    source: "Xero",
    title,
    hint,
    target: { kind: "opening", domain },
    columns: COLUMNS,
    findsHeaderRow: true,
    transform(records, ctx) {
      const out: ProfileResult = emptyResult();
      const seen = new Map<string, number>();
      let group = "";

      for (const r of records) {
        const reference = cell(r, "reference");
        const amountText = cell(r, "amount");
        const first =
          Object.values(r.values)
            .find((v) => v.trim() !== "")
            ?.trim() ?? "";

        if (isTotalLabel(first) || isTotalLabel(cell(r, "contact"))) continue;
        if (reference === "" && amountText === "") {
          // A group heading: the contact the lines below belong to.
          if (first !== "") group = first;
          continue;
        }
        if (reference === "") {
          out.findings.push({
            line: r.line,
            severity: "info",
            message: `skipped: an amount with no invoice number (${amountText}), read as a subtotal`,
          });
          continue;
        }

        const contact = cell(r, "contact") || group;
        if (contact === "") {
          out.findings.push({
            line: r.line,
            severity: "error",
            message: "no contact for this line",
          });
          continue;
        }

        const lineFindings = out.findings.length;
        let amount = readMinor(r, "amount", "amount", out.findings);
        if (amount === null) continue;
        if (/credit|overpay|prepay/i.test(cell(r, "type")) && amount > 0) amount = -amount;

        const currency = cell(r, "currency").toUpperCase();
        if (currency !== "" && currency !== "GBP") {
          out.exclusions.push({
            line: r.line,
            label: `${contact} ${reference}`,
            reason: `in ${currency}; foreign-currency items load in v1.1`,
            amountMinor: amount,
            quantity: null,
          });
          continue;
        }
        if (amount === 0) {
          out.findings.push({
            line: r.line,
            severity: "info",
            message: `skipped: ${reference} has nothing outstanding`,
          });
          continue;
        }

        const row: Record<string, string | number> = {
          party: "",
          reference,
          amount_minor: amount,
        };
        for (const key of ["document_date", "due_date"] as const) {
          const text = cell(r, key);
          if (text === "") continue;
          const iso = parseUkDate(text);
          if (iso) row[key] = iso;
          else {
            out.findings.push({
              line: r.line,
              severity: "error",
              message: `${key === "due_date" ? "due date" : "invoice date"} is not a date: ${text}`,
            });
          }
        }
        if (out.findings.length > lineFindings) continue;

        const party = ctx.partyCode(contact);
        row["party"] = party.code;
        if (!party.known) {
          out.findings.push({
            line: r.line,
            severity: "warning",
            message: `${contact} is not in a contacts file staged here; code ${party.code} derived from the name`,
          });
        }

        const key = `${party.code}\u0000${reference}`;
        const earlier = seen.get(key);
        if (earlier !== undefined) {
          out.findings.push({
            line: r.line,
            severity: "warning",
            message: `${reference} for ${contact} is also on line ${earlier}`,
          });
        }
        seen.set(key, r.line);

        out.rows.push(row);
        out.lines.push(r.line);
        out.stagedTotalMinor += amount;
      }
      return out;
    },
  };
}

export const xeroAgedReceivables = agedProfile(
  "xero-aged-receivables",
  "Aged Receivables Detail",
  "Reports → Aged Receivables Detail, as at the cutover date. Export to Excel and save as CSV.",
  "sales_ledger",
);

export const xeroAgedPayables = agedProfile(
  "xero-aged-payables",
  "Aged Payables Detail",
  "Reports → Aged Payables Detail, as at the cutover date. Export to Excel and save as CSV.",
  "purchase_ledger",
);
