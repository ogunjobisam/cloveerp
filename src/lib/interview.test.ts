import { describe, expect, test } from "bun:test";

import {
  answerText,
  buildAnswer,
  dedupeEntries,
  describeItem,
  entriesFromText,
  entryFor,
  fill,
  fromAnswer,
  hasAnswer,
  listEntries,
  listHas,
  missingRequired,
  monthAnswer,
  monthChoices,
  named,
  namesFromQuestions,
  opensGate,
  orderSections,
  outcomeKind,
  pairsFromText,
  pairsOf,
  parseMonth,
  parseNumber,
  pendingProposals,
  readAccept,
  readItems,
  readQuestions,
  readSessions,
  resumeSection,
  sameAnswer,
  sectionProgress,
  statusText,
  toAnswer,
  wireValue,
  type Question,
  type Suggestion,
} from "./interview";

const same = (text: string) => text;

function suggestion(value: string, label: string, extra: Partial<Suggestion> = {}): Suggestion {
  return {
    value,
    code: null,
    label,
    note: null,
    axis: null,
    likely: false,
    available: true,
    unavailable_reason: null,
    present: false,
    ...extra,
  };
}

function question(extra: Partial<Question> & Pick<Question, "code" | "answer_shape">): Question {
  return {
    section: "B.7",
    seq: 10,
    prompt: extra.code,
    help: null,
    choices: [],
    maps_to: null,
    is_required: false,
    applies: true,
    applies_when: null,
    answer: null,
    suggestions: [],
    left_suggestions: [],
    likely: null,
    example: null,
    ...extra,
  };
}

describe("a number as a person types it", () => {
  test("plain, grouped with commas or spaces, or with a currency sign", () => {
    expect(parseNumber("1000")).toBe(1000);
    expect(parseNumber("1,000")).toBe(1000);
    expect(parseNumber("12,500,000")).toBe(12500000);
    expect(parseNumber("1 000")).toBe(1000);
    expect(parseNumber("1 000")).toBe(1000);
    expect(parseNumber("£1,000.50")).toBe(1000.5);
    expect(parseNumber("  250 ")).toBe(250);
  });

  test("a comma that is not a thousands separator is refused, not guessed", () => {
    expect(parseNumber("1.000,50")).toBeNull();
    expect(parseNumber("1,00")).toBeNull();
    expect(parseNumber("10,0000")).toBeNull();
    expect(parseNumber("one thousand")).toBeNull();
    expect(parseNumber("")).toBeNull();
  });

  test("money: the old screen sent Number('1,000'), which is NaN and arrives as null", () => {
    expect(Number("1,000")).toBeNaN();
    expect(toAnswer("money", { kind: "scalar", raw: "1,000" })).toEqual({
      kind: "answer",
      value: 1000,
    });
    expect(toAnswer("money", { kind: "scalar", raw: "12.345" })).toEqual({
      kind: "invalid",
      reason: "too_many_decimals",
      max: 2,
    });
    expect(toAnswer("money", { kind: "scalar", raw: "" })).toEqual({ kind: "empty" });
  });

  test("integer: whole, in range, never zero for an empty box", () => {
    expect(toAnswer("integer", { kind: "scalar", raw: "72" })).toEqual({
      kind: "answer",
      value: 72,
    });
    expect(toAnswer("integer", { kind: "scalar", raw: "1,200" })).toEqual({
      kind: "answer",
      value: 1200,
    });
    expect(toAnswer("integer", { kind: "scalar", raw: "7.5" })).toEqual({
      kind: "invalid",
      reason: "not_whole",
    });
    expect(toAnswer("integer", { kind: "scalar", raw: "13" }, { min: 1, max: 12 })).toEqual({
      kind: "invalid",
      reason: "out_of_range",
      min: 1,
      max: 12,
    });
    expect(toAnswer("integer", { kind: "scalar", raw: "  " })).toEqual({ kind: "empty" });
  });
});

