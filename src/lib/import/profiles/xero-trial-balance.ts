import { cell, emptyResult, type Column, type Profile } from "../types";
import { gbp, isTotalLabel, readMinorOrZero } from "./common";

/**
 * Xero: Trial Balance as at the cutover, exported and saved as CSV.
 *
 * The year-to-date columns, never the period ones (decision D3, option A:
 * profit and loss comes across year to date). The account is printed
 * "200 - Sales" or "Sales (200)". Each resolves through the chart the Xero
 * chart import loaded — by code, or by name where the line has no code — and
 * falls back to the printed code where no chart has been loaded.
 *
 * Accounts Receivable, Accounts Payable and Inventory are the three control
 * accounts the other domains load; they are listed as exclusions with the
 * Xero figure beside each, which is the first reconciliation the finance
 * person sees.
 */

const COLUMNS: Column[] = [
  { key: "account", label: "Account", aliases: ["Account Name", "Account Code"], required: true },
  {
    key: "ytd_debit",
    label: "YTD Debit",
    aliases: ["Debit - Year to date", "Debit Year to date", "YTD Dr"],
    required: true,
  },
  {
    key: "ytd_credit",
    label: "YTD Credit",
    aliases: ["Credit - Year to date", "Credit Year to date", "YTD Cr"],
    required: true,
  },
];

const CONTROL = [
  { pattern: /^(accounts receivable|trade debtors|debtors control)$/i, domain: "the sales ledger" },
  {
    pattern: /^(accounts payable|trade creditors|creditors control)$/i,
    domain: "the purchase ledger",
  },
  { pattern: /^(inventory|stock|stock on hand)$/i, domain: "the stock domain" },
];

/** "200 - Sales" → 200/Sales; "Sales (200)" → 200/Sales; "Sales" → null/Sales. */
export function splitAccount(text: string): { code: string | null; name: string } {
  const t = text.trim();
  let m = /^([A-Za-z0-9.]+)\s+-\s+(.+)$/.exec(t);
  if (m && /\d/.test(m[1] ?? "")) return { code: m[1] ?? null, name: (m[2] ?? "").trim() };
  m = /^(.+?)\s*\(([A-Za-z0-9.]+)\)$/.exec(t);
  if (m && /\d/.test(m[2] ?? "")) return { code: m[2] ?? null, name: (m[1] ?? "").trim() };
  return { code: null, name: t };
}

export const xeroTrialBalance: Profile = {
  id: "xero-trial-balance",
  source: "Xero",
  title: "Trial Balance",
  hint: "Reports → Trial Balance, as at the cutover date. Export to Excel and save as CSV.",
  target: { kind: "opening", domain: "nominal" },
  columns: COLUMNS,
  findsHeaderRow: true,
  transform(records, ctx) {
    const out = emptyResult();

    for (const r of records) {
      const accountText = cell(r, "account");
      if (accountText === "" || isTotalLabel(accountText)) continue;
      const debitText = cell(r, "ytd_debit");
      const creditText = cell(r, "ytd_credit");
      // A section heading ("Revenue", "Current Assets") carries no figures.
      if (debitText === "" && creditText === "") continue;

      const before = out.findings.length;
      const debit = readMinorOrZero(r, "ytd_debit", "YTD debit", out.findings);
      const credit = readMinorOrZero(r, "ytd_credit", "YTD credit", out.findings);
      if (debit === null || credit === null || out.findings.length > before) continue;
      if (debit === 0 && credit === 0) continue;

      const { code, name } = splitAccount(accountText);
      const resolved = ctx.account(code, name);
      const byName = CONTROL.find((c) => c.pattern.test(name));
      if (resolved?.control || (!resolved && byName)) {
        out.exclusions.push({
          line: r.line,
          label: accountText,
          reason: `control account, explained by ${byName?.domain ?? "its subledger domain"}; Xero shows debit ${gbp(debit)}, credit ${gbp(credit)}`,
          amountMinor: debit,
          quantity: null,
        });
        continue;
      }
      const account = resolved?.code ?? code;
      if (account === null) {
        out.findings.push({
          line: r.line,
          severity: "error",
          message: `${accountText} carries no account code and no loaded chart names it; load the Xero chart first, or map it there`,
        });
        continue;
      }

      const row: Record<string, string | number> = { account };
      if (debit !== 0) row["debit_minor"] = debit;
      if (credit !== 0) row["credit_minor"] = credit;
      out.rows.push(row);
      out.lines.push(r.line);
      out.stagedTotalMinor += debit;
    }
    return out;
  },
};
