import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import {
  VAT_EXPORT_FORMATS,
  VAT_PERMISSION,
  boxLines,
  exceptionsOf,
  exportFile,
  groupFindings,
  nextReturns,
  normaliseObligations,
  statusTone,
  vatPresses,
  type VatObligation,
} from "./vat-returns";

const MAIN = "00000000-0000-4000-8000-0000000000a1";
const OTHER = "00000000-0000-4000-8000-0000000000a2";
const RETURN = "00000000-0000-4000-8000-0000000000b1";

const BOXES = {
  box1_minor: 574911,
  box2_minor: 0,
  box3_minor: 574911,
  box4_minor: 120000,
  box5_minor: 454911,
  box5_is: "payable",
  box6_pounds: 77956,
  box7_pounds: 131909,
  box8_pounds: 0,
  box9_pounds: 0,
};

const raw = (over: Record<string, unknown> = {}) => ({
  entity_id: MAIN,
  company: "MAIN",
  vrn: "GB123456789",
  currency: "GBP",
  frequency: "quarterly",
  stagger: 1,
  period_start: "2026-04-01",
  period_end: "2026-06-30",
  due_on: "2026-08-07",
  status: "overdue",
  return_document_id: null,
  return_number: null,
  boxes: BOXES,
  entries: 49,
  entries_digest: "0bd2",
  carried_forward: { entries: 0, net_minor: 0, tax_minor: 0, over_threshold: false },
  is_next: true,
  take_from: "2025-08-23",
  can_finalise: true,
  finalise_blocked_by: null,
  can_export: false,
  ...over,
});

const holds =
  (...codes: string[]) =>
  (code: string) =>
    codes.includes(code);

const one = (over: Record<string, unknown> = {}): VatObligation => {
  const [row] = normaliseObligations([raw(over)]);
  if (!row) throw new Error("the fixture did not normalise");
  return row;
};

describe("the obligations as the door answers them", () => {
  test("a row keeps its dates, status, boxes and what the doors would take", () => {
    const row = one();
    expect(row.period_end).toBe("2026-06-30");
    expect(row.status).toBe("overdue");
    expect(row.boxes?.box5_minor).toBe(454911);
    expect(row.boxes?.box5_is).toBe("payable");
    expect(row.take_from).toBe("2025-08-23");
    expect(row.can_finalise).toBe(true);
    expect(row.can_export).toBe(false);
  });

  test("an answer that is not a list, and rows with no company, period or known state, are nothing", () => {
    expect(normaliseObligations(null)).toEqual([]);
    expect(normaliseObligations({ rows: [] })).toEqual([]);
    expect(
      normaliseObligations([
        raw({ entity_id: null }),
        raw({ period_end: "" }),
        raw({ status: "filed" }),
        "a string",
      ]),
    ).toEqual([]);
  });

  test("a door older than the screen says nothing about its presses, and nothing is offered", () => {
    const old = raw();
    delete (old as Record<string, unknown>)["can_finalise"];
    delete (old as Record<string, unknown>)["can_export"];
    const [row] = normaliseObligations([old]);
    expect(row?.can_finalise).toBe(false);
    expect(row?.can_export).toBe(false);
  });

  test("box 5 is never negative, and says which way it goes", () => {
    const row = one({ boxes: { ...BOXES, box5_minor: -2000, box5_is: "repayable" } });
    expect(row.boxes?.box5_minor).toBe(2000);
    expect(row.boxes?.box5_is).toBe("repayable");
  });
});

describe("the two presses", () => {
  test("Finalise is drawn on the next period that has ended, where the door would take it", () => {
    expect(vatPresses(one(), holds(VAT_PERMISSION))).toEqual({ finalise: true, export: false });
    expect(vatPresses(one({ status: "due" }), holds(VAT_PERMISSION)).finalise).toBe(true);
  });

  test("it is not drawn without finance.close_period, whatever the row says", () => {
    expect(vatPresses(one(), holds("finance.read"))).toEqual({ finalise: false, export: false });
  });

  test("it is not drawn where the database says the door would refuse", () => {
    const row = one({ can_finalise: false, finalise_blocked_by: "An earlier period is open" });
    expect(vatPresses(row, holds(VAT_PERMISSION)).finalise).toBe(false);
  });

  test("it is not drawn on an open period, a later one, or a finalised one", () => {
    const can = holds(VAT_PERMISSION);
    expect(vatPresses(one({ status: "open" }), can).finalise).toBe(false);
    expect(vatPresses(one({ is_next: false }), can).finalise).toBe(false);
    expect(vatPresses(one({ status: "finalised" }), can).finalise).toBe(false);
  });

  test("Export is drawn on a finalised return the door would export, and nowhere else", () => {
    const can = holds(VAT_PERMISSION);
    const done = { status: "finalised", is_next: false, can_finalise: false };
    expect(
      vatPresses(one({ ...done, can_export: true, return_document_id: RETURN }), can).export,
    ).toBe(true);
    expect(vatPresses(one({ ...done, can_export: true }), can).export).toBe(false);
    expect(
      vatPresses(one({ ...done, can_export: false, return_document_id: RETURN }), can).export,
    ).toBe(false);
    expect(vatPresses(one({ can_export: true, return_document_id: RETURN }), can).export).toBe(
      false,
    );
    expect(
      vatPresses(
        one({ ...done, can_export: true, return_document_id: RETURN }),
        holds("finance.read"),
      ).export,
    ).toBe(false);
  });

  test("the next returns are one per company, and never an open or finalised period", () => {
    const rows = normaliseObligations([
      raw({ status: "finalised", is_next: false, period_end: "2026-03-31" }),
      raw(),
      raw({ status: "open", is_next: false, period_end: "2026-09-30" }),
      raw({ entity_id: OTHER, company: "OTHER", status: "open", is_next: true }),
    ]);
    expect(nextReturns(rows).map((r) => `${r.company} ${r.period_end}`)).toEqual([
      "MAIN 2026-06-30",
    ]);
  });
});