describe("a month", () => {
  test("by number or by name", () => {
    expect(parseMonth("4")).toBe(4);
    expect(parseMonth("04")).toBe(4);
    expect(parseMonth("April")).toBe(4);
    expect(parseMonth("apr")).toBe(4);
    expect(parseMonth("Sept.")).toBe(9);
    expect(parseMonth("ju")).toBeNull();
    expect(parseMonth("13")).toBeNull();
    expect(parseMonth("0")).toBeNull();
  });

  test("the answer is the number the proposer reads", () => {
    expect(monthAnswer({ kind: "scalar", raw: "April" })).toEqual({ kind: "answer", value: 4 });
    expect(monthAnswer({ kind: "scalar", raw: "Smarch" }).kind).toBe("invalid");
    const fy = question({ code: "org.fiscal_year_start", answer_shape: "integer" });
    expect(buildAnswer(fy, { kind: "scalar", raw: "april" })).toEqual({
      kind: "answer",
      value: 4,
    });
  });

  test("twelve choices, named by the locale", () => {
    const en = monthChoices("en-GB");
    expect(en).toHaveLength(12);
    expect(en[0]).toEqual({ value: "1", label: "January" });
    expect(monthChoices("de")[2]?.label).toBe("März");
  });
});

describe("a list", () => {
  test("typed names go as strings; a suggestion keeps the code it lands with", () => {
    const built = toAnswer("text_list", {
      kind: "list",
      entries: [
        { code: null, name: "Operations" },
        { code: "FIN", name: "Finance" },
      ],
    });
    expect(built).toEqual({
      kind: "answer",
      value: ["Operations", { code: "FIN", name: "Finance" }],
    });
  });

  test("read back whichever form each element took", () => {
    expect(listEntries(["Operations", { code: "FG", name: "Finished goods" }, "  ", 7])).toEqual([
      { code: null, name: "Operations" },
      { code: "FG", name: "Finished goods" },
    ]);
    expect(fromAnswer("text_list", ["A"])).toEqual({
      kind: "list",
      entries: [{ code: null, name: "A" }],
    });
  });

  test("the same entry twice is one", () => {
    expect(
      dedupeEntries([
        { code: "FIN", name: "Finance" },
        { code: "fin", name: "Finance dept" },
        { code: null, name: "Sales" },
        { code: null, name: " sales " },
      ]),
    ).toEqual([
      { code: "FIN", name: "Finance" },
      { code: null, name: "Sales" },
    ]);
  });

  test("a name typed by hand that is a starter suggestion lands with its code", () => {
    const pack = [
      suggestion("FIN", "Finance", { code: "FIN" }),
      suggestion("SUP_DOM", "Domestic supplier", { code: "SUP_DOM" }),
    ];
    expect(entryFor(" finance ", pack)).toEqual({ code: "FIN", name: "Finance" });
    expect(entryFor("sup_dom", pack)).toEqual({ code: "SUP_DOM", name: "Domestic supplier" });
    expect(entryFor("Operations", pack)).toEqual({ code: null, name: "Operations" });
    expect(entryFor("   ", pack)).toBeNull();
    expect(listHas([{ code: null, name: "Finance" }], { code: "FIN", name: "Finance" })).toBe(true);
    expect(listHas([{ code: "FIN", name: "Finance" }], { code: "PROC", name: "Procurement" })).toBe(
      false,
    );
  });

  test("an empty list is no answer, not an empty array", () => {
    expect(toAnswer("text_list", { kind: "list", entries: [] })).toEqual({ kind: "empty" });
    expect(entriesFromText("A\n\n B \r\nC")).toEqual([
      { code: null, name: "A" },
      { code: null, name: "B" },
      { code: null, name: "C" },
    ]);
  });
});

