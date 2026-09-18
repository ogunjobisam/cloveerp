import { describe, expect, test } from "bun:test";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

import {
  DOOR_ONLY_TRANSITIONS,
  isDoorOnlyTransition,
  manualTransitions,
  offersAnyTransition,
  type Transition,
} from "../components/erp/available-transitions";
import type { FlowSpec, Stage } from "../components/erp/process-flow";
import { actionKey } from "./flow-actions";
import { formatMinorTotals, formatMinorWhole } from "./money";
import { MODULES } from "./modules";
import {
  DOCUMENT_READ,
  FIELD_LABELS,
  SETTLED,
  formatWhen,
  offerFor,
  partyLabel,
  rowsAtStage,
  stepsPerRow,
  settledAtStage,
  stageReadArgs,
  stateOf,
  summariseRecord,
} from "./stage-records";

/**
 * What sits at a step, and what the record beside it says.
 *
 * The owner walked Purchasing in the demonstration organisation and found the
 * first two steps listing the same twenty-six requisitions, most of them
 * already Ordered; the record printing TOTAL MINOR 317100 and IS CANCELLED
 * false; and "Submit for approval" offered on a requisition that had become an
 * order. Each of those is one of the functions below, and each is pinned here.
 */

const ROOT = join(import.meta.dir, "..", "..");

const requisition = (state: string, extra: Record<string, unknown> = {}) => ({
  document_id: `id-${state}`,
  document_number: `REQ-${state}`,
  document_type: "requisition",
  document_date: "2026-09-01",
  required_date: null,
  currency: "GBP",
  party: "Dales Dairy Co",
  total_minor: 317100,
  state,
  state_name: state.charAt(0).toUpperCase() + state.slice(1),
  is_committed: state === "ordered",
  is_cancelled: false,
  ...extra,
});

const DOCS = [
  requisition("draft"),
  requisition("submitted"),
  requisition("approved"),
  requisition("ordered"),
  requisition("cancelled"),
  // Flagged cancelled on the document while its state still reads draft.
  { ...requisition("draft"), document_id: "id-flagged", is_cancelled: true },
];

describe("a step lists what sits there", () => {
  test("a document step asks the door for its states", () => {
    expect(
      stageReadArgs(DOCUMENT_READ, { p_type_code: "requisition", p_limit: 200 }, ["draft"], false),
    ).toEqual({ p_type_code: "requisition", p_limit: 200, p_states: ["draft"] });
  });

  test("asked for finished ones too, it reads the type whole", () => {
    const args = { p_type_code: "requisition", p_limit: 200 };
    expect(stageReadArgs(DOCUMENT_READ, args, ["draft"], true)).toEqual(args);
  });

  test("a step that is not documents, or names no states, reads as declared", () => {
    expect(stageReadArgs("erp_works_orders", { p_limit: 200 }, ["released"], false)).toEqual({
      p_limit: 200,
    });
    expect(stageReadArgs(DOCUMENT_READ, { p_type_code: "x" }, undefined, false)).toEqual({
      p_type_code: "x",
    });
  });

  test("the requisition step holds drafts, and nothing ordered or cancelled", () => {
    const rows = rowsAtStage(DOCS, { states: ["draft"], statusKey: "state_name" });
    expect(rows.map((r) => r["document_id"])).toEqual(["id-draft"]);
  });

  test("the approval step does not hold the same rows as the requisition step", () => {
    const approval = rowsAtStage(DOCS, {
      states: ["submitted", "approved"],
      statusKey: "state_name",
    });
    expect(approval.map((r) => r["document_id"])).toEqual(["id-submitted", "id-approved"]);
  });

  test("show finished brings back the finished ones beside what is waiting", () => {
    const rows = rowsAtStage(DOCS, { states: ["draft"], statusKey: "state_name" }, true);
    expect(rows.map((r) => r["document_id"])).toEqual([
      "id-draft",
      "id-ordered",
      "id-cancelled",
      "id-flagged",
    ]);
  });

  test("a status read is narrowed by its status", () => {
    const orders = [
      { works_order_id: "a", status: "planned" },
      { works_order_id: "b", status: "released" },
      { works_order_id: "c", status: "closed" },
    ];
    expect(
      rowsAtStage(orders, { states: ["released", "in_progress"], statusKey: "status" }),
    ).toEqual([orders[1]!]);
  });

  test("a step that names no states lists its read as it comes", () => {
    const pallets = [{ line_key: "1", putaway_task: "open" }];
    expect(rowsAtStage(pallets, { statusKey: "putaway_task" })).toEqual(pallets);
  });

  test("the state is the code, not the name", () => {
    expect(
      stateOf({ state: "pending_approval", state_name: "Pending approval" }, "state_name"),
    ).toBe("pending_approval");
    expect(stateOf({ status: "Released" }, "status")).toBe("released");
    expect(stateOf(null)).toBeNull();
  });
});

