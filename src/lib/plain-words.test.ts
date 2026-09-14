import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import {
  actionOutcome,
  approvalStep,
  approvalSubject,
  asSentence,
  byTone,
  capitalise,
  describeWarehouseTask,
  documentIdInPath,
  documentOutcome,
  localIsoDate,
  movedOnWord,
  orderPeriods,
  periodRank,
  plainHint,
  plainSentence,
  planningOutcome,
  soundsInternal,
  transitionTone,
} from "./plain-words";
import { rowsAtStage } from "./stage-records";

/**
 * What a customer reads, from what the database wrote.
 *
 * Each case is something the owner met on the live desk on 14 September: a
 * refusal in lower case with a note for the engine's maintainers after it, a
 * toast that did not name the requisition it made, a Close step that opened on
 * December next year, and a putaway picker that read like a database row.
 */

const ROOT = join(import.meta.dir, "..", "..");

describe("a sentence from the database", () => {
  test("starts with a capital letter", () => {
    expect(capitalise("you despatched DN-000255 and cannot also invoice it")).toBe(
      "You despatched DN-000255 and cannot also invoice it",
    );
    expect(capitalise("  “quoted” first")).toBe("“Quoted” first");
    expect(capitalise("'draft' is not a state it leaves")).toBe("'Draft' is not a state it leaves");
  });

  test("a sentence that starts with a number or a code is left as it is", () => {
    expect(capitalise("2 of 40 cases")).toBe("2 of 40 cases");
    expect(capitalise("DN-000255 is posted")).toBe("DN-000255 is posted");
    expect(capitalise("")).toBe("");
  });

  test("ends with a stop, once", () => {
    expect(asSentence("you despatched DN-000255 and cannot also invoice it")).toBe(
      "You despatched DN-000255 and cannot also invoice it.",
    );
    expect(asSentence("Already said.")).toBe("Already said.");
    expect(asSentence("Is it?")).toBe("Is it?");
    expect(asSentence('Say "yes."')).toBe('Say "yes."');
  });

  test("the hint a customer was shown on 14 September is not shown again", () => {
    const hint =
      "B1 has carried sales.despatch and sales.invoice as separate permissions since it was written; this is the first thing to require that they be held by different people.";
    expect(soundsInternal(hint)).toBe(true);
    expect(plainSentence(hint)).toBeNull();
  });

  test("each kind of internal wording is caught on its own", () => {
    for (const internal of [
      "Legislation packs are priced at nil by default (§17.6).",
      "The platform runs on its own primitives (D37).",
      "Part 5 says so.",
      "Specification v1.5 requires it.",
      "Hold sales.despatch first.",
      "Grant master_data.write to them.",
      "erp.configure_receivables() installs it.",
      "Registered in erp_ref.refusal.",
      "Call erp_invoice_from_delivery again.",
      "The document is pending_approval.",
      "Raised as CLOVEERP_SEGREGATION_OF_DUTIES.",
      "Kept apart since it was written.",
      "It does not bypass row-level security.",
    ]) {
      expect([internal, soundsInternal(internal)]).toEqual([internal, true]);
    }
  });

  test("a plain sentence is shown, including numbers, codes and e.g.", () => {
    for (const plain of [
      "Ask a colleague who may do this step to do it.",
      "Enter a discount between 0 and 99.99%.",
      "Record the customer's acceptance on the quote first.",
      "DN-000255 has no lines, e.g. after a cancellation.",
      "Give the approving role to somebody, or choose another approver role on the Configuration screen.",
      "The order FG-5000 of 20 at £32.00 is over the credit limit.",
    ]) {
      expect([plain, soundsInternal(plain)]).toEqual([plain, false]);
      expect(plainSentence(plain)).toBe(plain);
    }
    expect(plainSentence("   ")).toBeNull();
    expect(plainSentence(null)).toBeNull();
  });

  test("a hint may name the permission to ask for, and nothing else internal", () => {
    expect(plainHint("Ask an administrator to grant inventory.read.")).toBe(
      "Ask an administrator to grant inventory.read.",
    );
    expect(plainHint("grant master_data.write to them")).toBe("Grant master_data.write to them.");
    expect(
      plainHint(
        "B1 has carried sales.despatch and sales.invoice as separate permissions since it was written; this is the first thing to require that they be held by different people.",
      ),
    ).toBeNull();
    expect(plainHint("Call erp_invoice_from_delivery again.")).toBeNull();
    expect(plainHint("The document is pending_approval.")).toBeNull();
    expect(plainHint("")).toBeNull();
  });
});