describe("pairs", () => {
  test("rows become {left, right}; blank rows are ignored; a picked code travels", () => {
    expect(
      toAnswer("text_pairs", {
        kind: "pairs",
        rows: [
          { left: " UK ", right: "GBP" },
          { left: "", right: "" },
          { left: "STORAGE_COND", right: "Ambient", code: "AMBIENT" },
        ],
      }),
    ).toEqual({
      kind: "answer",
      value: [
        { left: "UK", right: "GBP" },
        { left: "STORAGE_COND", right: "Ambient", code: "AMBIENT" },
      ],
    });
  });

  test("a half-filled row is a mistake to show, not a row to drop", () => {
    expect(
      toAnswer("text_pairs", {
        kind: "pairs",
        rows: [
          { left: "UK", right: "GBP" },
          { left: "IE", right: "" },
        ],
      }),
    ).toEqual({ kind: "invalid", reason: "incomplete_rows", rows: [1] });
  });

  test("read back {left,right,code}, [a, b], {class, level} and {key, value}", () => {
    expect(
      pairsOf([
        { left: "UK", right: "GBP" },
        { left: "STORAGE_COND", right: "Ambient", code: "AMBIENT" },
        ["finished_good", "pallet"],
        { class: "raw", level: "case" },
        { key: "MAIN", value: "fifo" },
        { left: "broken" },
      ]),
    ).toEqual([
      { left: "UK", right: "GBP" },
      { left: "STORAGE_COND", right: "Ambient", code: "AMBIENT" },
      { left: "finished_good", right: "pallet" },
      { left: "raw", right: "case" },
      { left: "MAIN", right: "fifo" },
    ]);
  });

  test("pasted lines: / tab = or comma; a line with none is reported, not lost", () => {
    expect(
      pairsFromText("COLOUR / Red\nSIZE\tLarge\nGRADE=A\nUK, United Kingdom, Ltd\nnothing here"),
    ).toEqual({
      rows: [
        { left: "COLOUR", right: "Red" },
        { left: "SIZE", right: "Large" },
        { left: "GRADE", right: "A" },
        { left: "UK", right: "United Kingdom, Ltd" },
      ],
      unread: ["nothing here"],
    });
  });
});

describe("yes, no and not yet", () => {
  test("an unanswered yes/no shows as unanswered, not as No", () => {
    expect(fromAnswer("boolean", null)).toEqual({ kind: "scalar", raw: "" });
    expect(fromAnswer("boolean", false)).toEqual({ kind: "scalar", raw: "false" });
    expect(toAnswer("boolean", { kind: "scalar", raw: "" })).toEqual({ kind: "empty" });
    expect(toAnswer("boolean", { kind: "scalar", raw: "true" })).toEqual({
      kind: "answer",
      value: true,
    });
  });

  test("clearing sends JSON null, which the door treats as taking the answer back", () => {
    expect(wireValue(toAnswer("text", { kind: "scalar", raw: "  " }))).toBeNull();
    expect(wireValue(toAnswer("boolean", { kind: "scalar", raw: "false" }))).toBe(false);
  });

  test("a choice outside the list is refused before the database refuses it", () => {
    expect(
      toAnswer("choice", { kind: "scalar", raw: "lifo" }, { choices: ["fefo", "fifo"] }),
    ).toEqual({ kind: "invalid", reason: "not_a_choice" });
  });

  test("false is an answer but does not open a gate — as erp.interview_questions decides", () => {
    expect(hasAnswer(false)).toBe(true);
    expect(opensGate(false)).toBe(false);
    expect(opensGate(true)).toBe(true);
    expect(hasAnswer([])).toBe(false);
    expect(opensGate([])).toBe(false);
    expect(opensGate(["A"])).toBe(true);
    expect(opensGate("")).toBe(false);
    expect(opensGate(0)).toBe(true);
  });

  test("the autosave's changed? ignores key order", () => {
    expect(sameAnswer([{ left: "A", right: "B" }], [{ right: "B", left: "A" }])).toBe(true);
    expect(sameAnswer(["A"], ["A", "B"])).toBe(false);
    expect(sameAnswer(null, undefined)).toBe(true);
  });
});

