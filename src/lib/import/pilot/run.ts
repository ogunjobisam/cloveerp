import { accountResolver, partyKeysFrom, type CrosswalkEntry } from "../crosswalk";
import { controlFigure, controlQuantity, partyResolver, readFile } from "../pipeline";
import { unleashedProducts } from "../profiles/unleashed-products";
import { unleashedCustomers, unleashedSuppliers } from "../profiles/unleashed-parties";
import { unleashedStock } from "../profiles/unleashed-stock";
import { xeroAgedPayables, xeroAgedReceivables } from "../profiles/xero-aged";
import { xeroChart } from "../profiles/xero-chart";
import { xeroContacts } from "../profiles/xero-contacts";
import { xeroTrialBalance } from "../profiles/xero-trial-balance";
import type { ChartAccount, Json, Profile, ProfileContext, ProfileResult } from "../types";

/**
 * The Xero + Unleashed pilot, start to finish, through the doors the import
 * screens use and in the order the runbook gives: the chart, the contacts,
 * the Unleashed customers and suppliers, the products, then the four opening
 * domains — stock, receivables, payables and the trial balance.
 *
 * Every file goes through the same profile and pipeline the screen runs, with
 * the context the screen would build: each step reads the crosswalk the steps
 * before it loaded, so a supplier named on a product is found the way a
 * person's browser would find it. The printed totals are typed here as a
 * person types them from the printed reports (decision D31); they are never
 * computed from the files.
 *
 * `door` is the only way out. In CI it is psql as the pilot's administrator
 * (supabase/ci/pilot.ts); in the unit test it is a fake that keeps the
 * crosswalk. Anything that would stop a person on the screen — a refused line,
 * a staged total that does not meet the control, a batch validation refuses —
 * stops the pilot, saying which file and why.
 */

export type Door = (fn: string, args?: Readonly<Record<string, Json>>) => Promise<Json>;

export type PilotFile =
  | "xero-chart"
  | "xero-contacts"
  | "unleashed-customers"
  | "unleashed-suppliers"
  | "unleashed-products"
  | "unleashed-stock"
  | "xero-aged-receivables"
  | "xero-aged-payables"
  | "xero-trial-balance";

export const PILOT_FILES: readonly PilotFile[] = [
  "xero-chart",
  "xero-contacts",
  "unleashed-customers",
  "unleashed-suppliers",
  "unleashed-products",
  "unleashed-stock",
  "xero-aged-receivables",
  "xero-aged-payables",
  "xero-trial-balance",
];

/** What the printed reports say at the foot, as a person types it. */
export const PRINTED = {
  stock: { minor: 416720, quantity: "70172" },
  receivables: { minor: 422550 },
  payables: { minor: 193925 },
  trialBalance: { minor: 6492550 },
} as const;

/** The choices a person makes on the screen for this organisation. */
export const CHOICES = {
  // Greenway is a Xero supplier Unleashed never lists, so the role step names it.
  partyRoles: { "Greenway Office Services": ["supplier"] },
  weightUnit: "kg",
  reorderSite: "MAIN",
  defaultLocation: "DEFAULT",
} as const;

export type PilotStep = {
  file: PilotFile;
  batchId: string;
  rows: number;
  /** Opening batches: the control total staged, and what the rows come to. */
  controlMinor: number | null;
  stagedMinor: number | null;
  warnings: string[];
  activated: number | null;
};

export class PilotError extends Error {}

const NO_ENTRIES: CrosswalkEntry[] = [];

function context(over: Partial<ProfileContext>): ProfileContext {
  return {
    partyCode: partyResolver({}),
    account: () => null,
    chartLoaded: false,
    defaultLocation: "",
    accounts: [],
    chartChoices: {},
    partyRoles: {},
    defaultPartyRole: "none",
    termsFromXero: false,
    weightUnit: CHOICES.weightUnit,
    reorderSite: "",
    stock: null,
    ...over,
  };
}

/** A file read as the screen reads it; refused lines stop the pilot. */
export function readPilotFile(
  file: PilotFile,
  text: string,
  profile: Profile,
  ctx: ProfileContext,
): ProfileResult {
  const read = readFile(text, profile, ctx);
  if (read.missing.length > 0) {
    throw new PilotError(
      `${file}: no column for ${read.missing.map((c) => c.label).join(", ")} among ${read.headings.join(", ")}`,
    );
  }
  const result = read.result;
  if (!result) throw new PilotError(`${file}: the file could not be read`);
  const errors = [...read.findings, ...result.findings].filter((f) => f.severity === "error");
  if (errors.length > 0) {
    throw new PilotError(
      `${file}: ${errors.map((f) => `line ${f.line ?? "-"}: ${f.message}`).join("; ")}`,
    );
  }
  if (result.rows.length === 0) throw new PilotError(`${file}: nothing to stage`);
  return result;
}

