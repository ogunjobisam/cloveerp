import { cell, emptyResult, type Column, type Profile } from "../types";
import { gbp, isTotalLabel, readMinorOrZero } from "./common";

/**
 * Xero: Trial Balance as at the cutover, exported and saved as CSV.
 *
 * The year-to-date columns, never the period ones (decision D3, option A:
 * profit and loss comes across year to date). The account is printed
 * "200 - Sales" or "Sales (200)". Each resolves through the chart the Xero
 * chart import loaded — by code, or by name where the line has no code. Once a
 * chart is loaded, a line it does not name is refused; the printed code is
 * used as it stands only where no chart has been loaded at all.
 *
 * Accounts Receivable, Accounts Payable and Inventory are the three control
 * accounts the other domains load; they are listed as exclusions with the
 * Xero figure beside each, which is the first reconciliation the finance
 * person sees.
 *
 * Opening stock loads at Unleashed's value, which need not be Xero's
 * Inventory figure. Decision D7: the difference is written off to stock
 * adjustment, as one more line of the trial balance, so migration clearing
 * still comes to zero. A line the report does not print changes the debit
 * column, so it is listed with the exclusions, as a negative one, and the
 * control total explains it.
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

    // D7: Xero's Inventory against the stock loaded.
    const stockAdjustment = (xeroMinor: number, line: number) => {
      if (!ctx.stock) {
        out.findings.push({
          line,
          severity: "warning",
          message:
            "no opening stock is loaded yet, so a difference between it and Xero's Inventory cannot be written off; load the Unleashed stock first",
        });
        return;
      }
      const difference = xeroMinor - ctx.stock.valueMinor;
      if (difference === 0) return;
      const row: Record<string, string | number> = { account: ctx.stock.adjustmentAccount };
      if (difference > 0) row["debit_minor"] = difference;
      else row["credit_minor"] = -difference;
      out.rows.push(row);
      out.lines.push(line);
      if (difference > 0) out.stagedTotalMinor += difference;
      out.exclusions.push({
        line,
        label: `Stock adjustment ${ctx.stock.adjustmentAccount}`,
        reason: `Xero's Inventory is ${gbp(xeroMinor)} and the stock loaded is ${gbp(ctx.stock.valueMinor)}; the ${gbp(Math.abs(difference))} difference is written off to stock adjustment (D7), a line the report does not print`,
        amountMinor: difference > 0 ? -difference : 0,
        quantity: null,
      });
      out.findings.push({
        line,
        severity: "warning",
        message: `${gbp(Math.abs(difference))} between Xero's Inventory and the stock loaded goes to stock adjustment ${ctx.stock.adjustmentAccount}`,
      });
    };

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
        if (byName?.domain === "the stock domain") stockAdjustment(debit - credit, r.line);
        out.exclusions.push({
          line: r.line,
          label: accountText,
          reason: `control account, explained by ${byName?.domain ?? "its subledger domain"}; Xero shows debit ${gbp(debit)}, credit ${gbp(credit)}`,
          amountMinor: debit,
          quantity: null,
        });
        continue;
      }
      if (!resolved && ctx.chartLoaded) {
        out.findings.push({
          line: r.line,
          severity: "error",
          message: `${accountText} is not in the loaded Xero chart; load or map it there, so its balance does not land on an unrelated account that shares the code`,
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
