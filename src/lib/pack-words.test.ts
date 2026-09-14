import { describe, expect, test } from "bun:test";

import { decisionLabel, featureName, packConflictWords } from "./pack-words";

const TITLES = { batch_control: "Batch control", expiry_dates: "Expiry dates" };

describe("featureName", () => {
  test("takes the title the Features screen shows", () => {
    expect(featureName("batch_control", TITLES)).toBe("Batch control");
  });

  test("falls back to the code as words, never the code", () => {
    expect(featureName("serial_numbers", TITLES)).toBe("Serial numbers");
  });
});

describe("packConflictWords", () => {
  test("says what is held back by the feature's name", () => {
    expect(
      packConflictWords(
        "3 item(s) are held back because the batch_control capability is off",
        TITLES,
      ),
    ).toBe("3 items are held back because Batch control is switched off");
  });

  test("counts one item as one", () => {
    expect(
      packConflictWords(
        "1 item(s) are held back because the expiry_dates capability is off",
        TITLES,
      ),
    ).toBe("1 item is held back because Expiry dates is switched off");
  });

  test("names a feature it has no title for in words", () => {
    expect(
      packConflictWords("2 item(s) are held back because the serial_numbers capability is off", {}),
    ).toBe("2 items are held back because Serial numbers is switched off");
  });

  test("rewrites the engine's words inside the other sentences", () => {
    expect(
      packConflictWords(
        "report(s) STOCK_AGE are held back because the stock_value KPI they name comes with the batch_control capability, which is off",
        TITLES,
      ),
    ).toBe(
      "reports STOCK_AGE are held back because the stock_value KPI they name comes with the Batch control feature, which is off",
    );
    expect(
      packConflictWords(
        "this pack needs the batch_control capability, which is off for this organisation",
        TITLES,
      ),
    ).toBe("this pack needs the Batch control feature, which is off for this organisation");
  });

  test("leaves a sentence with nothing to rewrite as it was", () => {
    expect(packConflictWords("account 4000 already exists as 'Sales'", TITLES)).toBe(
      "account 4000 already exists as 'Sales'",
    );
  });
});

describe("decisionLabel", () => {
  test("names an approval band by department, document and number", () => {
    expect(decisionLabel("approval_band", "FIN|invoice_reference|1")).toBe(
      "Finance: supplier invoices, approval band 1",
    );
    expect(decisionLabel("approval_band", "PROC|requisition|3")).toBe(
      "Procurement: requisitions, approval band 3",
    );
    expect(decisionLabel("approval_band", "SALES|sales_order|2")).toBe(
      "Sales: sales orders held on credit, approval band 2",
    );
  });

  test("keeps an unknown department's code and words an unknown document", () => {
    expect(decisionLabel("approval_band", "ZZ|goods_return|1")).toBe(
      "ZZ: goods return, approval band 1",
    );
  });

  test("shows a key of another shape as its parts in words, never the raw key", () => {
    expect(decisionLabel("calendar", "UK|two_shift")).toBe("UK, Two shift");
    expect(decisionLabel("approval_band", "")).toBe("Approval band");
  });
});