describe("a toast names what was made", () => {
  test("a new document, and the move it was given", () => {
    expect(
      documentOutcome({
        document_id: "a",
        document_number: "REQ-000047",
        lines: 2,
        moved_on: "submit",
      }),
    ).toBe("REQ-000047 created and submitted.");
    expect(
      documentOutcome({ document_id: "a", document_number: "REQ-000048", moved_on: null }),
    ).toBe("REQ-000048 created.");
  });

  test("a converted document names the one it came from", () => {
    expect(
      documentOutcome({
        document_id: "b",
        document_number: "PO-000057",
        source_document_number: "REQ-000047",
        moved_on: null,
      }),
    ).toBe("PO-000057 created from REQ-000047.");
    expect(
      documentOutcome({
        document_id: "c",
        document_number: "DN-000255",
        order_document_number: "SO-000262",
        moved_on: "post",
      }),
    ).toBe("DN-000255 created from SO-000262 and posted.");
  });

  test("a move with no word of its own still says it moved", () => {
    expect(movedOnWord("dispatch_to_carrier")).toBe("moved on");
    expect(movedOnWord(null)).toBeNull();
  });

  test("a result without a document id and number is not a document made", () => {
    expect(documentOutcome({ document_number: "SO-1", picked: 3 })).toBeNull();
    expect(documentOutcome("0b5c…")).toBeNull();
    expect(documentOutcome([{ document_id: "a", document_number: "X" }])).toBeNull();
  });

  test("the toast says the number instead of the dialog's title", () => {
    expect(
      actionOutcome("New requisition", {
        document_id: "a",
        document_number: "REQ-000047",
        moved_on: "submit",
      }),
    ).toBe("REQ-000047 created and submitted.");
    expect(
      actionOutcome("Turn this requisition into a purchase order", {
        document_id: "b",
        document_number: "PO-000057",
        source_document_number: "REQ-000047",
      }),
    ).toBe("PO-000057 created from REQ-000047.");
  });

  test("applying cash counts the items it settled, not records created", () => {
    expect(actionOutcome("Apply cash", [{}, {}], undefined, "erp_apply_cash")).toBe(
      "Cash applied to 2 open items.",
    );
    expect(actionOutcome("Apply cash", [{}], undefined, "erp_apply_cash")).toBe(
      "Cash applied to 1 open item.",
    );
    expect(actionOutcome("Raise putaway tasks", 1, undefined, "erp_raise_putaway_tasks")).toBe(
      "1 putaway task raised.",
    );
  });

  test("counts, nought and an answer with nothing to count keep their sentences", () => {
    expect(actionOutcome("Something", 3)).toBe("Something: 3 records created.");
    expect(actionOutcome("Something", 0, "nothing is standing in goods-in at that site.")).toBe(
      "Something: nothing was raised — nothing is standing in goods-in at that site. Change the site or the dates and try again.",
    );
    expect(actionOutcome("Something", "0b5c")).toBe("Something — done.");
  });

  test("a planning run says what it produced, or why it produced nothing", () => {
    expect(
      planningOutcome("Run planning", { run_id: "r", orders_raised: 3, exceptions_raised: 1 }),
    ).toBe("Run planning: 3 planned orders and 1 exception.");
    expect(
      planningOutcome("Run planning", { run_id: "r", orders_raised: 1, exceptions_raised: 0 }),
    ).toBe("Run planning: 1 planned order and 0 exceptions.");
    const nothing = planningOutcome("Run planning", {
      run_id: "r",
      orders_raised: 0,
      exceptions_raised: 0,
    });
    expect(nothing).toStartWith("Run planning: no planned orders and no exceptions.");
    expect(nothing).toContain("reorder point");
    expect(planningOutcome("Run planning", undefined)).toBeNull();
    expect(planningOutcome("Run planning", { run_id: "r" })).toBeNull();
  });
});