describe("every flow module names the states of its record steps", () => {
  // Read as the strip reads them: a stage the strip lists records for, with a
  // verb for the chosen record, must say which states it holds, or it is the
  // Requisition-and-Approval fault again.
  const routeFlows = ["procurement", "sales"].map((area) =>
    readFileSync(join(ROOT, "src", "routes", area, "index.tsx"), "utf8"),
  );

  const stagesWithRecordVerbs = (flow: FlowSpec): Stage[] =>
    flow.stages.filter((s) => (s.typeCode || s.list) && (s.actionFn || s.actionFns?.length));

  for (const mod of MODULES.filter((m) => m.flow)) {
    const flow = mod.flow as FlowSpec;
    // Stock's count step is being reworked elsewhere; its read is left as it was.
    const exempt = new Set(["Count"]);
    test(`${mod.key}: each step with a verb for its records names their states`, () => {
      const bare = stagesWithRecordVerbs(flow)
        .filter((s) => !exempt.has(s.label))
        .filter((s) => !s.states || s.states.length === 0)
        .map((s) => s.label);
      expect(bare).toEqual([]);
    });

    test(`${mod.key}: a state a verb is offered in is one the step can list`, () => {
      // Held at the step, or finished and reached through "Show finished" —
      // billing a posted receipt is the second kind. Anything else is a verb
      // no row on the step could ever be offered.
      const stray = flow.stages.flatMap((s) =>
        Object.entries(s.actionStates ?? {}).flatMap(([key, states]) =>
          states
            .filter((st) => !(s.states ?? []).includes(st) && !SETTLED.has(st))
            .map((st) => `${s.label}: ${key} in ${st}`),
        ),
      );
      expect(stray).toEqual([]);
    });

    test(`${mod.key}: every verb a step gates by state is a verb it carries`, () => {
      const keys = new Set((mod.actions ?? []).map(actionKey));
      const unknown = flow.stages.flatMap((s) =>
        Object.keys(s.actionStates ?? {}).filter((k) => !keys.has(k)),
      );
      expect(unknown).toEqual([]);
    });
  }

  test("purchasing and sales name the states of their document steps", () => {
    for (const src of routeFlows) {
      const typed = [...src.matchAll(/typeCode:\s*"([a-z_]+)",\s*\n(\s*\/\/[^\n]*\n)*\s*states:/g)];
      const all = [...src.matchAll(/^\s*typeCode:\s*"([a-z_]+)"/gm)];
      expect(all.length).toBeGreaterThan(3);
      expect(typed.length).toBe(all.length);
    }
  });
});

describe("a verb is offered where the record's state allows it", () => {
  const base = { settled: false, staysOpen: false, stageStates: ["draft"] };

  test("submit is not offered on an ordered requisition", () => {
    expect(offerFor({ ...base, transition: "submit", state: "ordered", available: [] })).toBe(
      "hide",
    );
  });

  test("submit is offered on a draft whose state has it", () => {
    expect(
      offerFor({ ...base, transition: "submit", state: "draft", available: ["submit", "cancel"] }),
    ).toBe("offer");
  });

  test("while the moves are being read, nothing is offered yet", () => {
    expect(offerFor({ ...base, transition: "submit", state: "draft", available: undefined })).toBe(
      "wait",
    );
  });

  test("with no read of the moves, the step's states answer", () => {
    expect(offerFor({ ...base, transition: "submit", state: "draft", available: null })).toBe(
      "offer",
    );
    expect(offerFor({ ...base, transition: "submit", state: "ordered", available: null })).toBe(
      "hide",
    );
  });

  test("a verb gated by state is offered only in those states", () => {
    const bill = { ...base, offeredIn: ["posted"], available: null };
    expect(offerFor({ ...bill, state: "draft" })).toBe("hide");
    expect(offerFor({ ...bill, state: "posted" })).toBe("offer");
  });

  test("a verb that is neither stays, greyed on a finished record", () => {
    const stamp = { ...base, available: null, state: "ordered" };
    expect(offerFor({ ...stamp, settled: true })).toBe("settled");
    expect(offerFor({ ...stamp, settled: true, staysOpen: true })).toBe("offer");
    expect(offerFor({ ...stamp, settled: false })).toBe("offer");
  });

  test("a record in its own step's states is not settled there", () => {
    expect(settledAtStage({ status: "despatched" }, "status", ["booked", "despatched"])).toBeNull();
    expect(settledAtStage({ status: "despatched" }, "status", ["planned"])).toBe("despatched");
    expect(settledAtStage(requisition("ordered"), "state_name", ["draft"])).toBe("ordered");
    expect(settledAtStage({ ...requisition("draft"), is_cancelled: true }, "state_name", [])).toBe(
      "cancelled",
    );
  });
});

