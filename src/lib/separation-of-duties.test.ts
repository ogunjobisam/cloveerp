import { describe, expect, test } from "bun:test";

import { ErpError } from "./erp";
import {
  awaitsDecision,
  EXCEPTION_REASON_MIN,
  exceptionReasonProblem,
  isProhibitedPairing,
  readDutiesReport,
  toReview,
  type SettledConflict,
} from "./separation-of-duties";

function settled(over: Partial<SettledConflict> & { rule_code: string }): SettledConflict {
  return {
    rule_name: over.rule_code,
    severity: "material",
    permissions_a: ["inventory.adjust"],
    permissions_b: ["inventory.write_off"],
    status: "open",
    exception_reason: null,
    ...over,
  };
}

describe("the refusal that offers an exception", () => {
  test("a prohibited pairing is recognised by its token", () => {
    const refused = new ErpError(
      'CLOVEERP_SOD_PROHIBITED: Poppy Poster cannot be given the Poster role, because they would hold both "Post journals" and "Close periods"',
      { code: "23514", hint: "Give the Poster role to somebody else." },
    );
    expect(isProhibitedPairing(refused)).toBe(true);
  });

  test("changing your own roles, a missing permission and plain errors are not", () => {
    expect(
      isProhibitedPairing(
        new ErpError("CLOVEERP_SOD_SELF_GRANT: you cannot change your own roles", {
          code: "42501",
        }),
      ),
    ).toBe(false);
    expect(
      isProhibitedPairing(
        new ErpError("CLOVEERP_PERMISSION_DENIED: administration.promote", { code: "42501" }),
      ),
    ).toBe(false);
    expect(isProhibitedPairing(new Error("CLOVEERP_SOD_PROHIBITED: not from the database"))).toBe(
      false,
    );
    expect(isProhibitedPairing(null)).toBe(false);
  });
});

describe("the reason for an exception", () => {
  test("nothing, or only spaces, is no reason", () => {
    expect(exceptionReasonProblem("")).toBe("empty");
    expect(exceptionReasonProblem("    ")).toBe("empty");
  });

  test("fewer characters than the database accepts is too short, counting what is typed", () => {
    expect(exceptionReasonProblem("ok by me")).toBe("short");
    expect(exceptionReasonProblem(`  ${"x".repeat(EXCEPTION_REASON_MIN - 1)}  `)).toBe("short");
  });

  test("twenty characters will do", () => {
    expect(exceptionReasonProblem("x".repeat(EXCEPTION_REASON_MIN))).toBeNull();
    expect(
      exceptionReasonProblem("Two-person office until October; the partner reviews every close."),
    ).toBeNull();
  });
});

describe("what waits on a decision", () => {
  test("recorded or not, a conflict with no exception waits; an exception does not", () => {
    expect(awaitsDecision({ status: "unrecorded" })).toBe(true);
    expect(awaitsDecision({ status: "open" })).toBe(true);
    expect(awaitsDecision({ status: "accepted" })).toBe(false);
    expect(awaitsDecision({ status: "mitigated" })).toBe(false);
  });

  test("a grant door's answer lists only the open conflicts to review", () => {
    const answer = [
      settled({ rule_code: "ADJUST_APPROVE_STOCK" }),
      settled({
        rule_code: "POST_CLOSE",
        severity: "prohibited",
        status: "accepted",
        exception_reason: "Two-person office until October.",
      }),
    ];
    expect(toReview(answer).map((c) => c.rule_code)).toEqual(["ADJUST_APPROVE_STOCK"]);
    expect(toReview(undefined)).toEqual([]);
    expect(toReview(null)).toEqual([]);
    expect(toReview({})).toEqual([]);
  });
});

describe("reading the conflicts door", () => {
  test("its answer is read as it comes", () => {
    const report = readDutiesReport({
      is_live: true,
      rules: 8,
      conflicts: [{ app_user_id: "p", rule_code: "POST_CLOSE", status: "accepted" }],
      administrators: [{ app_user_id: "a", person: "Ada Admin" }],
    });
    expect(report.is_live).toBe(true);
    expect(report.rules).toBe(8);
    expect(report.conflicts.map((c) => c.rule_code)).toEqual(["POST_CLOSE"]);
    expect(report.administrators.map((a) => a.person)).toEqual(["Ada Admin"]);
  });

  test("an empty or malformed answer is an organisation with no rules, not a throw", () => {
    for (const raw of [[], null, undefined, "nonsense", { rules: "8", conflicts: {} }]) {
      expect(readDutiesReport(raw)).toEqual({
        is_live: false,
        rules: 0,
        conflicts: [],
        administrators: [],
      });
    }
  });
});