describe("the Close step's periods", () => {
  const period = (code: string, status: string, ledger = "GL") => {
    const [y, m] = code.split("-").map(Number) as [number, number];
    const last = new Date(Date.UTC(y, m, 0)).getUTCDate();
    return {
      code,
      ledger,
      status,
      starts_on: `${code}-01`,
      ends_on: `${code}-${String(last).padStart(2, "0")}`,
    };
  };
  // As the door lists them: newest first, a year ahead.
  const calendar = [
    period("2027-12", "open"),
    period("2026-10", "open"),
    period("2026-09", "open"),
    period("2026-09", "open", "COMMIT"),
    period("2026-08", "closed"),
    period("2026-07", "closed"),
    period("2026-06", "open"),
    period("2025-01", "open"),
    period("2024-12", "permanently_closed"),
  ];
  const today = "2026-09-14";

  test("the current period first, then open periods already ended, oldest first, then closed ones, latest first", () => {
    expect(orderPeriods(calendar, today).map((p) => `${p.code} ${p.ledger}`)).toEqual([
      "2026-09 COMMIT",
      "2026-09 GL",
      "2025-01 GL",
      "2026-06 GL",
      "2026-08 GL",
      "2026-07 GL",
    ]);
  });

  test("periods not yet started and years closed for good wait behind the toggle", () => {
    const all = orderPeriods(calendar, today, true).map((p) => p.code);
    expect(all.slice(-3)).toEqual(["2026-10", "2027-12", "2024-12"]);
    expect(all).toHaveLength(calendar.length);
  });

  test("through the step's own states, the toggle brings back future periods and years closed for good", () => {
    const states = ["future", "open", "closing", "closed"];
    const held = rowsAtStage(calendar, { states, statusKey: "status" });
    expect(orderPeriods(held, today).map((p) => p["code"])).not.toContain("2024-12");
    const all = rowsAtStage(calendar, { states, statusKey: "status" }, true);
    expect(orderPeriods(all, today, true).map((p) => p["code"])).toContain("2024-12");
    expect(orderPeriods(all, today, true).map((p) => p["code"])).toContain("2027-12");
  });

  test("a period is where it stands for somebody closing the books", () => {
    expect(periodRank(period("2026-09", "open"), today)).toBe(0);
    expect(periodRank(period("2026-06", "open"), today)).toBe(1);
    expect(periodRank(period("2026-08", "closed"), today)).toBe(2);
    expect(periodRank(period("2026-10", "open"), today)).toBe(3);
    expect(periodRank(period("2026-09", "future"), today)).toBe(3);
    expect(periodRank(period("2024-12", "permanently_closed"), today)).toBe(4);
  });

  test("today is the reader's own date, as the database writes one", () => {
    expect(localIsoDate(new Date(2026, 8, 4, 23, 30))).toBe("2026-09-04");
  });

  test("the Close step is declared to work in that order", () => {
    const src = readFileSync(join(ROOT, "src", "lib", "modules.tsx"), "utf8");
    expect(src).toContain(
      "arrange: (rows, showFinished) => orderPeriods(rows, localIsoDate(), showFinished)",
    );
    expect(src).toContain('showFinishedLabel: "Show future and finished periods"');
  });
});