describe("the record says what a person reads", () => {
  const source = { fn: DOCUMENT_READ, id: "document_id", status: "state_name" };

  test("a document shows its party, its date and its total as money, and nothing internal", () => {
    const fields = summariseRecord(requisition("ordered"), source, () => 2, "supplier");
    expect(fields.map((f) => f.label)).toEqual(["Supplier", "Document date", "Total"]);
    const total = fields.find((f) => f.key === "total_minor");
    expect(total?.kind).toBe("money");
    expect(total?.value).toContain("£");
    expect(total?.value).toContain("3,171.00");
    const keys = fields.map((f) => f.key);
    for (const internal of [
      "is_cancelled",
      "is_committed",
      "document_type",
      "state",
      "document_id",
    ])
      expect(keys).not.toContain(internal);
  });

  test("a required-by date is shown when the document has one", () => {
    const fields = summariseRecord(
      requisition("draft", { required_date: "2026-10-01" }),
      source,
      () => 2,
      "customer",
    );
    expect(fields.map((f) => f.label)).toEqual([
      "Customer",
      "Document date",
      "Required by",
      "Total",
    ]);
  });

  test("the party is named by the side of the trade, or as a business partner", () => {
    expect(partyLabel("customer")).toBe("Customer");
    expect(partyLabel("supplier")).toBe("Supplier");
    expect(partyLabel(undefined)).toBe("Business partner");
  });

  test("any other row drops identifiers, flags and the state, and formats money and time", () => {
    const shipment = {
      shipment_id: "s1",
      reference: "SH-1",
      status: "booked",
      carrier: "DPD",
      carrier_id: "c1",
      is_international: false,
      planned_despatch: "2026-09-14",
      actual_arrival: "2026-09-15T09:30:00+00:00",
      freight_cost_minor: 4250,
      currency: "GBP",
      proof_of_delivery: { signed_by: "A" },
    };
    const fields = summariseRecord(shipment, {
      fn: "erp_shipments",
      id: "shipment_id",
      title: ["reference"],
      status: "status",
    });
    expect(fields.map((f) => f.key)).toEqual([
      "carrier",
      "planned_despatch",
      "actual_arrival",
      "freight_cost_minor",
    ]);
    const cost = fields.find((f) => f.key === "freight_cost_minor");
    expect(cost?.label).toBe("Freight cost");
    expect(cost?.value).toContain("42.50");
    expect(fields.find((f) => f.key === "actual_arrival")?.value).toBe("2026-09-15 09:30");
  });

  test("a zero-place currency is not divided by a hundred", () => {
    const fields = summariseRecord(
      { ...requisition("draft"), currency: "JPY", total_minor: 5000 },
      source,
      (code) => (code === "JPY" ? 0 : 2),
    );
    expect(fields.find((f) => f.key === "total_minor")?.value).toContain("5,000");
  });

  test("a time at midnight is a date", () => {
    expect(formatWhen("2026-09-14T00:00:00+00:00")).toBe("2026-09-14");
    expect(formatWhen("2026-09-14")).toBe("2026-09-14");
  });
});