const warningsOf = (r: ProfileResult) =>
  r.findings.filter((f) => f.severity === "warning").map((f) => f.message);

function asString(value: Json, what: string): string {
  if (typeof value === "string") return value;
  if (value && typeof value === "object" && !Array.isArray(value)) {
    const id = value["batch_id"];
    if (typeof id === "string") return id;
  }
  throw new PilotError(`${what} answered ${JSON.stringify(value)}, not a batch`);
}

function asNumber(value: Json, key: string | null, what: string): number {
  const v =
    key !== null && value && typeof value === "object" && !Array.isArray(value)
      ? value[key]
      : value;
  if (typeof v === "number") return v;
  throw new PilotError(`${what} answered ${JSON.stringify(value)}, not a count`);
}

async function crosswalk(door: Door, source: string, objectType: string) {
  const answer = await door("erp_import_crosswalk", {
    p_source_system: source,
    p_object_type: objectType,
  });
  return Array.isArray(answer) ? (answer as unknown as CrosswalkEntry[]) : NO_ENTRIES;
}

/** Validate, preview and load a staged batch, refusing one validation refuses. */
async function validateAndLoad(door: Door, file: PilotFile, batchId: string): Promise<void> {
  const errors = asNumber(
    await door("erp_validate_import", { p_batch_id: batchId }),
    "errors",
    `${file}: validation`,
  );
  if (errors > 0) {
    throw new PilotError(
      `${file}: validation refused ${errors} row(s) of batch ${batchId}; the profile and the door disagree`,
    );
  }
  await door("erp_preview_import", { p_batch_id: batchId });
  await door("erp_load_import", { p_batch_id: batchId });
}

async function master(
  door: Door,
  file: PilotFile,
  result: ProfileResult,
  objectType: string,
  activate: boolean,
): Promise<PilotStep> {
  const batchId = asString(
    await door("erp_stage_import", {
      p_object_type: objectType,
      p_rows: result.rows,
      p_code: `PILOT-${file.toUpperCase()}`,
      p_source: `${file}.csv`,
    }),
    `${file}: staging`,
  );
  await validateAndLoad(door, file, batchId);
  const activated = activate
    ? asNumber(
        await door("erp_activate_import_batch", { p_batch_id: batchId }),
        "activated",
        `${file}: activation`,
      )
    : null;
  return {
    file,
    batchId,
    rows: result.rows.length,
    controlMinor: null,
    stagedMinor: null,
    warnings: warningsOf(result),
    activated,
  };
}

async function opening(
  door: Door,
  file: PilotFile,
  result: ProfileResult,
  domain: string,
  asAt: string,
  printedMinor: number,
  printedQuantity: string | null,
): Promise<PilotStep> {
  const control = controlFigure(printedMinor, result.exclusions);
  const quantity =
    printedQuantity === null ? null : controlQuantity(printedQuantity, result.exclusions);
  // The screen shows this before it lets anyone stage; a person would stop here.
  if (control !== result.stagedTotalMinor) {
    throw new PilotError(
      `${file}: the rows come to ${result.stagedTotalMinor} and the printed total less what is held back is ${control}`,
    );
  }
  if (quantity !== null && quantity !== result.stagedQuantity) {
    throw new PilotError(
      `${file}: the rows hold ${result.stagedQuantity ?? "nothing"} and the printed quantity less what is held back is ${quantity}`,
    );
  }
  const batchId = asString(
    await door("erp_stage_opening_balances", {
      p_domain_code: domain,
      p_as_at: asAt,
      p_rows: result.rows,
      p_control_total_minor: control,
      p_control_quantity: quantity === null ? null : Number(quantity),
      p_code: `PILOT-${file.toUpperCase()}`,
    }),
    `${file}: staging`,
  );
  await door("erp_record_control_evidence", {
    p_batch_id: batchId,
    p_printed_minor: printedMinor,
    p_printed_quantity: printedQuantity === null ? null : Number(printedQuantity),
    p_exclusions: result.exclusions.map((e) => ({
      line: e.line,
      label: e.label,
      reason: e.reason,
      amount_minor: e.amountMinor,
      quantity: e.quantity,
    })),
  });
  await validateAndLoad(door, file, batchId);
  return {
    file,
    batchId,
    rows: result.rows.length,
    controlMinor: control,
    stagedMinor: result.stagedTotalMinor,
    warnings: warningsOf(result),
    activated: null,
  };
}