describe("sections and progress", () => {
  test("organisation first, then the interview's order, then anything new", () => {
    expect(orderSections(["B.1", "B.3", "B.7", "B.9", "B.1"])).toEqual([
      "B.7",
      "B.1",
      "B.3",
      "B.9",
    ]);
  });

  test("every section is listed, counted over the questions that apply now", () => {
    const progress = sectionProgress([
      { section: "B.1", applies: true, is_required: true, answer: null },
      { section: "B.7", applies: true, is_required: true, answer: false },
      { section: "B.7", applies: false, is_required: false, answer: null },
      { section: "B.2", applies: true, is_required: false, answer: [] },
    ]);
    expect(progress.map((p) => p.section)).toEqual([
      "B.7",
      "B.1",
      "B.2",
      "B.3",
      "B.4",
      "B.5",
      "B.6",
    ]);
    expect(progress[0]).toEqual({
      section: "B.7",
      asked: 1,
      answered: 1,
      requiredMissing: 0,
      complete: true,
    });
    expect(progress[1]).toEqual({
      section: "B.1",
      asked: 1,
      answered: 0,
      requiredMissing: 1,
      complete: false,
    });
    expect(resumeSection(progress)).toBe("B.1");
  });

  test("resume at the first section with an unanswered question, required or not", () => {
    const progress = sectionProgress([
      { section: "B.7", applies: true, is_required: false, answer: null },
      { section: "B.1", applies: true, is_required: true, answer: null },
    ]);
    expect(resumeSection(progress)).toBe("B.7");
    const done = sectionProgress([{ section: "B.7", applies: true, is_required: true, answer: 1 }]);
    expect(resumeSection(done)).toBe("B.7");
  });

  test("what is missing before proposing, in section order", () => {
    const missing = missingRequired([
      {
        section: "B.1",
        seq: 10,
        applies: true,
        is_required: true,
        answer: null,
        code: "dept.list",
      },
      { section: "B.7", seq: 5, applies: true, is_required: true, answer: null, code: "org.multi" },
      { section: "B.2", seq: 1, applies: false, is_required: true, answer: null, code: "gated" },
      { section: "B.2", seq: 2, applies: true, is_required: true, answer: false, code: "answered" },
    ]);
    expect(missing.map((q) => q.code)).toEqual(["org.multi", "dept.list"]);
  });
});

describe("reading the doors", () => {
  test("questions: missing keys become empty lists, an unknown shape is text", () => {
    const [q] = readQuestions([
      {
        code: "dept.list",
        section: "B.1",
        seq: 10,
        prompt: "Which departments?",
        answer_shape: "text_list",
        is_required: true,
        applies: true,
        answer: null,
        suggestions: [{ value: "FIN", code: "FIN", label: "Finance", present: true }, { bad: 1 }],
      },
    ]);
    expect(q?.suggestions).toEqual([suggestion("FIN", "Finance", { code: "FIN", present: true })]);
    expect(q?.left_suggestions).toEqual([]);
    expect(q?.likely).toBeNull();
    expect(
      readQuestions([{ code: "x", section: "B.5", answer_shape: "rhyme" }])[0]?.answer_shape,
    ).toBe("text");
    expect(readQuestions(null)).toEqual([]);
  });

  test("sessions: proposals in the interview's section order", () => {
    const read = readSessions({
      live: true,
      sessions: [
        {
          session_id: "s1",
          code: "interview-1",
          status: "proposed",
          proposals: [
            {
              section: "B.1",
              proposal_id: "p1",
              change_set_id: "c1",
              change_set_status: "draft",
              item_count: 2,
            },
            {
              section: "B.7",
              proposal_id: "p7",
              change_set_id: "c7",
              change_set_status: "promoted",
              item_count: 1,
            },
          ],
        },
      ],
    });
    expect(read.live).toBe(true);
    expect(read.sessions[0]?.proposals.map((p) => p.section)).toEqual(["B.7", "B.1"]);
    expect(readSessions(undefined)).toEqual({ live: false, sessions: [] });
  });

  test("items and the accept result", () => {
    expect(readItems([{ item_id: "i", object_kind: "department", payload: "nope" }])[0]).toEqual({
      item_id: "i",
      seq: 0,
      object_kind: "department",
      object_key: "",
      operation: "upsert",
      payload: {},
      note: null,
    });
    const accepted = readAccept({
      interview: "interview-1",
      live: false,
      stops_at: "promoted",
      steps: [
        { step: "B.3", outcome: "refused", refusal: { code: "CLOVEERP_X", message: "no" } },
        { step: "B.2", outcome: "skipped", waits_for: "B.1" },
      ],
      landed: 1,
      waiting: 0,
      refused: 1,
    });
    expect(accepted.steps[0]?.refusal).toEqual({
      code: "CLOVEERP_X",
      message: "no",
      detail: null,
      hint: null,
    });
    expect(outcomeKind(accepted.steps[0]!)).toBe("needs_attention");
    expect(outcomeKind(accepted.steps[1]!)).toBe("waiting_section");
    expect(outcomeKind({ outcome: "promoted", waits_for: null })).toBe("in_force");
    expect(outcomeKind({ outcome: "ready", waits_for: null })).toBe("waiting_second");
    expect(outcomeKind({ outcome: "set_up", waits_for: null })).toBe("books_set_up");
    expect(outcomeKind({ outcome: "not_needed", waits_for: null })).toBe("not_needed");
  });
});

