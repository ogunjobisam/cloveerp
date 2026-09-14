import { describe, expect, test } from "bun:test";

import {
  COST_CENTRE,
  draftLinesOf,
  emptyLine,
  isBlankLine,
  journalLinesArg,
  journalName,
  journalTotals,
  lineAmounts,
  minorToInput,
  readJournals,
  stateLabel,
  stateTone,
  type DraftLine,
} from "./journals";

const line = (over: Partial<DraftLine>): DraftLine => ({ ...emptyLine(), ...over });

describe("a line", () => {
  test("an untouched line is blank and a line with only a description is not", () => {
    expect(isBlankLine(emptyLine())).toBe(true);
    expect(isBlankLine(line({ debit: "  " }))).toBe(true);
    expect(isBlankLine(line({ description: "Accrual" }))).toBe(false);
  });

  test("pounds and pence become minor units, and a half penny rounds as typed", () => {
    expect(lineAmounts(line({ account_id: "a", debit: "125.50" }), 2)).toEqual({
      debit_minor: 12550,
      credit_minor: 0,
      problem: null,
    });
    expect(lineAmounts(line({ account_id: "a", credit: "1.005" }), 2).credit_minor).toBe(101);
    expect(lineAmounts(line({ account_id: "a", debit: "125" }), 0).debit_minor).toBe(125);
  });

  test("says what stops it, first thing first", () => {
    expect(lineAmounts(line({ account_id: "a", debit: "ten" }), 2).problem).toBe("unreadable");
    expect(lineAmounts(line({ account_id: "a", debit: "-5" }), 2).problem).toBe("negative");
    expect(lineAmounts(line({ account_id: "a", debit: "5", credit: "5" }), 2).problem).toBe("both");
    expect(lineAmounts(line({ account_id: "a", debit: "0" }), 2).problem).toBe("amount");
    expect(lineAmounts(line({ debit: "5" }), 2).problem).toBe("account");
  });
});

describe("the totals under the editor", () => {
  test("a journal balances when two lines or more have equal debits and credits", () => {
    const totals = journalTotals(
      [
        line({ account_id: "exp", debit: "125.00" }),
        line({ account_id: "acc", credit: "100" }),
        line({ account_id: "acc", credit: "25" }),
        emptyLine(),
      ],
      2,
    );
    expect(totals).toEqual({
      debit_minor: 12500,
      credit_minor: 12500,
      difference_minor: 0,
      lines: 3,
      problems: 0,
      complete: true,
      balanced: true,
    });
  });

  test("an unbalanced journal is complete and not balanced, and says by how much", () => {
    const totals = journalTotals(
      [line({ account_id: "exp", debit: "125" }), line({ account_id: "acc", credit: "120" })],
      2,
    );
    expect(totals.complete).toBe(true);
    expect(totals.balanced).toBe(false);
    expect(totals.difference_minor).toBe(500);
  });

  test("a line that cannot be sent keeps Submit waiting even when the sums agree", () => {
    const totals = journalTotals(
      [line({ account_id: "exp", debit: "10" }), line({ credit: "10" })],
      2,
    );
    expect(totals.debit_minor).toBe(totals.credit_minor);
    expect(totals.problems).toBe(1);
    expect(totals.balanced).toBe(false);
  });

  test("nothing typed is neither complete nor balanced", () => {
    const totals = journalTotals([emptyLine(), emptyLine()], 2);
    expect(totals.lines).toBe(0);
    expect(totals.complete).toBe(false);
    expect(totals.balanced).toBe(false);
  });

  test("one line cannot balance", () => {
    expect(journalTotals([line({ account_id: "a", debit: "0.01" })], 2).balanced).toBe(false);
  });
});

describe("the lines the door takes", () => {
  test("blank lines are left out, one side is sent, and a cost centre is analysis", () => {
    expect(
      journalLinesArg(
        [
          line({
            account_id: " exp ",
            debit: "125.00",
            description: " Electricity ",
            cost_centre: "LEE-WH",
          }),
          emptyLine(),
          line({ account_id: "acc", credit: "125" }),
        ],
        2,
      ),
    ).toEqual([
      {
        account_id: "exp",
        debit_minor: 12500,
        description: "Electricity",
        dimensions: { [COST_CENTRE]: "LEE-WH" },
      },
      { account_id: "acc", credit_minor: 12500 },
    ]);
  });
});

describe("a saved journal back in the editor", () => {
  test("minor units become what a person types, and zero is left empty", () => {
    expect(minorToInput(12550, 2)).toBe("125.50");
    expect(minorToInput(0, 2)).toBe("");
    expect(minorToInput(125, 0)).toBe("125");
  });

  test("its lines round-trip through the editor unchanged", () => {
    const journal = {
      lines: [
        {
          line_no: 1,
          account_id: "exp",
          account_code: "7100",
          account_name: "Light and heat",
          debit_minor: 12550,
          credit_minor: 0,
          description: "Electricity",
          dimensions: { [COST_CENTRE]: "LEE-WH" },
        },
        {
          line_no: 2,
          account_id: "acc",
          account_code: "2300",
          account_name: "Accruals",
          debit_minor: 0,
          credit_minor: 12550,
          description: null,
          dimensions: {},
        },
      ],
    };
    const drafted = draftLinesOf(journal, 2);
    expect(drafted[1]).toEqual({
      account_id: "acc",
      description: "",
      debit: "",
      credit: "125.50",
      cost_centre: "",
    });
    expect(journalLinesArg(drafted, 2)).toEqual([
      {
        account_id: "exp",
        debit_minor: 12550,
        description: "Electricity",
        dimensions: { [COST_CENTRE]: "LEE-WH" },
      },
      { account_id: "acc", credit_minor: 12550 },
    ]);
  });
});

describe("reading the list", () => {
  test("keeps rows that are journals in a known state", () => {
    const rows = readJournals([
      { journal_id: "j1", state: "posted" },
      { journal_id: "j2", state: "archived" },
      { state: "draft" },
      null,
      "j3",
    ]);
    expect(rows.map((r) => r.journal_id)).toEqual(["j1"]);
    expect(readJournals({ journals: [] })).toEqual([]);
  });

  test("names, words and tones", () => {
    expect(
      journalName({ journal_number: "GL-000012", reference: "ACC", posting_date: "2026-09-30" }),
    ).toBe("GL-000012");
    expect(journalName({ journal_number: null, reference: null, posting_date: "2026-09-30" })).toBe(
      "2026-09-30",
    );
    expect(stateLabel("submitted")).toBe("Waiting for approval");
    expect(stateTone("returned")).toBe("bad");
    expect(stateTone("posted")).toBe("ok");
  });
});