describe("money on a tile", () => {
  test("has its symbol and is in whole units", () => {
    const shown = formatMinorWhole(40055200, "GBP", 2);
    expect(shown).toContain("£");
    expect(shown).toContain("400,552");
    expect(shown).not.toContain(".");
  });

  test("rows in one currency are one figure in it", () => {
    const shown = formatMinorTotals([
      { minor: 100000, currency: "EUR" },
      { minor: 50000, currency: "EUR" },
    ]);
    expect(shown).toContain("€");
    expect(shown).toContain("1,500");
    expect(shown).not.toContain("+");
  });

  test("rows in two currencies are not added together", () => {
    const shown = formatMinorTotals([
      { minor: 100000, currency: "GBP" },
      { minor: 500000, currency: "USD" },
    ]);
    expect(shown).toContain("+");
    expect(shown.indexOf("$")).toBeLessThan(shown.indexOf("£"));
  });

  test("rows naming no currency count in the fallback", () => {
    expect(formatMinorTotals([{ minor: 12300, currency: null }])).toContain("£123");
  });
});

describe("every word the strip, the record and the help sheet say has a row", () => {
  // The harvest in supabase/ci/screen_strings.sh reads ui("…") on one line,
  // and prettier wraps a long one, so this reads the wrapped form too and
  // checks the words against every migration that seeds erp_ref.resource.
  const MIGRATIONS = join(ROOT, "supabase", "migrations");
  const seeds = readdirSync(MIGRATIONS)
    .filter((f) => f.endsWith(".sql"))
    .map((f) => readFileSync(join(MIGRATIONS, f), "utf8"))
    .filter((src) => src.includes("erp_ref.resource"))
    .join("\n");
  const seeded = (text: string) => seeds.includes(`'${text.replace(/'/g, "''")}'`);

  const files = [
    join(ROOT, "src", "components", "erp", "process-flow.tsx"),
    join(ROOT, "src", "components", "erp", "context-help.tsx"),
  ];

  test("every ui() literal in them", () => {
    const literals = files.flatMap((f) =>
      [...readFileSync(f, "utf8").matchAll(/\bui\(\s*"((?:[^"\\]|\\.)*)",?\s*\)/g)].map(
        (m) => m[1]!,
      ),
    );
    expect(literals.length).toBeGreaterThan(5);
    expect(literals.filter((t) => !seeded(t))).toEqual([]);
  });

  test("every label the record can show", () => {
    const labels = [...Object.values(FIELD_LABELS), "Customer", "Supplier", "Yes", "No"];
    expect(labels.filter((t) => !seeded(t))).toEqual([]);
  });
});

