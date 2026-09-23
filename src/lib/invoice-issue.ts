import { ErpError } from "./erp";

/**
 * A sales invoice's legal issue, as its page reads it.
 *
 * Issuing reserves the invoice's permanent number, renders the PDF from the
 * frozen contract, files it and completes the number; a reprint hands back the
 * file that was filed (src/lib/document-output.functions.ts). The database
 * decides each step under document.issue and document.reprint. Pure: no React,
 * no Supabase client.
 */

export type IssueStatus = "reserved" | "issued" | "sent" | "voided" | "failed" | string;

export type DocumentIssue = {
  document_issue_id: string;
  issued_number: string | null;
  status: IssueStatus;
  issued_at: string | null;
  sent_at: string | null;
  voided_at: string | null;
};

export type IssueReadiness = {
  can_issue: boolean;
  missing: { field: string; refusal: string }[];
};

/** What `erp_document_issues` returned, keeping only what reads as an issue. */
export function readIssues(data: unknown): DocumentIssue[] {
  if (!Array.isArray(data)) return [];
  return data.filter(
    (row): row is DocumentIssue =>
      typeof row === "object" &&
      row !== null &&
      typeof (row as Record<string, unknown>)["document_issue_id"] === "string",
  );
}

/** The issue that holds the invoice's number, if one does: reserved, issued or sent. */
export function currentIssue(issues: DocumentIssue[]): DocumentIssue | null {
  return issues.find((i) => ["reserved", "issued", "sent"].includes(String(i.status))) ?? null;
}

/** Whether an issue has a filed PDF to hand back. */
export function canReprint(issue: DocumentIssue | null): boolean {
  return issue !== null && (issue.status === "issued" || issue.status === "sent");
}

/** What `erp_sales_invoice_issue_readiness` returned. Nothing readable is not ready. */
export function readReadiness(data: unknown): IssueReadiness {
  if (typeof data !== "object" || data === null) return { can_issue: false, missing: [] };
  const raw = data as Record<string, unknown>;
  const missing = Array.isArray(raw["missing"])
    ? (raw["missing"] as unknown[]).flatMap((m) => {
        if (typeof m !== "object" || m === null) return [];
        const r = m as Record<string, unknown>;
        return typeof r["field"] === "string"
          ? [{ field: r["field"], refusal: typeof r["refusal"] === "string" ? r["refusal"] : "" }]
          : [];
      })
    : [];
  return { can_issue: raw["can_issue"] === true, missing };
}

/** The refusal an invoice with no tax point of its own is held on. */
export const TAX_POINT_MISSING = "CLOVEERP_INVOICE_TAX_POINT_MISSING";

/** Whether the press has to state the tax point before it issues. */
export function needsTaxPoint(ready: IssueReadiness): boolean {
  return ready.missing.some((m) => m.refusal === TAX_POINT_MISSING);
}

/**
 * Whether one press can issue the invoice: nothing is missing, or only the tax
 * point, which the press states before it issues (20260923500000).
 */
export function issuableInOnePress(ready: IssueReadiness): boolean {
  return (
    ready.can_issue ||
    (ready.missing.length > 0 && ready.missing.every((m) => m.refusal === TAX_POINT_MISSING))
  );
}

/**
 * A failure from the issue path, as a refusal the desk can word.
 *
 * The server function keeps the database's token at the front of its message
 * but arrives as a plain Error, so the register's wording was never looked up.
 */
export function issueFailure(error: unknown): unknown {
  if (error instanceof ErpError || !(error instanceof Error)) return error;
  return new ErpError(error.message, {});
}
