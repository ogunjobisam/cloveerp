import { describe, expect, test } from "bun:test";

import {
  amendmentChanges,
  describeChanges,
  describeTermination,
  describeUplift,
  EMPTY_AMENDMENT,
} from "./contract-terms";

describe("an amendment built from the form", () => {
  test("sends only what was filled in", () => {
    const built = amendmentChanges({
      ...EMPTY_AMENDMENT,
      annualValue: "24000",
      entitlements: [
        { code: "users", limit: "500" },
        { code: "", limit: "9" },
      ],
      capabilities: [{ code: "serialisation", action: "remove" }],
    });
    // The very amendment erp.amend_contract's own suite drafts.
    expect(built).toEqual({
      ok: true,
      changes: {
        annual_value_minor: 2_400_000,
        entitlements: [{ code: "users", limit_value: 500 }],
        capabilities: [{ code: "serialisation", action: "remove" }],
      },
    });
  });

  test("a blank limit is unlimited", () => {
    const built = amendmentChanges({
      ...EMPTY_AMENDMENT,
      entitlements: [{ code: "sites", limit: "" }],
    });
    expect(built).toEqual({
      ok: true,
      changes: { entitlements: [{ code: "sites", limit_value: null }] },
    });
  });

  test("every key the writer accepts can be set", () => {
    const built = amendmentChanges({
      ...EMPTY_AMENDMENT,
      planCode: "standard",
      termEnd: "2027-12-31",
      renewalKind: "by_agreement",
      noticeDays: "60",
      upliftKind: "capped",
      upliftIndex: "cpi",
      upliftCap: "4",
      supportSeverity: "priority",
    });
    expect(built).toEqual({
      ok: true,
      changes: {
        plan_code: "standard",
        term_end: "2027-12-31",
        renewal_kind: "by_agreement",
        notice_days: 60,
        uplift_rule: { kind: "capped", index_code: "CPI", cap_pct: 4 },
        support_severity_code: "priority",
      },
    });
  });

  test("an amendment that changes nothing is stopped before the door refuses it", () => {
    expect(amendmentChanges(EMPTY_AMENDMENT).ok).toBe(false);
  });

  test("says what is wrong rather than sending it", () => {
    expect(amendmentChanges({ ...EMPTY_AMENDMENT, annualValue: "lots" })).toMatchObject({
      ok: false,
    });
    expect(amendmentChanges({ ...EMPTY_AMENDMENT, noticeDays: "2.5" })).toMatchObject({
      ok: false,
    });
    expect(amendmentChanges({ ...EMPTY_AMENDMENT, upliftKind: "fixed_pct" })).toMatchObject({
      ok: false,
    });
    expect(amendmentChanges({ ...EMPTY_AMENDMENT, upliftKind: "index" })).toMatchObject({
      ok: false,
    });
    expect(
      amendmentChanges({ ...EMPTY_AMENDMENT, entitlements: [{ code: "users", limit: "many" }] }),
    ).toMatchObject({ ok: false });
  });

  test("no uplift is a change of its own", () => {
    expect(amendmentChanges({ ...EMPTY_AMENDMENT, upliftKind: "none" })).toEqual({
      ok: true,
      changes: { uplift_rule: { kind: "none" } },
    });
  });
});

describe("terms in words", () => {
  test("uplift", () => {
    expect(describeUplift({ kind: "none" })).toBe("No uplift");
    expect(describeUplift({})).toBe("No uplift");
    expect(describeUplift({ kind: "fixed_pct", pct: 5 })).toBe("Rises by 5% at each renewal");
    expect(describeUplift({ kind: "index", index_code: "CPI" })).toBe(
      "Rises in line with CPI at each renewal",
    );
    expect(describeUplift({ kind: "capped", index_code: "RPI", cap_pct: 4 })).toBe(
      "Rises in line with RPI at each renewal, capped at 4%",
    );
  });

  test("termination, with nothing left as JSON", () => {
    expect(
      describeTermination({
        rights: "either party for material breach",
        exit_assistance_days: 90,
        data_return: "full export in open formats before deletion",
        survives: true,
      }),
    ).toEqual([
      "Termination rights: either party for material breach",
      "90 days of exit assistance",
      "Data return: full export in open formats before deletion",
      "Survives: yes",
    ]);
    expect(describeTermination({})).toEqual(["No termination terms recorded"]);
    expect(describeTermination({ rights: null, exit_assistance_days: 0 })).toEqual([
      "No termination terms recorded",
    ]);
  });

  test("an amendment's changes", () => {
    expect(
      describeChanges(
        {
          entitlements: [{ code: "users", limit_value: 500 }],
          capabilities: [{ code: "serialisation", action: "remove" }],
          annual_value_minor: 2_400_000,
        },
        (minor) => `${minor / 100} GBP`,
      ),
    ).toEqual([
      "Annual value becomes 24000 GBP",
      "users limit becomes 500",
      "Feature serialisation withdrawn",
    ]);
  });
});
