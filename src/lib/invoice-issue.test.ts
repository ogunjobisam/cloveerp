import { describe, expect, test } from "bun:test";

import { ErpError } from "./erp";
import {
  canReprint,
  currentIssue,
  issuableInOnePress,
  issueFailure,
  needsTaxPoint,
  readIssues,
  readReadiness,
} from "./invoice-issue";

const issue = (status: string, id = status) => ({
  document_issue_id: id,
  issued_number: status === "voided" ? "INV-1" : "INV-2",
  status,
  issued_at: "2026-09-14T10:00:00Z",
  sent_at: null,
  voided_at: null,
});

describe("the issues of an invoice", () => {
  test("keeps rows that are issues", () => {
    expect(readIssues([issue("issued"), { status: "issued" }, null]).length).toBe(1);
    expect(readIssues(null)).toEqual([]);
  });

  test("the number an invoice holds is its reserved, issued or sent issue, never a voided one", () => {
    expect(currentIssue([issue("voided"), issue("issued")])?.status).toBe("issued");
    expect(currentIssue([issue("voided"), issue("failed")])).toBeNull();
    expect(currentIssue([issue("reserved")])?.status).toBe("reserved");
  });

  test("only a filed issue is reprinted", () => {
    expect(canReprint(issue("issued"))).toBe(true);
    expect(canReprint(issue("sent"))).toBe(true);
    expect(canReprint(issue("reserved"))).toBe(false);
    expect(canReprint(null)).toBe(false);
  });
});

describe("whether an invoice can be issued", () => {
  test("reads what is missing", () => {
    expect(
      readReadiness({
        can_issue: false,
        missing: [
          { field: "Tax point", refusal: "CLOVEERP_INVOICE_TAX_POINT_MISSING" },
          { refusal: "no field" },
        ],
      }),
    ).toEqual({
      can_issue: false,
      missing: [{ field: "Tax point", refusal: "CLOVEERP_INVOICE_TAX_POINT_MISSING" }],
    });
  });

  test("nothing readable is not ready", () => {
    expect(readReadiness(undefined)).toEqual({ can_issue: false, missing: [] });
    expect(readReadiness({ can_issue: "yes" }).can_issue).toBe(false);
  });
});

describe("issuing in one press", () => {
  const taxPoint = { field: "Tax point", refusal: "CLOVEERP_INVOICE_TAX_POINT_MISSING" };
  const address = {
    field: "Customer invoice address",
    refusal: "CLOVEERP_CUSTOMER_ADDRESS_MISSING",
  };

  test("a missing tax point is stated by the press, so it does not hold the invoice", () => {
    const ready = { can_issue: false, missing: [taxPoint] };
    expect(needsTaxPoint(ready)).toBe(true);
    expect(issuableInOnePress(ready)).toBe(true);
  });

  test("anything else missing still holds it", () => {
    const ready = { can_issue: false, missing: [taxPoint, address] };
    expect(needsTaxPoint(ready)).toBe(true);
    expect(issuableInOnePress(ready)).toBe(false);
  });

  test("a complete invoice issues and is asked for nothing", () => {
    const ready = { can_issue: true, missing: [] };
    expect(needsTaxPoint(ready)).toBe(false);
    expect(issuableInOnePress(ready)).toBe(true);
    expect(issuableInOnePress({ can_issue: false, missing: [] })).toBe(false);
  });
});

describe("a failure on the issue path", () => {
  test("keeps the database's token, so the register words it", () => {
    const failed = issueFailure(
      new Error("CLOVEERP_ALREADY_ISSUED: this invoice already carries an issued number"),
    );
    expect(failed).toBeInstanceOf(ErpError);
    expect((failed as ErpError).erpCode).toBe("CLOVEERP_ALREADY_ISSUED");
  });

  test("an ErpError and a non-error pass through", () => {
    const erp = new ErpError("CLOVEERP_PERMISSION_DENIED: document.issue", { code: "42501" });
    expect(issueFailure(erp)).toBe(erp);
    expect(issueFailure("offline")).toBe("offline");
  });
});