describe("statuses in plain words", () => {
  test("each state a proposed change can be in", () => {
    expect(statusText("draft", same)).toBe("Proposed");
    expect(statusText("ready", same)).toBe("Waiting for approval");
    expect(statusText("approved", same)).toBe("Approved, not yet in force");
    expect(statusText("promoted", same)).toBe("In force");
    expect(statusText("failed", same)).toBe("Not applied");
    expect(statusText("rolled_back", same)).toBe("Not applied");
    expect(statusText("cancelled", same)).toBe("Not applied");
  });

  test("after go-live, a change waiting for someone else is not the button's to move", () => {
    const proposals = ["draft", "ready", "approved", "promoted", "failed"].map((s, i) => ({
      section: `B.${i + 1}`,
      proposal_id: `p${i}`,
      change_set_id: `c${i}`,
      change_set_code: null,
      change_set_status: s,
      item_count: 1,
    }));
    expect(pendingProposals(proposals, false).map((p) => p.change_set_status)).toEqual([
      "draft",
      "ready",
      "approved",
    ]);
    expect(pendingProposals(proposals, true).map((p) => p.change_set_status)).toEqual([
      "draft",
      "approved",
    ]);
  });
});

describe("a proposed change, as a sentence", () => {
  const names = namesFromQuestions([
    question({
      code: "org.legislation",
      answer_shape: "text_pairs",
      suggestions: [suggestion("gb_vat", "United Kingdom VAT")],
      left_suggestions: [{ value: "MAIN", label: "Main company", note: null, present: true }],
    }),
    question({
      code: "org.currencies",
      answer_shape: "text_pairs",
      suggestions: [suggestion("GBP", "Pound sterling")],
    }),
    question({
      code: "dept.list",
      section: "B.1",
      answer_shape: "text_list",
      suggestions: [suggestion("FIN", "Finance", { code: "FIN" })],
    }),
    question({
      code: "approval.role",
      section: "B.2",
      answer_shape: "text",
      suggestions: [suggestion("finance_manager", "Finance manager")],
    }),
    question({
      code: "classification.axes",
      section: "B.4",
      answer_shape: "text_list",
      suggestions: [suggestion("STORAGE_COND", "Storage condition", { code: "STORAGE_COND" })],
    }),
    question({
      code: "org.companies",
      answer_shape: "text_pairs",
      answer: [{ left: "UK", right: "Northern Trading Ltd" }],
    }),
  ]);
  const say = (object_kind: string, payload: Record<string, unknown>, object_key = "K") =>
    describeItem({ object_kind, object_key, operation: "upsert", payload }, same, {
      locale: "en-GB",
      names,
    });

  test("names come from the questions: labels with their codes", () => {
    expect(named(names, "pack", "gb_vat")).toBe("United Kingdom VAT (gb_vat)");
    expect(named(names, "company", "MAIN")).toBe("Main company (MAIN)");
    expect(named(names, "company", "UK")).toBe("Northern Trading Ltd (UK)");
    expect(named(names, "currency", "gbp")).toBe("Pound sterling (gbp)");
    expect(named(names, "site", "NORTH")).toBe("NORTH");
    expect(fill("{a} and {b}", { a: 1 })).toBe("1 and {b}");
  });

  test("departments, accounting codes and nominal accounts", () => {
    expect(say("department", { code: "FIN", name: "Finance" })).toBe(
      "Add the department Finance (FIN)",
    );
    expect(say("department", { code: "OPERATIONS", name: "OPERATIONS" })).toBe(
      "Add the department OPERATIONS",
    );
    expect(say("posting_class", { kind: "item", code: "FG", name: "Finished good" })).toBe(
      "Add the accounting code Finished good (FG) for products",
    );
    expect(
      say("posting_class", { kind: "party", code: "SUP_DOM", name: "Domestic supplier" }),
    ).toBe("Add the accounting code Domestic supplier (SUP_DOM) for business partners");
    expect(
      say("account_determination", { transaction_type: "goods_receipt", account: "1200" }),
    ).toBe("Goods that arrive are added to nominal account 1200");
  });

  test("approval bands: document, department, amount in its currency, approver", () => {
    expect(
      say("approval_band", {
        department: "FIN",
        object_type: "purchase_order",
        seq: 1,
        lower_bound_minor: 500000,
        currency: "GBP",
        approver_role: "finance_manager",
        use_line_manager: true,
      }),
    ).toBe(
      "A purchase order from Finance (FIN) above £5,000.00 needs sign-off by Finance manager (finance_manager), and the manager of whoever raised it",
    );
    expect(
      say("approval_band", {
        department: "OPS",
        object_type: "requisition",
        lower_bound_minor: 100000,
        currency: "JPY",
        use_line_manager: true,
      }),
    ).toBe(
      "A requisition from OPS above JP¥100,000 needs sign-off by the manager of whoever raised it",
    );
  });

  test("classification, product codes and marshalling areas", () => {
    expect(say("classification_axis", { code: "BRAND", name: "Brand", is_mandatory: false })).toBe(
      "Group products by Brand (BRAND); a value is optional",
    );
    expect(
      say("classification_axis", {
        code: "PRODUCT_TYPE",
        name: "Product type",
        is_mandatory: true,
      }),
    ).toBe("Group products by Product type (PRODUCT_TYPE); every product needs a value");
    expect(
      say("classification_value", { axis: "STORAGE_COND", code: "AMBIENT", name: "Ambient" }),
    ).toBe("Add Ambient (AMBIENT) as a value of Storage condition (STORAGE_COND)");
    expect(
      say("code_template", {
        code: "ITEM",
        segments: [
          { kind: "literal", value: "IT" },
          { kind: "sequence", length: 5 },
        ],
      }),
    ).toBe("New product codes follow the pattern IT#####, for example IT00001");
    expect(
      say("release_area", {
        code: "PICKING",
        name: "Picking",
        replenishment_mode: "pull",
        ageing_hours: 72,
      }),
    ).toBe(
      "Add the marshalling area Picking (PICKING), bringing in just what is short; stock left more than 72 hours goes back to storage",
    );
    expect(
      say("release_area", { code: "DESP", name: "Despatch", replenishment_mode: "push" }),
    ).toBe("Add the marshalling area Despatch (DESP), topped up when short");
  });

  test("companies, their rules, costing, labels, picking and the chart", () => {
    expect(
      say("entity", {
        code: "UK",
        name: "Northern Trading Ltd",
        currency: "GBP",
        country: "GB",
        locale: "en-GB",
        fiscal_year_start_month: 4,
      }),
    ).toBe(
      "The company Northern Trading Ltd (UK): in GB, keeps its books in Pound sterling (GBP), writes in en-GB, starts its year in April",
    );
    expect(say("entity", { code: "MAIN", currency: "EUR" })).toBe(
      "Main company (MAIN): keeps its books in EUR",
    );
    expect(say("legislation_binding", { entity: "MAIN", pack: "gb_vat", pack_version: "1" })).toBe(
      "Main company (MAIN) follows United Kingdom VAT (gb_vat)",
    );
    expect(say("costing_policy", { code: "DEFAULT", method: "average" })).toBe(
      "Stock is costed at average cost",
    );
    expect(
      say("costing_policy", { code: "DEFAULT", method: "standard", variance_account: "9100" }),
    ).toBe(
      "Stock is costed at a standard cost you set; differences from what you pay go to nominal account 9100",
    );
    expect(say("container_identity_policy", { code: "DEFAULT", identity_level: "pallet" })).toBe(
      "Stock is labelled at the pallet",
    );
    expect(
      say("container_identity_policy", {
        code: "CLASS-FG",
        item_class: "FG",
        identity_level: "case",
      }),
    ).toBe("FG products are labelled at the case");
    expect(
      say("config", {
        config_type: "stock.allocation_policy",
        value: { default: "lifo" },
        site: "NORTH",
      }),
    ).toBe("At NORTH, stock is picked newest stock first");
    expect(
      say("config", { config_type: "stock.allocation_policy", value: { default: "fifo" } }),
    ).toBe("Stock is picked oldest stock first");
    expect(say("capability", { code: "statutory_chart_8_1", enabled: true })).toBe(
      "Number nominal accounts by statutory ranges",
    );
    expect(say("capability", { code: "consignment_stock", enabled: false })).toBe(
      "Switch off the feature consignment_stock",
    );
  });

  test("a kind nobody wrote a sentence for still says something, and removal is marked", () => {
    expect(say("rule_set", {}, "discounts")).toBe("Another change: rule set discounts");
    expect(
      describeItem(
        {
          object_kind: "department",
          object_key: "FIN",
          operation: "remove",
          payload: { code: "FIN" },
        },
        same,
      ),
    ).toBe("Remove: Add the department FIN");
  });

  test("no sentence leaves a placeholder behind", () => {
    const kinds = [
      "department",
      "approval_band",
      "posting_class",
      "account_determination",
      "classification_axis",
      "classification_value",
      "code_template",
      "release_area",
      "entity",
      "legislation_binding",
      "costing_policy",
      "container_identity_policy",
      "config",
      "capability",
    ];
    for (const kind of kinds) expect(say(kind, {})).not.toMatch(/\{[a-z_]+\}/);
  });
});