describe("a move another document makes is never a button", () => {
  const move = (code: string, extra: Partial<Transition> = {}): Transition => ({
    code,
    name: code,
    to_state: code,
    permitted: true,
    guard_passes: true,
    is_automatic: false,
    ...extra,
  });
  const codes = (type: string, list: string[]) =>
    manualTransitions(
      type,
      list.map((c) => move(c)),
    ).map((t) => t.code);

  test("the list is the moves a receipt, a pick, a despatch, an invoice, a payment or a credit note makes", () => {
    expect(DOOR_ONLY_TRANSITIONS).toEqual({
      purchase_order: ["receive_partial", "receive_rest", "receive_all"],
      sales_order: ["pick", "despatch", "invoice"],
      sales_invoice: ["settle", "credit"],
      purchase_invoice: ["pay"],
    });
  });

  test("a sent purchase order offers no receiving, and keeps what a person records", () => {
    expect(
      codes("purchase_order", [
        "submit",
        "approve",
        "reject",
        "send",
        "receive_partial",
        "receive_rest",
        "receive_all",
        "close",
        "cancel",
        "cancel_approved",
      ]),
    ).toEqual(["submit", "approve", "reject", "send", "close", "cancel", "cancel_approved"]);
  });

  test("a sales order offers no pick, despatch or invoice", () => {
    expect(
      codes("sales_order", ["submit", "approve", "pick", "despatch", "invoice", "close", "cancel"]),
    ).toEqual(["submit", "approve", "close", "cancel"]);
  });

  test("an invoice is neither paid nor credited by a bare button, and is still issued, registered and disputed", () => {
    // Credited is terminal. Pressed with nothing behind it, the button said the
    // customer had been given their money back when nobody had.
    expect(codes("sales_invoice", ["issue", "settle", "credit", "cancel"])).toEqual([
      "issue",
      "cancel",
    ]);
    expect(codes("purchase_invoice", ["register", "dispute", "resolve", "pay", "cancel"])).toEqual([
      "register",
      "dispute",
      "resolve",
      "cancel",
    ]);
  });

  test("the list is by type: the same code elsewhere, or an unknown type, is left alone", () => {
    expect(codes("goods_receipt", ["post", "pay", "invoice"])).toEqual(["post", "pay", "invoice"]);
    expect(codes("requisition", ["submit", "order"])).toEqual(["submit", "order"]);
    expect(isDoorOnlyTransition(null, "pay")).toBe(false);
    expect(isDoorOnlyTransition("purchase_invoice", "pay")).toBe(true);
  });

  test("a document whose only moves are made by doors offers nothing", () => {
    const sent = [move("receive_partial"), move("receive_all")];
    expect(offersAnyTransition("purchase_order", sent)).toBe(false);
    expect(offersAnyTransition("purchase_order", [...sent, move("close")])).toBe(true);
    expect(offersAnyTransition("purchase_order", [move("close", { permitted: false })])).toBe(
      false,
    );
  });

  test("this list is exactly the moves the driver register does not leave to a screen", () => {
    // The database says what fires each transition
    // (erp.transition_driver_register, 20260919900000). A row marked 'screen'
    // means the document page draws a button for it; a row marked 'routine' or
    // 'undriven' means it does not, which is this list. Two lists that disagree
    // mean either a button drawn over nothing or a move nobody can make, the
    // pair of defects that file exists to stop.
    const register = readFileSync(
      join(ROOT, "supabase", "migrations", "20260919905000_the_lifecycle_completes.sql"),
      "utf8",
    );
    const body = register.slice(
      register.indexOf("from (values"),
      register.indexOf("as x(machine_code"),
    );
    const registered: Record<string, string[]> = {};
    for (const match of body.matchAll(
      /\('([a-z_]+)'(?:::text)?,\s*'([a-z_]+)'(?:::text)?,\s*'(screen|routine|undriven)'/g,
    )) {
      const [, machine, code, driver] = match;
      if (!machine || !code || driver === "screen") continue;
      (registered[machine] ??= []).push(code);
    }
    const sorted = (list: readonly string[]) => [...list].sort();
    const shape = (byType: Record<string, readonly string[]>) =>
      Object.fromEntries(Object.entries(byType).map(([k, v]) => [k, sorted(v)]));
    expect(shape(registered)).toEqual(shape(DOOR_ONLY_TRANSITIONS));
  });

  test("every move on the list is one the shipped lifecycle of that type declares", () => {
    // A renamed move would leave its button back on the screen with nothing
    // here to say so.
    const spine = readFileSync(
      join(ROOT, "supabase", "migrations", "20260904150000_document_spine_through_promotion.sql"),
      "utf8",
    );
    const missing = Object.entries(DOOR_ONLY_TRANSITIONS).flatMap(([type, list]) => {
      const start = spine.indexOf(`'kind','state_machine','key','${type}'`);
      const end = spine.indexOf("'kind','", start + 1);
      const machine = start < 0 ? "" : spine.slice(start, end < 0 ? undefined : end);
      return list
        .filter((c) => !machine.includes(`'code','${c}','name'`))
        .map((c) => `${type}.${c}`);
    });
    expect(missing).toEqual([]);
  });
});

describe("how many steps a strip puts on a row", () => {
  test("steps that fit side by side are one row", () => {
    expect(stepsPerRow(5, 7)).toBe(5);
    expect(stepsPerRow(8, 8)).toBe(8);
  });

  test("eight steps with room for six go four and four, not six and two", () => {
    // Purchase-to-pay at 1512px: the case that pushed Payment off the edge.
    expect(stepsPerRow(8, 6)).toBe(4);
  });

  test("wrapped rows are as even as they can be", () => {
    expect(stepsPerRow(8, 3)).toBe(3); // 3, 3, 2
    expect(stepsPerRow(5, 4)).toBe(3); // 3, 2
    expect(stepsPerRow(7, 5)).toBe(4); // 4, 3
  });

  test("no row is ever wider than the room it has", () => {
    for (let count = 1; count <= 12; count++) {
      for (let fits = 1; fits <= 12; fits++) {
        expect(stepsPerRow(count, fits)).toBeLessThanOrEqual(Math.max(1, Math.min(count, fits)));
      }
    }
  });

  test("a width too narrow for one step still draws one per row", () => {
    expect(stepsPerRow(8, 0)).toBe(1);
  });
});
