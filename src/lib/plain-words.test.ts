import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import { formatMinor } from "./money";
import {
  actionOutcome,
  approvalChoice,
  cashOutcome,
  countApprovalChoice,
  countOutcome,
  freightTermsOutcome,
  movedDocumentOutcome,
  namedOutcome,
  qualityEventOutcome,
  samplesOutcome,
  transitionOutcome,
  paymentRunOutcome,
  receiptIds,
  receiptOutcome,
  approvalStep,
  approvalSubject,
  asSentence,
  byTone,
  capitalise,
  describeWarehouseTask,
  documentIdInPath,
  documentOutcome,
  lookupOutcome,
  article,
  localIsoDate,
  quarterToDate,
  shortDate,
  movedOnWord,
  orderPeriods,
  periodRank,
  plainHint,
  plainSentence,
  planningOutcome,
  soundsInternal,
  transitionTone,
  madeDocumentId,
  OUTCOME_LINGER_MS,
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
    expect(
      documentOutcome({
        document_id: "d",
        document_number: "PO-000058",
        source_document_number: "REQ-000049",
        moved_on: "inherit_approval",
      }),
    ).toBe("PO-000058 created from REQ-000049 and approved.");
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

  test("a receipt says what it applied, wrote off and kept on account, and counts no remainder as an invoice", () => {
    const gbp = (n: number) => formatMinor(n, "GBP");
    const item = (applied: number, extra: Record<string, unknown> = {}) => ({
      subledger_item_id: `i-${applied}`,
      applied_minor: applied,
      remaining_minor: 0,
      written_off_minor: 0,
      on_account_minor: 0,
      ...extra,
    });
    const rest = (remaining: number, extra: Record<string, unknown> = {}) => ({
      subledger_item_id: null,
      applied_minor: 0,
      remaining_minor: remaining,
      written_off_minor: 0,
      on_account_minor: 0,
      ...extra,
    });
    // A penny short, written off on the invoice it was short on.
    expect(cashOutcome([item(59999, { written_off_minor: 1 })], "GBP")).toBe(
      `${gbp(59999)} applied to 1 open invoice and ${gbp(1)} written off within the tolerance.`,
    );
    // £100 over, kept on the customer's account.
    expect(
      cashOutcome([item(40000), item(20000), rest(10000, { on_account_minor: 10000 })], "GBP"),
    ).toBe(`${gbp(60000)} applied to 2 open invoices and ${gbp(10000)} on account.`);
    // A penny over, credited within the tolerance.
    expect(cashOutcome([item(60000), rest(1, { written_off_minor: 1 })], "GBP")).toBe(
      `${gbp(60000)} applied to 1 open invoice and ${gbp(1)} written off within the tolerance.`,
    );
    // Short beyond it: applied, and nothing else to say.
    expect(cashOutcome([item(59899)], "GBP")).toBe(`${gbp(59899)} applied to 1 open invoice.`);
    // A database that does not say what it kept names what was left over.
    expect(
      cashOutcome(
        [
          { subledger_item_id: "a", applied_minor: 500, remaining_minor: 200 },
          { subledger_item_id: null, applied_minor: 0, remaining_minor: 200 },
        ],
        "GBP",
      ),
    ).toBe(`${gbp(500)} applied to 1 open invoice and ${gbp(200)} left over.`);
    expect(cashOutcome("nope", "GBP")).toBeNull();
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

describe("a lookup says its answer", () => {
  test("a price found names the amount and where it came from", () => {
    expect(
      actionOutcome(
        "Find a price",
        [
          {
            amount_minor: 4200,
            currency: "GBP",
            price_kind: "sales_list",
            price_list_code: "TRADE",
            source: "the sales list",
          },
        ],
        undefined,
        "erp_resolve_price",
      ),
    ).toBe("Find a price: £42.00 each, from the sales list (TRADE).");
    expect(
      actionOutcome(
        "Find a purchase price",
        { amount_minor: 1250, currency: "GBP", price_list_code: null, source: "the last cost" },
        undefined,
        "erp_resolve_purchase_price",
      ),
    ).toBe("Find a purchase price: £12.50 each, from the last cost.");
  });

  test("no price is said as that, not as nothing raised", () => {
    expect(actionOutcome("Find a price", [], undefined, "erp_resolve_price")).toBe(
      "Find a price: nothing prices this product for this customer today. Type a price on the line, or add one to their price list.",
    );
    expect(
      actionOutcome(
        "Find a purchase price",
        { amount_minor: null, source: "no price is on record for this supplier and item" },
        undefined,
        "erp_resolve_purchase_price",
      ),
    ).toBe(
      "Find a purchase price: no price is on record for this supplier and item. Type a price on the line, or add one to the supplier's price list.",
    );
  });

  test("a date promised is shown, and none is said", () => {
    expect(actionOutcome("Promise a date", "2026-10-12", undefined, "erp_promise_date")).toBe(
      "Promise a date: that quantity can be promised for 2026-10-12.",
    );
    expect(actionOutcome("Promise a date", null, undefined, "erp_promise_date")).toBe(
      "Promise a date: no date can be promised for that quantity from that site.",
    );
  });

  test("working out who approves names them, in order, and says when nobody is named (J-50)", () => {
    const step = (approver: string, extra: Record<string, unknown> = {}) => ({
      seq: 1,
      approver_user_id: "00000000-0000-4000-8000-0000000000a1",
      approver,
      approver_of_record: approver,
      covered: false,
      ...extra,
    });
    expect(
      actionOutcome(
        "Work out who approves",
        { steps: [step("Andy Approver"), step("Bea Boss")], exhausted: false },
        undefined,
        "erp_stamp_document_approval",
      ),
    ).toBe("Work out who approves: Andy Approver, then Bea Boss.");
    expect(
      actionOutcome(
        "Work out who approves",
        {
          steps: [step("Carol Cover", { approver_of_record: "Andy Approver", covered: true })],
        },
        undefined,
        "erp_stamp_document_approval",
      ),
    ).toBe("Work out who approves: Carol Cover (for Andy Approver).");
    expect(
      actionOutcome(
        "Work out who approves",
        { steps: [], exhausted: true },
        undefined,
        "erp_stamp_document_approval",
      ),
    ).toBe("Work out who approves: no value band or named approver applies at this value.");
    expect(lookupOutcome("erp_stamp_document_approval", "", { steps: [] })).not.toBeNull();
    expect(lookupOutcome("erp_stamp_document_approval", "", "unexpected")).toBeNull();
  });

  test("any other routine keeps its sentence", () => {
    expect(lookupOutcome("erp_apply_cash", "Apply cash", [])).toBeNull();
    expect(lookupOutcome(undefined, "Anything", "2026-10-12")).toBeNull();
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

  test("the current period first, then open periods already ended, oldest first", () => {
    expect(orderPeriods(calendar, today).map((p) => `${p.code} ${p.ledger}`)).toEqual([
      "2026-09 COMMIT",
      "2026-09 GL",
      "2025-01 GL",
      "2026-06 GL",
    ]);
  });

  test("a closed period is not work waiting, so the step does not count it (J-98)", () => {
    const shown = orderPeriods(calendar, today);
    expect(shown.map((p) => p.status)).not.toContain("closed");
    // The step's count is the rows it lists: one month open and nothing
    // closed counted, not every closed month of every ledger.
    expect(shown).toHaveLength(4);
  });

  test("closed periods, latest first, then periods not yet started and years closed for good wait behind the toggle", () => {
    const all = orderPeriods(calendar, today, true).map((p) => p.code);
    expect(all.slice(4)).toEqual(["2026-08", "2026-07", "2026-10", "2027-12", "2024-12"]);
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

  test("a step names an event, not a event", () => {
    expect(article("event")).toBe("an");
    expect(article("invoice")).toBe("an");
    expect(article("order")).toBe("an");
    expect(article("document")).toBe("a");
    expect(article("works order")).toBe("a");
    expect(article("pallet")).toBe("a");
    // Sound, not spelling.
    expect(article("unit")).toBe("a");
    expect(article("user")).toBe("a");
    expect(article("hour")).toBe("an");
    expect(article("")).toBe("a");
  });

  test("today is the reader's own date, as the database writes one", () => {
    expect(localIsoDate(new Date(2026, 8, 4, 23, 30))).toBe("2026-09-04");
  });

  test("the tax report asks for the calendar quarter so far", () => {
    expect(quarterToDate(new Date(2026, 8, 14, 9, 0))).toEqual({
      p_from: "2026-07-01",
      p_to: "2026-09-14",
    });
    expect(quarterToDate(new Date(2027, 0, 1, 0, 5))).toEqual({
      p_from: "2027-01-01",
      p_to: "2027-01-01",
    });
    const src = readFileSync(join(ROOT, "src", "lib", "modules.tsx"), "utf8");
    expect(src).toMatch(/fn: "erp_tax_report",[\s\S]{0,400}args: quarterToDate\(\)/);
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

  test("a quotation left to expire is a way back, not the way forward (J-76)", () => {
    expect(transitionTone(move("expire", "expired"))).toBe("back");
    expect(transitionTone({ code: "expire" })).toBe("back");
    expect(transitionTone(move("accept", "accepted"))).toBe("forward");
    expect(
      byTone([
        move("expire", "expired"),
        move("decline", "declined"),
        move("accept", "accepted"),
      ]).map((m) => m.code),
    ).toEqual(["accept", "expire", "decline"]);
  });

  test("the document a door made is the one opened next (J-77)", () => {
    expect(madeDocumentId({ document_id: "so-1", document_number: "SO-000001" })).toBe("so-1");
    expect(madeDocumentId({ document_id: "" })).toBeNull();
    expect(madeDocumentId([{ document_id: "so-1" }])).toBeNull();
    expect(madeDocumentId(null)).toBeNull();
  });

  test("a step verb that moves the record on is drawn as the way forward", () => {
    const strip = readFileSync(join(ROOT, "src", "components", "erp", "process-flow.tsx"), "utf8");
    expect(strip).toContain('transitionTone({ code: action.transition }) === "forward"');
    expect(strip).toContain('variant={forward ? "primary" : "secondary"}');
    expect(strip).toContain("{...doneProps(action, openDocument)}");
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

describe("a cash document says what it is (PR13 M4)", () => {
  const gbp = (n: number) => formatMinor(n, "GBP");
  const R1 = "00000000-0000-4000-8000-0000000000r1";
  const R2 = "00000000-0000-4000-8000-0000000000r2";
  const row = (
    document_id: string | null,
    applied: number,
    extra: Record<string, unknown> = {},
  ) => ({
    subledger_item_id: `i-${applied}`,
    applied_minor: applied,
    remaining_minor: 0,
    written_off_minor: 0,
    on_account_minor: 0,
    document_id,
    ...extra,
  });

  test("the receipts are the documents the rows name, once each, in their order", () => {
    expect(receiptIds([row(R1, 100), row(R1, 200), row(R2, 300)])).toEqual([R1, R2]);
    // Receivables version 1 names none.
    expect(receiptIds([row(null, 100)])).toEqual([]);
    expect(receiptIds(null)).toEqual([]);
    expect(receiptIds({ document_id: R1 })).toEqual([]);
  });

  test("Apply cash leads with the receipt it made, and links to it", () => {
    const rest = {
      subledger_item_id: null,
      applied_minor: 0,
      remaining_minor: 10000,
      written_off_minor: 0,
      on_account_minor: 10000,
      document_id: R1,
    };
    expect(
      receiptOutcome([row(R1, 60000), rest], "GBP", [{ documentId: R1, number: "RCPT-000012" }]),
    ).toEqual({
      message: `RCPT-000012: ${gbp(60000)} applied to 1 open invoice and ${gbp(10000)} on account.`,
      documents: [{ documentId: R1, number: "RCPT-000012" }],
    });
    // Two companies' invoices, two receipts (D5).
    expect(
      receiptOutcome([row(R1, 100), row(R2, 200)], "GBP", [
        { documentId: R1, number: "RCPT-000012" },
        { documentId: R2, number: "RCPT-000013" },
      ])?.message,
    ).toBe(`RCPT-000012 and RCPT-000013: ${gbp(300)} applied to 2 open invoices.`);
  });

  test("a receipt whose number could not be read is still linked, and no receipt says only what the cash did", () => {
    expect(receiptOutcome([row(R1, 500)], "GBP", [{ documentId: R1, number: null }])).toEqual({
      message: `${gbp(500)} applied to 1 open invoice.`,
      documents: [{ documentId: R1, number: "the receipt" }],
    });
    expect(receiptOutcome([row(null, 500)], "GBP", [])).toEqual({
      message: `${gbp(500)} applied to 1 open invoice.`,
      documents: [],
    });
    expect(receiptOutcome(null, "GBP", [])).toBeNull();
  });

  test("paying a run names each supplier's payment, and links to each", () => {
    const answer = {
      proposal_id: "p",
      reference: "PAY-000003",
      currency: "GBP",
      lines_paid: 3,
      paid_minor: 90000,
      written_off_minor: 0,
      documents_settled: 3,
      held: 1,
      payments: [
        { document_id: "d1", document_number: "PMT-000001", party_id: "s1", paid_minor: 50000 },
        { document_id: "d2", document_number: "PMT-000002", party_id: "s2", paid_minor: 40000 },
      ],
    };
    expect(paymentRunOutcome(answer, "Pay an approved run")).toEqual({
      message: `PAY-000003 paid ${gbp(90000)} to 2 suppliers: PMT-000001 and PMT-000002. 1 line was held and not paid.`,
      documents: [
        { documentId: "d1", number: "PMT-000001" },
        { documentId: "d2", number: "PMT-000002" },
      ],
    });
    expect(
      paymentRunOutcome(
        { ...answer, held: 0, written_off_minor: 1, payments: [answer.payments[0]] },
        "Pay",
      )?.message,
    ).toBe(
      `PAY-000003 paid ${gbp(90000)} to 1 supplier: PMT-000001, and ${gbp(1)} written off within the tolerance.`,
    );
  });

  test("a run paid on procurement controls version 6 makes no payment, and counts its bills", () => {
    expect(
      paymentRunOutcome(
        { reference: "PAY-000004", currency: "GBP", lines_paid: 2, paid_minor: 1000, held: 0 },
        "Pay",
      ),
    ).toEqual({ message: `PAY-000004 paid ${gbp(1000)} on 2 bills.`, documents: [] });
    expect(paymentRunOutcome("not an answer", "Pay")).toBeNull();
    expect(paymentRunOutcome({ reference: "PAY-1" }, "Pay")).toBeNull();
  });
});

describe("how long an outcome stays", () => {
  // Most outcomes name a document, and each stayed twenty seconds: three of
  // them stacked over the record's heading for a minute, and over the next
  // form opened (J-125).
  test("longer than an ordinary toast, and gone within ten seconds", () => {
    expect(OUTCOME_LINGER_MS).toBeGreaterThan(5000);
    expect(OUTCOME_LINGER_MS).toBeLessThanOrEqual(10_000);
  });

  test("the action form uses it, and clears what is showing when it opens", () => {
    const source = readFileSync(join(ROOT, "src", "components", "erp", "action.tsx"), "utf8");
    expect(source).not.toContain("20_000");
    expect(source).toContain("duration: OUTCOME_LINGER_MS");
    expect(source).toContain("toast.dismiss()");
  });
});

describe("a press says what it did (J-83, J-122, J-124, J-151, R-03)", () => {
  const transfer = {
    document_id: "t",
    document_number: "TRF-000026",
    lines: 1,
    quantity: 4,
    state: "in_transit",
  };

  test("a transfer despatched or received is not a transfer created", () => {
    expect(actionOutcome("Despatch a transfer", transfer, undefined, "erp_despatch_transfer")).toBe(
      "TRF-000026 despatched.",
    );
    expect(actionOutcome("Receive a transfer", transfer, undefined, "erp_receive_transfer")).toBe(
      "TRF-000026 received.",
    );
    expect(
      actionOutcome(
        "Confirm a stock adjustment",
        { document_id: "a", document_number: "ADJ-000003", lines: 2 },
        undefined,
        "erp_post_stock_adjustment",
      ),
    ).toBe("ADJ-000003 posted.");
    // A door that makes the document it names still says created.
    expect(movedDocumentOutcome("erp_create_transfer_order", transfer)).toBeNull();
    expect(actionOutcome("New transfer", transfer)).toBe("TRF-000026 created.");
  });

  test("freight terms name the order and who brings the goods", () => {
    const answer = { order_id: "o", order_number: "PO-000143", freight_terms: "we_collect" };
    expect(freightTermsOutcome(answer)).toBe("PO-000143: we collect the goods.");
    expect(freightTermsOutcome({ ...answer, freight_terms: "supplier_delivers" })).toBe(
      "PO-000143: the supplier delivers the goods.",
    );
    expect(actionOutcome("Set freight terms", answer, undefined, "erp_set_freight_terms")).toBe(
      "PO-000143: we collect the goods.",
    );
    expect(freightTermsOutcome({ order_number: "PO-1", freight_terms: "by_pigeon" })).toBeNull();
  });

  test("a sample settled says which way, from which receipt, and what is still held", () => {
    const settled = {
      line_id: "l",
      receipt_number: "GRN-000012",
      outcome: "return",
      quantity: 3,
      price_minor: 0,
      currency: "GBP",
      held: 2,
    };
    expect(samplesOutcome(settled)).toBe("GRN-000012: 3 returned to the supplier, 2 still held.");
    expect(samplesOutcome({ ...settled, outcome: "keep", held: 0 })).toBe(
      "GRN-000012: 3 kept free, none still held.",
    );
    expect(
      samplesOutcome({ ...settled, outcome: "buy", price_minor: 500, quantity: 1, held: 0 }),
    ).toBe(`GRN-000012: 1 bought at ${formatMinor(500, "GBP")} each, none still held.`);
    expect(actionOutcome("Settle a sample", settled, undefined, "erp_settle_samples")).toBe(
      "GRN-000012: 3 returned to the supplier, 2 still held.",
    );
    expect(samplesOutcome({ receipt_number: "GRN-1", outcome: "lose", quantity: 1 })).toBeNull();
  });

  test("a sentence naming its record replaces the line written before the press", () => {
    expect(
      namedOutcome("erp_settle_samples", {
        receipt_number: "GRN-1",
        outcome: "keep",
        quantity: 1,
        held: 0,
      }),
    ).not.toBeNull();
    expect(
      namedOutcome("erp_set_freight_terms", { order_number: "PO-1", freight_terms: "we_collect" }),
    ).not.toBeNull();
    expect(namedOutcome("erp_reverse_journal", { state: "submitted" })).toBeNull();
    const source = readFileSync(join(ROOT, "src", "components", "erp", "action.tsx"), "utf8");
    expect(source).toContain("namedOutcome(fn, result) !== null");
  });

  test("a journal reversal waits for approval, and says so", () => {
    const reversal = { journal_id: "j", journal_number: null, state: "submitted", lines: 2 };
    expect(actionOutcome("Reverse the journal", reversal, undefined, "erp_reverse_journal")).toBe(
      "Submitted for approval.",
    );
    expect(actionOutcome("Reverse the journal", reversal)).not.toBe("Submitted for approval.");
  });

  test("a problem reported is named by its reference", () => {
    expect(qualityEventOutcome({ quality_event_id: "q", reference: "QE-000012" })).toBe(
      "QE-000012 reported.",
    );
    expect(qualityEventOutcome(undefined)).toBeNull();
  });

  test("a move on a document names it and the state it is in now", () => {
    expect(transitionOutcome("PO-000143", { state: "approved" })).toBe(
      "PO-000143 is now approved.",
    );
    expect(transitionOutcome(null, { state: "pending_approval" })).toBe(
      "This document is now pending approval.",
    );
    expect(transitionOutcome("PO-000143", null)).toBeNull();
  });

  test("a count says whether it posted or what it waits for", () => {
    expect(countOutcome("A-01 P1", "erp_record_count", "posted")).toBe(
      "A-01 P1: counted and posted.",
    );
    expect(countOutcome("A-01 P1", "erp_record_count", "pending_approval")).toBe(
      "A-01 P1: counted, and waiting for approval.",
    );
    expect(countOutcome("A-01 P1", "erp_record_count", "counted")).toBe(
      "A-01 P1: counted, and waiting to be posted.",
    );
    expect(countOutcome("A-01 P1", "erp_post_count", 2)).toBe("A-01 P1: posted.");
    expect(countOutcome("", "erp_recount_task", "open")).toBe("The count: to be counted again.");
  });

  test("none of these sentences is written for the people who build the product", () => {
    for (const sentence of [
      actionOutcome("x", transfer, undefined, "erp_despatch_transfer"),
      freightTermsOutcome({ order_number: "PO-1", freight_terms: "supplier_delivers" }) ?? "",
      samplesOutcome({ receipt_number: "GRN-1", outcome: "keep", quantity: 1, held: 1 }) ?? "",
      transitionOutcome("SO-1", { state: "pending_approval" }) ?? "",
      countOutcome("A-01", "erp_record_count", "pending_approval"),
    ])
      expect(soundsInternal(sentence)).toBe(false);
  });

  test("the pressed buttons say what they did", () => {
    const transitions = readFileSync(
      join(ROOT, "src", "components", "erp", "document-transitions.tsx"),
      "utf8",
    );
    expect(transitions).toContain("transitionOutcome(documentNumber, result)");
    const counts = readFileSync(
      join(ROOT, "src", "components", "erp", "count-worklist.tsx"),
      "utf8",
    );
    expect(counts.match(/countOutcome\(/g)?.length).toBe(2);
  });
});

describe("a press is busy until its lists are read again (J-123)", () => {
  const source = readFileSync(join(ROOT, "src", "components", "erp", "action.tsx"), "utf8");

  test("both the press and the form wait for what they changed", () => {
    expect(source).not.toMatch(/invalidates\.forEach\(/);
    expect(source.match(/await readAgain\(queryClient, invalidates\)/g)?.length).toBe(2);
    expect(source).toContain("queryClient.invalidateQueries({ queryKey: [key] })");
  });
});

describe("an approval waiting on me says what it is worth (J-56)", () => {
  test("the amount sits between who it is with and who asked", () => {
    expect(
      approvalChoice({
        object_type: "document",
        document_number: "PO-000143",
        document_type_name: "Purchase order",
        partner: "Anchor Fasteners",
        value_minor: 10860,
        currency: "GBP",
        requested_by: "Samuel Ogunjobi",
      }),
    ).toBe(
      `PO-000143 · Purchase order — Anchor Fasteners — ${formatMinor(10860, "GBP")} — Samuel Ogunjobi`,
    );
  });

  test("an approval with no amount, or no partner, leaves them out", () => {
    expect(
      approvalChoice({
        object_type: "match_exception",
        value_minor: null,
        currency: null,
        requested_by: "Sam",
      }),
    ).toBe("Match exception — Sam");
  });

  test("the approvals picker uses it", () => {
    const src = readFileSync(join(ROOT, "src", "routes", "procurement", "index.tsx"), "utf8");
    expect(src).toContain("describe: approvalChoice");
  });
});

describe("a count waiting on my approval is named by what was counted where (J-20)", () => {
  test("a day reads as a person writes it, and nothing else reads as one", () => {
    expect(shortDate("2026-10-04T12:00:00Z")).toBe("4 Oct 2026");
    expect(shortDate("2026-10-04")).toBe("4 Oct 2026");
    expect(shortDate("not a day")).toBeNull();
    expect(shortDate(null)).toBeNull();
  });

  test("the product, the place, what was found against what was expected, who and when", () => {
    expect(
      countApprovalChoice({
        object_type: "count_task",
        item: "PK-010",
        item_name: "Packing box",
        location: "RECV",
        site: "MAIN",
        context: { counted: 50, expected: "100.000000", variance: "-50.000000" },
        requested_by: "Samuel Ogunjobi",
        requested_at: "2026-10-04T12:15:14.717477+00:00",
      }),
    ).toBe("PK-010 Packing box at RECV — counted 50, expected 100 — Samuel Ogunjobi — 4 Oct 2026");
  });

  test("a count with no place or figures still says what it is, and never the raw kind or time", () => {
    const words = countApprovalChoice({
      object_type: "count_task",
      item: "PK-010",
      site: "MAIN",
      context: null,
      requested_by: "Sam",
      requested_at: "2026-10-04T12:15:14Z",
    });
    expect(words).toBe("PK-010 at MAIN — Sam — 4 Oct 2026");
    expect(words).not.toContain("count_task");
    expect(words).not.toContain("T12:15");
  });

  test("Decide a count difference offers counts only, named this way", () => {
    const src = readFileSync(join(ROOT, "src", "routes", "inventory", "audit.tsx"), "utf8");
    expect(src).toContain('keep: (r) => r["object_type"] === "count_task"');
    expect(src).toContain("describe: countApprovalChoice");
  });
});
