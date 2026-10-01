import { beforeAll, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import type { CrosswalkEntry } from "../crosswalk";
import type { Json } from "../types";
import {
  PILOT_FILES,
  PilotError,
  runPilot,
  type Door,
  type PilotFile,
  type PilotStep,
} from "./run";

/**
 * The pilot against a fake of the doors it calls: enough of the database to
 * keep a crosswalk, total what each domain loaded, and keep migration clearing
 * as the four loaders post it. It proves the fixture set is one organisation
 * whose files agree with one another — every file reads clean, every staged
 * total meets its printed total, and clearing comes to zero — before the build
 * proves the same against the real doors (supabase/ci/pilot_rehearsal.sh).
 */

const files = Object.fromEntries(
  PILOT_FILES.map((f) => [
    f,
    readFileSync(new URL(`../fixtures/pilot/${f}.csv`, import.meta.url), "utf8"),
  ]),
) as Record<PilotFile, string>;

const CLOVE_CHART = [
  { code: "1100", name: "Trade debtors", control_kind: "receivable", is_postable: true },
  { code: "1300", name: "Stock", control_kind: "inventory", is_postable: true },
  { code: "2100", name: "Trade creditors", control_kind: "payable", is_postable: true },
  { code: "1200", name: "Bank", control_kind: null, is_postable: true },
  { code: "5900", name: "Stock adjustments", control_kind: null, is_postable: true },
];

type Row = Record<string, Json>;
type Batch = { kind: string; rows: Row[]; control: number | null; evidence: boolean };

function fakeDoor() {
  const batches = new Map<string, Batch>();
  const crosswalk: (CrosswalkEntry & { source: string; object: string })[] = [];
  const calls: string[] = [];
  let clearing = 0;
  let stockLoaded = 0;
  let next = 0;
  const num = (v: Json | undefined) => (typeof v === "number" ? v : 0);

  const door: Door = async (fn, args = {}) => {
    calls.push(fn);
    const batch = () => {
      const b = batches.get(String(args["p_batch_id"]));
      if (!b) throw new Error(`${fn}: no batch ${String(args["p_batch_id"])}`);
      return b;
    };
    switch (fn) {
      case "erp_accounts":
        return CLOVE_CHART;
      case "erp_import_crosswalk":
        return crosswalk
          .filter((e) => e.source === args["p_source_system"] && e.object === args["p_object_type"])
          .map(({ legacy_key, legacy_name, clove_code, resolution }) => ({
            legacy_key,
            legacy_name,
            clove_code,
            resolution,
          }));
      case "erp_stage_import":
      case "erp_stage_opening_balances": {
        const id = `batch-${++next}`;
        batches.set(id, {
          kind: String(args["p_object_type"] ?? args["p_domain_code"]),
          rows: args["p_rows"] as Row[],
          control:
            typeof args["p_control_total_minor"] === "number"
              ? args["p_control_total_minor"]
              : null,
          evidence: false,
        });
        return fn === "erp_stage_import" ? id : { batch_id: id };
      }
      case "erp_record_control_evidence": {
        const b = batch();
        const held = (args["p_exclusions"] as Row[]).reduce(
          (s, e) => s + num(e["amount_minor"]),
          0,
        );
        if (num(args["p_printed_minor"]) - held !== b.control) {
          throw new Error(`CLOVEERP_CONTROL_EVIDENCE_DISAGREES on ${b.kind}`);
        }
        b.evidence = true;
        return {};
      }
      case "erp_validate_import":
        batch();
        return { errors: 0 };
      case "erp_preview_import":
        return [];
      case "erp_load_import": {
        const b = batch();
        for (const r of b.rows) {
          switch (b.kind) {
            case "account":
              crosswalk.push({
                source: "xero",
                object: "account",
                legacy_key: String(r["legacy_code"] ?? r["legacy_name"]),
                legacy_name: String(r["legacy_name"]),
                clove_code: String(r["code"]),
                resolution: r["action"] as CrosswalkEntry["resolution"],
              });
              break;
            case "party_profile":
              crosswalk.push({
                source: String(r["source"]),
                object: "party",
                legacy_key: String(r["legacy_key"]),
                legacy_name: String(r["name"]),
                clove_code: String(r["code"]),
                resolution: "map",
              });
              break;
            case "stock": {
              const value =
                typeof r["value_minor"] === "number"
                  ? r["value_minor"]
                  : Math.round(Number(r["quantity"]) * num(r["unit_cost_minor"]));
              stockLoaded += value;
              clearing -= value;
              break;
            }
            case "sales_ledger":
              clearing -= num(r["amount_minor"]);
              break;
            case "purchase_ledger":
              clearing += num(r["amount_minor"]);
              break;
            case "nominal":
              clearing -= num(r["debit_minor"]) - num(r["credit_minor"]);
              break;
          }
        }
        return b.rows.length;
      }
      case "erp_activate_import_batch":
        return { activated: batch().rows.length };
      case "erp_migration_domains":
        return [
          { domain_code: "stock", loaded_total_minor: stockLoaded, adjustment_account: "5900" },
        ];
      default:
        throw new Error(`the pilot called ${fn}, which the fake does not know`);
    }
  };
  return { door, batches, crosswalk, calls, clearing: () => clearing };
}

describe("the Xero + Unleashed pilot", () => {
  const fake = fakeDoor();
  let steps: PilotStep[] = [];
  beforeAll(async () => {
    steps = await runPilot(fake.door, files, "2026-10-01");
  });
  const rowsOf = (file: PilotFile) => {
    const id = steps.find((s) => s.file === file)?.batchId ?? "";
    return fake.batches.get(id)?.rows ?? [];
  };

  test("every file stages, in the runbook's order", () => {
    expect(steps.map((s) => s.file)).toEqual([...PILOT_FILES]);
  });

  test("every opening batch stages exactly its printed total less what is held back, with its working", () => {
    for (const s of steps.filter((x) => x.controlMinor !== null)) {
      expect([s.file, s.stagedMinor]).toEqual([s.file, s.controlMinor]);
    }
    for (const b of fake.batches.values()) {
      if (b.control !== null) expect([b.kind, b.evidence]).toEqual([b.kind, true]);
    }
  });

  test("the four domains together leave migration clearing at zero", () => {
    expect(fake.clearing()).toBe(0);
  });

  test("Xero's Inventory above the stock loaded goes to stock adjustment (D7)", () => {
    expect(rowsOf("xero-trial-balance")).toContainEqual({ account: "5900", debit_minor: 2680 });
  });

  test("stock loads at Unleashed's value, sub-penny averages included", () => {
    const stock = steps.find((s) => s.file === "unleashed-stock");
    expect(stock?.stagedMinor).toBe(417320);
    expect(rowsOf("unleashed-stock")).toContainEqual(
      expect.objectContaining({ item: "WID-01", unit_cost_minor: 234, value_minor: 28020 }),
    );
  });

  test("Unleashed's lists land on the party Xero loaded, and only a party Xero never named is new", () => {
    const codes = rowsOf("unleashed-customers").map((r) => [r["legacy_key"], r["code"]]);
    expect(codes).toEqual([
      ["BAYSIDE", "BAY001"],
      ["CARTER", "CARTERSONS"],
      ["DUNMORE", "DUN001"],
      ["HOLLIS", "HOLLIS"],
    ]);
  });

  test("a product finds its supplier by Unleashed's code or by name", () => {
    const supplier = (code: string) =>
      (
        rowsOf("unleashed-products").find((r) => r["code"] === code)?.["supplier"] as
          Row | undefined
      )?.["party"];
    expect(supplier("FIX-M6")).toBe("EAS001");
    expect(supplier("WID-01")).toBe("FER001");
  });

  test("the role step gives Greenway the supplier role Unleashed never could", () => {
    const greenway = rowsOf("xero-contacts").find((r) => r["name"] === "Greenway Office Services");
    expect(greenway?.["roles"]).toEqual(["supplier"]);
  });

  test("the ledgers name parties by the codes the contacts loaded", () => {
    expect(rowsOf("xero-aged-receivables").map((r) => r["party"])).toEqual([
      "BAY001",
      "BAY001",
      "CARTERSONS",
      "DUN001",
    ]);
    expect(rowsOf("xero-aged-payables").map((r) => r["party"])).toEqual([
      "EAS001",
      "FER001",
      "GRE001",
    ]);
  });

  test("a staged total that misses its control stops the pilot before anything is staged", async () => {
    const short = fakeDoor();
    const broken = {
      ...files,
      "unleashed-stock": files["unleashed-stock"].replace("2,150.00", "2,151.00"),
    };
    await expect(runPilot(short.door, broken, "2026-10-01")).rejects.toBeInstanceOf(PilotError);
    expect(short.calls).not.toContain("erp_stage_opening_balances");
  });
});