type StockDomain = {
  domain_code: string;
  loaded_total_minor: number | null;
  adjustment_account: string | null;
};

/** The pilot, file by file. Each step reads back what the steps before it loaded. */
export async function runPilot(
  door: Door,
  files: Readonly<Record<PilotFile, string>>,
  asAt: string,
): Promise<PilotStep[]> {
  const steps: PilotStep[] = [];

  // 2. The chart, onto the Clove chart the organisation was configured with.
  const accounts = (await door("erp_accounts", {
    p_postable_only: false,
  })) as unknown as ChartAccount[];
  const chart = readPilotFile(
    "xero-chart",
    files["xero-chart"],
    xeroChart,
    context({ accounts: Array.isArray(accounts) ? accounts : [] }),
  );
  steps.push(await master(door, "xero-chart", chart, "account", false));

  // 3. Parties: Xero's contacts, then Unleashed's customers and suppliers,
  //    which find the party Xero loaded by its name.
  const contacts = readPilotFile(
    "xero-contacts",
    files["xero-contacts"],
    xeroContacts,
    context({ partyRoles: CHOICES.partyRoles }),
  );
  steps.push(await master(door, "xero-contacts", contacts, "party_profile", true));

  for (const [file, profile] of [
    ["unleashed-customers", unleashedCustomers],
    ["unleashed-suppliers", unleashedSuppliers],
  ] as const) {
    const xero = await crosswalk(door, "xero", "party");
    const result = readPilotFile(
      file,
      files[file],
      profile,
      context({ partyCode: partyResolver(partyKeysFrom(xero)) }),
    );
    steps.push(await master(door, file, result, "party_profile", true));
  }

  // 4–5. Products and their extras, naming suppliers by either system's key.
  const parties = [
    ...(await crosswalk(door, "xero", "party")),
    ...(await crosswalk(door, "unleashed", "party")),
  ];
  const products = readPilotFile(
    "unleashed-products",
    files["unleashed-products"],
    unleashedProducts,
    context({ partyCode: partyResolver(partyKeysFrom(parties)), reorderSite: CHOICES.reorderSite }),
  );
  steps.push(await master(door, "unleashed-products", products, "item_profile", true));

  // 6. Opening stock, at the value Unleashed states.
  const stock = readPilotFile(
    "unleashed-stock",
    files["unleashed-stock"],
    unleashedStock,
    context({ defaultLocation: CHOICES.defaultLocation }),
  );
  steps.push(
    await opening(
      door,
      "unleashed-stock",
      stock,
      "stock",
      asAt,
      PRINTED.stock.minor,
      PRINTED.stock.quantity,
    ),
  );

  // 7. The ledgers, naming parties by their Xero names.
  const named = partyResolver(partyKeysFrom(await crosswalk(door, "xero", "party")));
  for (const [file, profile, domain, printed] of [
    ["xero-aged-receivables", xeroAgedReceivables, "sales_ledger", PRINTED.receivables.minor],
    ["xero-aged-payables", xeroAgedPayables, "purchase_ledger", PRINTED.payables.minor],
  ] as const) {
    const result = readPilotFile(file, files[file], profile, context({ partyCode: named }));
    steps.push(await opening(door, file, result, domain, asAt, printed, null));
  }

  // 8. The trial balance, through the loaded chart, writing off the stock
  //    difference to stock adjustment (D7).
  const accountMap = await crosswalk(door, "xero", "account");
  const domains = await door("erp_migration_domains");
  const stockDomain = Array.isArray(domains)
    ? (domains as unknown as StockDomain[]).find((d) => d.domain_code === "stock")
    : undefined;
  const tb = readPilotFile(
    "xero-trial-balance",
    files["xero-trial-balance"],
    xeroTrialBalance,
    context({
      account: accountResolver(accountMap),
      chartLoaded: accountMap.length > 0,
      stock:
        stockDomain?.adjustment_account && stockDomain.loaded_total_minor
          ? {
              valueMinor: stockDomain.loaded_total_minor,
              adjustmentAccount: stockDomain.adjustment_account,
            }
          : null,
    }),
  );
  steps.push(
    await opening(
      door,
      "xero-trial-balance",
      tb,
      "nominal",
      asAt,
      PRINTED.trialBalance.minor,
      null,
    ),
  );

  return steps;
}