describe("the exceptions to read before finalising", () => {
  const answer = [
    {
      entity_id: OTHER,
      exceptions: [{ finding: "elsewhere", blocks: true, reference: "X", detail: "x" }],
    },
    {
      entity_id: MAIN,
      box1_minor: 1,
      exceptions: [
        { finding: "a purchase from abroad", blocks: false, reference: "PINV-1", detail: "flag" },
        { finding: "the tax determined is not", blocks: true, reference: "INV-1", detail: "block" },
        { blocks: true, detail: "no finding" },
      ],
    },
  ];

  test("they are the company's own, blocking first", () => {
    expect(exceptionsOf(answer, MAIN).map((x) => `${x.blocks} ${x.reference}`)).toEqual([
      "true INV-1",
      "false PINV-1",
    ]);
  });

  test("a company the door did not answer for, or an answer with none, has none", () => {
    expect(exceptionsOf(answer, "nobody")).toEqual([]);
    expect(exceptionsOf(null, MAIN)).toEqual([]);
    expect(exceptionsOf([{ entity_id: MAIN }], MAIN)).toEqual([]);
  });
});

describe("the findings as the next return lists them (J-99)", () => {
  const abroad = "a purchase from abroad states no tax, and may need the reverse charge";
  const exempt = "an exempt supply is in the period, and box 4 claims all input tax";
  const flag = (finding: string, reference: string) => ({
    finding,
    blocks: false,
    reference,
    detail: `${reference} ${finding}`,
  });
  const block = (reference: string) => ({
    finding: "the tax determined is not the tax the ledger carries",
    blocks: true,
    reference,
    detail: `${reference} blocks`,
  });

  test("each finding that blocks keeps a line of its own, ahead of the checks", () => {
    const groups = groupFindings([flag(abroad, "PINV-1"), block("INV-1"), block("INV-2")]);
    expect(groups.map((g) => `${g.blocks} ${g.items.map((x) => x.reference).join(",")}`)).toEqual([
      "true INV-1",
      "true INV-2",
      "false PINV-1",
    ]);
  });

  test("the checks are one line per kind, counted, in the order the door gave them", () => {
    const many = Array.from({ length: 63 }, (_, i) => flag(abroad, `PINV-${i + 1}`));
    const groups = groupFindings([...many.slice(0, 30), flag(exempt, "INV-9"), ...many.slice(30)]);
    expect(groups.map((g) => `${g.finding} ${g.items.length}`)).toEqual([
      `${abroad} 63`,
      `${exempt} 1`,
    ]);
    expect(groups[0]?.items[0]?.reference).toBe("PINV-1");
    expect(groups[0]?.items.map((x) => x.reference)).toEqual(many.map((x) => x.reference));
  });

  test("nothing to check is no line at all", () => {
    expect(groupFindings([])).toEqual([]);
  });
});

describe("the file the export door hands over", () => {
  test("is its body as it came, with its name, type and digest", () => {
    const body = "field,value\nreturn,VAT-000001\n";
    expect(
      exportFile({
        filename: "VAT-000001_2025-08-23_2025-09-30.csv",
        media_type: "text/csv",
        sha256: "f30a",
        body,
      }),
    ).toEqual({
      filename: "VAT-000001_2025-08-23_2025-09-30.csv",
      mediaType: "text/csv",
      body,
      sha256: "f30a",
    });
  });

  test("an empty body is still a file; no body or no name is not", () => {
    expect(exportFile({ filename: "a.csv", body: "" })?.body).toBe("");
    expect(exportFile({ filename: "a.csv" })).toBeNull();
    expect(exportFile({ body: "x" })).toBeNull();
    expect(exportFile("x")).toBeNull();
  });

  test("three forms, the nine boxes first, each the export door makes", () => {
    expect(VAT_EXPORT_FORMATS.map((f) => f.format)).toEqual(["csv", "json", "entries_csv"]);
  });
});

describe("the nine boxes as a person reads them", () => {
  test("nine lines in order, pence to box 5 and whole pounds from box 6", () => {
    const lines = boxLines(one().boxes ?? (BOXES as never));
    expect(lines.map((l) => l.box)).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9]);
    expect(lines.filter((l) => l.whole).map((l) => l.box)).toEqual([6, 7, 8, 9]);
    expect(lines[5]?.minor).toBe(7795600);
    expect(lines[4]?.minor).toBe(454911);
  });

  test("an overdue period reads as a fault, a finalised one as done", () => {
    expect(statusTone("overdue")).toBe("bad");
    expect(statusTone("due")).toBe("warn");
    expect(statusTone("finalised")).toBe("ok");
    expect(statusTone("open")).toBe("muted");
  });
});

describe("the screen declares the cycle its budget is held to", () => {
  const route = readFileSync(join(import.meta.dir, "..", "routes", "finance", "vat.tsx"), "utf8");

  test("its cycle is vat, and its verbs are the two presses", () => {
    expect(route).toContain('code: "vat"');
    const verbs = [...route.matchAll(/actionFn:\s*"([^"]+)"/g)].map((m) => m[1]);
    expect(verbs).toEqual(["erp_finalise_vat_return", "erp_vat_return_export"]);
  });

  test("it reads the four doors that had waited for it", () => {
    for (const door of [
      "erp_vat_obligations",
      "erp_vat_boxes",
      "erp_finalise_vat_return",
      "erp_vat_return_export",
    ]) {
      expect(route).toContain(`"${door}"`);
    }
  });
});