describe("a likely answer, as a person reads it", () => {
  test("labels rather than values, months by name, rows as left: right", () => {
    const multi = question({
      code: "org.multi_company",
      answer_shape: "boolean",
      suggestions: [
        suggestion("true", "More than one company"),
        suggestion("false", "One company"),
      ],
    });
    expect(answerText(multi, false, same)).toBe("One company");
    expect(answerText(question({ code: "x", answer_shape: "boolean" }), true, same)).toBe("Yes");
    expect(
      answerText(
        question({ code: "org.fiscal_year_start", answer_shape: "integer" }),
        4,
        same,
        "en-GB",
      ),
    ).toBe("April");
    const legislation = question({
      code: "org.legislation",
      answer_shape: "text_pairs",
      suggestions: [suggestion("gb_vat", "United Kingdom VAT")],
      left_suggestions: [{ value: "MAIN", label: "Main company", note: null, present: true }],
    });
    expect(answerText(legislation, [{ left: "MAIN", right: "gb_vat" }], same)).toBe(
      "Main company: United Kingdom VAT",
    );
    const account = question({
      code: "posting.receipt_account",
      answer_shape: "text",
      suggestions: [suggestion("1200", "Inventory")],
    });
    expect(answerText(account, "1200", same)).toBe("Inventory (1200)");
    expect(
      answerText(
        question({ code: "classification.axes", answer_shape: "text_list" }),
        [{ code: "PRODUCT_TYPE", name: "Product type" }],
        same,
      ),
    ).toBe("Product type");
  });
});