describe("a picker and a page say what a thing is", () => {
  const task = {
    task_id: "t",
    kind: "putaway",
    status: "open",
    item: "FG-5000",
    item_name: "Acme widget, boxed, for the northern depots",
    from_location: "RECV",
    from_location_name: "Goods in",
    to_location: "BULK",
    to_location_name: "Bulk store",
    quantity: 100,
  };

  test("a warehouse task reads the way the floor says it", () => {
    expect(describeWarehouseTask(task)).toBe(
      "FG-5000 Acme widget, boxed, for the… from Goods in to Bulk store, 100",
    );
    expect(describeWarehouseTask({ ...task, item_name: "Widget" }, true)).toBe(
      "Putaway: FG-5000 Widget from Goods in to Bulk store, 100",
    );
  });

  test("a door that names only codes still says from and to", () => {
    expect(
      describeWarehouseTask({
        item: "FG-5000",
        from_location: "RECV",
        to_location: "BULK",
        quantity: 5,
      }),
    ).toBe("FG-5000 from RECV to BULK, 5");
  });

  test("a document's page is found from its path, and nothing else is", () => {
    expect(documentIdInPath("/documents/a35c7414-5d5b-4c1e-9a7e-0b1c2d3e4f50")).toBe(
      "a35c7414-5d5b-4c1e-9a7e-0b1c2d3e4f50",
    );
    expect(documentIdInPath("/documents/a35c7414-5d5b-4c1e-9a7e-0b1c2d3e4f50/")).toBe(
      "a35c7414-5d5b-4c1e-9a7e-0b1c2d3e4f50",
    );
    expect(documentIdInPath("/documents")).toBeNull();
    expect(documentIdInPath("/procurement/a35c7414-5d5b-4c1e-9a7e-0b1c2d3e4f50")).toBeNull();
    expect(documentIdInPath("/documents/not-an-id")).toBeNull();
  });

  test("an approval says what it is for and which step it is at", () => {
    expect(
      approvalSubject({
        object_type: "document",
        document_number: "PO-000057",
        document_type_name: "Purchase order",
      }),
    ).toBe("PO-000057 · Purchase order");
    expect(approvalSubject({ object_type: "match_exception" })).toBe("Match exception");
    expect(approvalStep({ step_code: "finance_review", step_name: "Finance review" })).toBe(
      "Finance review",
    );
    expect(approvalStep({ step_code: "finance_review", step_name: "finance_review" })).toBe(
      "Finance review",
    );
    expect(approvalStep({})).toBe("—");
  });
});

describe("a way out does not look like the way forward", () => {
  const move = (code: string, to_state: string) => ({ code, to_state });

  test("cancel is a way out, reject a way back, submit the way forward", () => {
    expect(transitionTone(move("cancel", "cancelled"))).toBe("out");
    expect(transitionTone(move("cancel_order", "void"))).toBe("out");
    expect(transitionTone(move("reject", "draft"))).toBe("back");
    expect(transitionTone(move("send_back", "draft"))).toBe("back");
    expect(transitionTone(move("decline", "declined"))).toBe("back");
    expect(transitionTone(move("submit", "pending_approval"))).toBe("forward");
    expect(transitionTone(move("approve", "approved"))).toBe("forward");
  });

  test("the way forward is drawn first and the way out last", () => {
    const moves = [
      move("cancel", "cancelled"),
      move("reject", "draft"),
      move("approve", "approved"),
    ];
    expect(byTone(moves).map((m) => m.code)).toEqual(["approve", "reject", "cancel"]);
  });

  test("the shared transitions component draws a way out in the destructive colour", () => {
    const src = readFileSync(
      join(ROOT, "src", "components", "erp", "document-transitions.tsx"),
      "utf8",
    );
    expect(src).toContain('transitionTone(t) === "out"');
    expect(src).toContain('"danger"');
  });
});

describe("the refusal texts this change registers are plain", () => {
  const migration = readFileSync(
    join(ROOT, "supabase", "migrations", "20260914075500_refusals_and_toasts_speak_plainly.sql"),
    "utf8",
  );

  test("every text between the markers passes the same test the screens apply", () => {
    const block =
      /-- refusal texts: begin\n([\s\S]*?)-- refusal texts: end/.exec(migration)?.[1] ?? "";
    const literals = [...block.matchAll(/'((?:[^']|'')*)'/g)].map((m) => m[1]!.replace(/''/g, "'"));
    const texts = literals.filter((t) => !/^CLOVEERP_[A-Z_%]+$/.test(t));
    expect(texts.length).toBeGreaterThanOrEqual(39);
    expect(texts.filter((t) => soundsInternal(t))).toEqual([]);
    expect(texts.filter((t) => asSentence(t) !== t)).toEqual([]);
  });

  test("the database's pattern names the same kinds of wording", () => {
    for (const fragment of [
      "§",
      "since it was written",
      "row[- ]level security",
      "master_data",
      "erp_ref",
    ]) {
      expect([fragment, migration.includes(fragment)]).toEqual([fragment, true]);
    }
  });
});
