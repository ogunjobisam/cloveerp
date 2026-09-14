import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";

import { documentOutput, type DocumentOutputResult } from "../../lib/document-output.functions";
import { callErp, hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import {
  canReprint,
  currentIssue,
  issueFailure,
  readIssues,
  readReadiness,
} from "../../lib/invoice-issue";
import { ActionButton, ErrorNote } from "./action";
import { Prose } from "./page";
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
export function InvoiceIssue({ documentId }: { documentId: string }) {
  const { ui } = useT();
  const { session } = useErpSession();
  const queryClient = useQueryClient();
  const [opened, setOpened] = useState<DocumentOutputResult | null>(null);

  const mayRead = hasPermission(session, "sales.read");
  const mayIssue = hasPermission(session, "document.issue");
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

  const issue = useMutation({
    mutationFn: async () => {
      try {
        return await documentOutput({ data: { action: "issue", documentId } });
      } catch (error) {
        throw issueFailure(error);
      }
    },
    onSuccess: (result) => {
      setOpened(result);
      void queryClient.invalidateQueries({ queryKey: ["erp_document_issues"] });
    },
  });

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
            <ActionButton
              busy={issue.isPending}
              disabled={readiness.isPending || !ready.can_issue}
              onClick={() => issue.mutate()}
            >
              {ui("Issue the invoice")}
            </ActionButton>
            {!readiness.isPending && !ready.can_issue && ready.missing.length > 0 ? (
              <span className="text-xs text-muted-foreground">
                {ui("Before it is issued, this invoice needs:")}{" "}
                {ready.missing.map((m) => m.field).join(", ")}
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
