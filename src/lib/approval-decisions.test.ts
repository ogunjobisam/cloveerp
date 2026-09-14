import { describe, expect, test } from "bun:test";

import {
  anyAdministratorDecision,
  decisionWords,
  type ApprovalDecision,
} from "./approval-decisions";
import { INTERNAL_WORDING } from "./plain-words";

const base: ApprovalDecision = {
  task_id: "t1",
  request_id: "q1",
  request_status: "approved",
  requested_at: "2026-09-14T09:00:00Z",
  requested_by: "Ada Lovelace",
  step: "Purchasing",
  status: "approved",
  assignee: "Sam Carter",
  assignee_role: "Purchasing",
  decided_by: "Sam Carter",
  decided_at: "2026-09-14T10:00:00Z",
  decided_via: "desk",
  own_request: false,
  comment: null,
};

describe("a document's approval decisions, in words", () => {
  test("a decision at the desk names who made it", () => {
    expect(decisionWords(base)).toBe("Approved by Sam Carter");
    expect(decisionWords({ ...base, status: "rejected" })).toBe("Rejected by Sam Carter");
  });

  test("an administrator deciding for the person asked says so and names them", () => {
    expect(
      decisionWords({ ...base, decided_by: "Ada Lovelace", decided_via: "administrator" }),
    ).toBe("Approved by Ada Lovelace as administrator, for Sam Carter");
  });

  test("an administrator approving their own request says that instead", () => {
    expect(
      decisionWords({
        ...base,
        assignee: "Ada Lovelace",
        decided_by: "Ada Lovelace",
        decided_via: "administrator",
        own_request: true,
      }),
    ).toBe("Approved by Ada Lovelace as administrator, on their own request");
  });

  test("from an email, waiting, and the rest", () => {
    expect(decisionWords({ ...base, decided_via: "email" })).toBe(
      "Approved by Sam Carter from an approval email",
    );
    expect(decisionWords({ ...base, status: "pending", decided_by: null })).toBe(
      "Waiting on Sam Carter",
    );
    expect(decisionWords({ ...base, status: "pending", assignee: null })).toBe(
      "Waiting on Purchasing",
    );
    expect(decisionWords({ ...base, status: "pending", assignee: null, assignee_role: null })).toBe(
      "Waiting on the approving role",
    );
    expect(decisionWords({ ...base, status: "cancelled" })).toBe("No longer needed");
    expect(decisionWords({ ...base, status: "delegated" })).toBe("Delegated by Sam Carter");
  });

  test("says nothing written for the people who build the product", () => {
    for (const d of [
      base,
      { ...base, decided_via: "administrator" as const, decided_by: "Ada Lovelace" },
      { ...base, status: "pending" },
    ]) {
      for (const pattern of INTERNAL_WORDING) expect(pattern.test(decisionWords(d))).toBe(false);
    }
  });

  test("knows when an administrator decided anything", () => {
    expect(anyAdministratorDecision([base])).toBe(false);
    expect(anyAdministratorDecision([base, { ...base, decided_via: "administrator" }])).toBe(true);
  });
});
