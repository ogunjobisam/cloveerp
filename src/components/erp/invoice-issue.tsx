import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";

import { documentOutput, type DocumentOutputResult } from "../../lib/document-output.functions";
import { callErp, hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import {
  canReprint,
  currentIssue,
  issuableInOnePress,
  issueFailure,
  needsTaxPoint,
  readIssues,
  readReadiness,
} from "../../lib/invoice-issue";
import { ActionButton, ErrorNote } from "./action";
import { Prose, TOUCH } from "./page";
import { Pill } from "./panel";
import { useErpSession } from "./session-context";

/**
 * Issuing a sales invoice: its permanent number and the PDF the customer gets.
 *
 * The numbered issue path reserves the number and freezes the invoice, renders
 * the PDF from what was frozen, files it and completes the number
 * (src/lib/document-output.functions.ts), each step decided by the database
 * under document.issue. A reprint hands back the file that was filed, under
 * document.reprint, and renders nothing. Hiding either button only saves
 * somebody a refusal.
 */
export function InvoiceIssue({ documentId, draft }: { documentId: string; draft: boolean }) {
  const { ui } = useT();
  const { session } = useErpSession();
  const queryClient = useQueryClient();
  const [opened, setOpened] = useState<DocumentOutputResult | null>(null);

  const mayRead = hasPermission(session, "sales.read");
  // A draft is moved to Issued by the same press, which is the lifecycle's
  // own move and asks for its permission too (20260923500000).
  const mayIssue =
    hasPermission(session, "document.issue") && (!draft || hasPermission(session, "sales.invoice"));
  const mayReprint = hasPermission(session, "document.reprint");

  const issues = useQuery({
    queryKey: ["erp_document_issues", { p_document_id: documentId, p_limit: 20 }],
    queryFn: () =>
      callErp<unknown>("erp_document_issues", { p_document_id: documentId, p_limit: 20 }),
    enabled: mayRead,
  });
  const current = currentIssue(readIssues(issues.data));

  const readiness = useQuery({
    queryKey: ["erp_sales_invoice_issue_readiness", { p_document_id: documentId }],
    queryFn: () =>
      callErp<unknown>("erp_sales_invoice_issue_readiness", { p_document_id: documentId }),
    enabled: mayRead && mayIssue && current === null,
  });
  const ready = readReadiness(readiness.data);
  const askTaxPoint = needsTaxPoint(ready);
  // The date of the invoice, which is the tax point when it is issued within
  // fourteen days of the supply. The person changes it when it is not.
  const [taxPoint, setTaxPoint] = useState(() => new Date().toLocaleDateString("en-CA"));

  // One press (20260923500000): the tax point it states, then the issue, which
  // moves a draft to Issued and posts it before it numbers it and files the PDF.
  const issue = useMutation({
    mutationFn: async () => {
      try {
        if (askTaxPoint)
          await callErp<unknown>("erp_set_invoice_tax_point", {
            p_document_id: documentId,
            p_tax_point: taxPoint,
          });
        return await documentOutput({ data: { action: "issue", documentId } });
      } catch (error) {
        throw issueFailure(error);
      }
    },
    onSuccess: (result) => {
      setOpened(result);
      for (const key of [
        "erp_document_issues",
        "erp_sales_invoice_issue_readiness",
        "erp_document",
        "erp_documents",
        "erp_available_transitions",
      ])
        void queryClient.invalidateQueries({ queryKey: [key] });
    },
    onError: () => {
      void queryClient.invalidateQueries({ queryKey: ["erp_sales_invoice_issue_readiness"] });
    },
  });
  const blocking = ready.missing.filter((m) => m.refusal !== "CLOVEERP_INVOICE_TAX_POINT_MISSING");

  const reprint = useMutation({
    mutationFn: async (documentIssueId: string) => {
      try {
        return await documentOutput({ data: { action: "reprint", documentIssueId } });
      } catch (error) {
        throw issueFailure(error);
      }
    },
    onSuccess: (result) => setOpened(result),
  });

  if (!mayRead) return null;

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5">
      <h2 className="text-sm font-semibold">{ui("Legal invoice")}</h2>
      <Prose className="mt-0.5 text-xs text-muted-foreground">
        {ui(
          "Issuing gives the invoice its permanent number and files the PDF the customer receives. A reprint hands back the same file; nothing is rendered again.",
        )}
      </Prose>

      <div className="mt-3 flex flex-wrap items-center gap-3">
        {current ? (
          <>
            <span className="text-sm">
              {ui("Issued as")} <span className="font-mono">{current.issued_number ?? "—"}</span>
            </span>
            <Pill tone={current.status === "reserved" ? "warn" : "ok"}>{current.status}</Pill>
            {canReprint(current) && mayReprint ? (
              <ActionButton
                variant="secondary"
                busy={reprint.isPending}
                onClick={() => reprint.mutate(current.document_issue_id)}
              >
                {ui("Reprint")}
              </ActionButton>
            ) : null}
            {current.status === "reserved" ? (
              <span className="text-xs text-muted-foreground">
                {ui("The number is held, but the PDF was not filed. Nothing has been sent.")}
              </span>
            ) : null}
          </>
        ) : mayIssue ? (
          <>
            {!readiness.isPending && askTaxPoint ? (
              <label className="flex items-center gap-2 text-sm">
                <span>{ui("Tax point")}</span>
                <input
                  type="date"
                  value={taxPoint}
                  onChange={(e) => setTaxPoint(e.target.value)}
                  className={`${TOUCH} rounded-md border border-input bg-background px-2 text-sm`}
                />
              </label>
            ) : null}
            <ActionButton
              busy={issue.isPending}
              disabled={
                readiness.isPending ||
                !issuableInOnePress(ready) ||
                (askTaxPoint && taxPoint === "")
              }
              onClick={() => issue.mutate()}
            >
              {ui("Issue the invoice")}
            </ActionButton>
            {!readiness.isPending && blocking.length > 0 ? (
              <span className="text-xs text-muted-foreground">
                {ui("Before it is issued, this invoice needs:")}{" "}
                {blocking.map((m) => m.field).join(", ")}
              </span>
            ) : null}
          </>
        ) : (
          <span className="text-xs text-muted-foreground">{ui("Not issued yet.")}</span>
        )}
      </div>

      {opened?.signedUrl ? (
        <p className="mt-3 text-sm">
          <a
            href={opened.signedUrl}
            target="_blank"
            rel="noreferrer"
            className="font-medium underline underline-offset-2"
          >
            {ui("Open the PDF")}
          </a>{" "}
          <span className="text-xs text-muted-foreground">
            {opened.issuedNumber ?? ""} · {ui("The link lasts five minutes.")}
          </span>
        </p>
      ) : null}

      <div className="mt-3">
        <ErrorNote error={issues.error ?? readiness.error ?? issue.error ?? reprint.error} />
      </div>
    </section>
  );
}
