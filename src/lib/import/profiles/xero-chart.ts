import { deriveCode } from "../values";
import {
  cell,
  emptyResult,
  type ChartAccount,
  type ChartAction,
  type ChartChoice,
  type Column,
  type Profile,
} from "../types";

/**
 * Xero: Accounting → Chart of accounts → Export.
 *
 * Each Xero account is mapped to an existing Clove account, marked as one of
 * the three control accounts the opening-balance domains load, or created.
 * An existing Clove account is never changed: a code that is taken is mapped
 * or refused, never merged. The defaults are a starting point — the same code
 * in both charts is mapped, Accounts Receivable, Accounts Payable and
 * Inventory are the control accounts, and the rest is created — and a person
 * changes any of them on the mapping step.
 */

const COLUMNS: Column[] = [
  { key: "code", label: "Code", aliases: ["Account Code", "*Code"], required: false },
  { key: "name", label: "Name", aliases: ["Account Name", "*Name"], required: true },
  { key: "type", label: "Type", aliases: ["Account Type", "*Type"], required: true },
];

const TYPES: Readonly<Record<string, string>> = {
  "current asset": "asset",
  "fixed asset": "asset",
  "non-current asset": "asset",
  inventory: "asset",
  prepayment: "asset",
  bank: "asset",
  "current liability": "liability",
  liability: "liability",
  "non-current liability": "liability",
  equity: "equity",
  revenue: "income",
  sales: "income",
  "other income": "income",
  "direct costs": "expense",
  expense: "expense",
  overhead: "expense",
  depreciation: "expense",
};

/** Which control account a Xero account is, if it is one of the three. */
export function controlKindOf(name: string, type: string): string | null {
  const n = name.trim().toLowerCase();
  if (/^(accounts receivable|trade debtors|debtors control)$/.test(n)) return "receivable";
  if (/^(accounts payable|trade creditors|creditors control)$/.test(n)) return "payable";
  if (type.trim().toLowerCase() === "inventory" || /^(inventory|stock)$/.test(n))
    return "inventory";
  return null;
}

/** The legacy key a row is known by: its code, or its name where it has none. */
export function chartKey(code: string, name: string): string {
  return code.trim() !== "" ? code.trim() : name.trim();
}

/** The choice a row starts with, before a person changes it. */
export function defaultChoice(
  code: string,
  name: string,
  type: string,
  accounts: readonly ChartAccount[],
  taken: Set<string>,
): ChartChoice {
  const kind = controlKindOf(name, type);
  if (kind) {
    const control = accounts.find((a) => a.control_kind === kind);
    return { action: "control", code: control?.code ?? "" };
  }
  const same = code.trim() !== "" ? accounts.find((a) => a.code === code.trim()) : undefined;
  if (same && same.is_postable && same.control_kind === null)
    return { action: "map", code: same.code };
  const wanted =
    code.trim() !== "" && !taken.has(code.trim()) ? code.trim() : deriveCode(name, taken);
  taken.add(wanted);
  return { action: "create", code: wanted };
}

const ACTIONS: readonly ChartAction[] = ["map", "control", "create"];

export const xeroChart: Profile = {
  id: "xero-chart",
  source: "Xero",
  title: "Chart of accounts",
  hint: "Accounting → Chart of accounts → Export, as CSV.",
  target: { kind: "master", objectType: "account" },
  columns: COLUMNS,
  findsHeaderRow: false,
  transform(records, ctx) {
    const out = emptyResult();
    const taken = new Set(ctx.accounts.map((a) => a.code));
    const seen = new Map<string, number>();

    for (const r of records) {
      const code = cell(r, "code");
      const name = cell(r, "name");
      const typeText = cell(r, "type");
      if (name === "") {
        out.findings.push({ line: r.line, severity: "error", message: "no account name" });
        continue;
      }
      const key = chartKey(code, name);
      const earlier = seen.get(key.toLowerCase());
      if (earlier !== undefined) {
        out.findings.push({
          line: r.line,
          severity: "error",
          message: `${key} is also on line ${earlier}`,
        });
        continue;
      }
      seen.set(key.toLowerCase(), r.line);

      const accountType = TYPES[typeText.toLowerCase()];
      const choice =
        ctx.chartChoices[key] ?? defaultChoice(code, name, typeText, ctx.accounts, taken);
      out.chart.push({ line: r.line, key, name, type: typeText, choice });
      if (!ACTIONS.includes(choice.action) || choice.code.trim() === "") {
        out.findings.push({
          line: r.line,
          severity: "error",
          message: `${key} ${name}: choose a Clove account to ${choice.action === "control" ? "mark as its control account" : "map to"}`,
        });
        continue;
      }
      if (choice.action === "create" && accountType === undefined) {
        out.findings.push({
          line: r.line,
          severity: "error",
          message: `${typeText || "a blank type"} is not a Xero account type Clove can create; map this account instead`,
        });
        continue;
      }

      const row: Record<string, string> = {
        source: "xero",
        legacy_name: name,
        action: choice.action,
        code: choice.code.trim(),
      };
      if (code !== "") row["legacy_code"] = code;
      if (choice.action === "create") {
        row["name"] = name;
        row["account_type"] = accountType ?? "";
      }
      out.rows.push(row);
      out.lines.push(r.line);
    }

    const created = out.rows.filter((r) => r["action"] === "create").length;
    if (created > 0) {
      out.findings.push({
        line: null,
        severity: "info",
        message: `${created} account${created === 1 ? "" : "s"} will be created in the Clove chart; every other line maps to an account that exists, which is not changed.`,
      });
    }
    return out;
  },
};
