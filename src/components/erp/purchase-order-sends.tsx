import { useQuery } from "@tanstack/react-query";
import { useState } from "react";

import { callErp, hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { purchaseOrderSends, type SendStatus } from "../../lib/purchase-order-send";
import { ActionButton, ActionDialog, ErrorNote, type Field } from "./action";
import { Prose } from "./page";
import { Pill } from "./panel";
import { useErpSession } from "./session-context";

/**
 * A purchase order on its way to its supplier (20261004920000).
 *
 * Send to supplier emails the order with its PDF attached, through
 * public.erp_send_purchase_order: an approved order moves to Sent by the same
 * press, and replies go to the buyer. It is offered where
 * public.erp_purchase_order_sends says the reader may send, and asks why only
 * when the order has gone already. Download PDF draws the same document from
 * the order as it reads now, for sending by hand. Every send is listed with how
 * far it got: queued, sent, delivered, or bounced and why.
 */

const INVALIDATES = [
  "erp_purchase_order_sends",
  "erp_document",
  "erp_documents",
  "erp_available_transitions",
];

const TONE: Record<SendStatus, "ok" | "warn" | "bad" | "muted"> = {
  queued: "muted",
  sending: "muted",
  sent: "ok",
  delivered: "ok",
  opened: "ok",
  bounced: "bad",
  failed: "bad",
};

async function downloadPurchaseOrder(documentId: string): Promise<void> {
  const payload = await callErp<unknown>("erp_purchase_order_document", { p_order: documentId });
  const { renderPurchaseOrderPdf, purchaseOrderFilename } =
    await import("../../lib/pdf/purchase-order-pdf");
  const bytes = await renderPurchaseOrderPdf(payload);
  const url = URL.createObjectURL(
    new Blob([bytes as unknown as BlobPart], { type: "application/pdf" }),
  );
  const a = document.createElement("a");
  a.href = url;
  a.download = purchaseOrderFilename(payload);
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 10_000);
}

export function PurchaseOrderSends({
  documentId,
  context,
}: {
  documentId: string;
  context: string;
}) {
  const { ui } = useT();
  const { session } = useErpSession();
  const [downloading, setDownloading] = useState(false);
  const [downloadError, setDownloadError] = useState<unknown>(null);
  const mayRead = hasPermission(session, "procurement.read");
  const { data, error } = useQuery({
    queryKey: ["erp_purchase_order_sends", { p_order: documentId }],
    queryFn: () => callErp<unknown>("erp_purchase_order_sends", { p_order: documentId }),
    enabled: mayRead,
  });
  const sends = purchaseOrderSends(data);
  if (!mayRead) return null;
  if (error) return <ErrorNote error={error} />;
  if (!sends) return null;

  const word: Record<SendStatus, string> = {
    queued: ui("queued"),
    sending: ui("sending"),
    sent: ui("sent"),
    delivered: ui("delivered"),
    opened: ui("opened"),
    bounced: ui("bounced"),
    failed: ui("failed"),
  };

  const fields: Field[] = [
    {
      kind: "text",
      name: "p_to",
      label: "To",
      required: true,
      placeholder: "orders@supplier.example",
      ...(sends.defaultTo ? { default: sends.defaultTo } : {}),
    },
    {
      kind: "text",
      name: "p_cc",
      label: "Copy to",
      hint: "Separate addresses with commas.",
    },
    {
      kind: "text",
      name: "p_message",
      label: "Message",
      placeholder: "Please confirm the delivery date.",
      hint: "Optional. Shown above the order in the email.",
    },
    ...(sends.needsReason
      ? ([
          {
            kind: "text",
            name: "p_reason",
            label: "Why it is going again",
            required: true,
            placeholder: "Changed quantities on line 2",
            hint: "Required for a second send. It travels with the order.",
          },
        ] satisfies Field[])
      : []),
  ];

  const download = () => {
    setDownloading(true);
    setDownloadError(null);
    downloadPurchaseOrder(documentId)
      .catch((err: unknown) => setDownloadError(err))
      .finally(() => setDownloading(false));
  };

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <h2 className="text-sm font-semibold">{ui("Sent to the supplier")}</h2>
          <Prose className="mt-0.5 text-xs text-muted-foreground">
            {ui(
              "The order as the supplier receives it: emailed from here with its PDF attached, or downloaded and sent by hand.",
            )}
          </Prose>
        </div>
        <div className="flex flex-wrap gap-2">
          <ActionButton variant="secondary" busy={downloading} onClick={download}>
            {ui("Download PDF")}
          </ActionButton>
          {sends.maySend ? (
            <ActionDialog
              trigger={
                <ActionButton>
                  {sends.sends.length > 0 ? ui("Send again") : ui("Send to supplier")}
                </ActionButton>
              }
              title="Send this order to the supplier"
              description="Emails the order with its PDF attached. An approved order moves to Sent. Replies come to you."
              permission="procurement.order"
              fn="erp_send_purchase_order"
              fields={fields}
              prefill={{ p_order: documentId }}
              context={context}
              invalidates={INVALIDATES}
              submitLabel="Send"
            />
          ) : null}
        </div>
      </div>
      <ErrorNote error={downloadError} />

      {sends.sends.length === 0 ? (
        <p className="mt-3 text-sm text-muted-foreground">
          {ui("Not sent yet. Send it from here, or download the PDF and send it yourself.")}
        </p>
      ) : (
        <ul className="mt-3 flex flex-col gap-2 text-sm">
          {sends.sends.map((s) => (
            <li key={s.id} className="flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1">
              <Pill tone={TONE[s.status]}>{word[s.status]}</Pill>
              <span className="min-w-0 break-all">{s.to}</span>
              {s.cc.length > 0 ? (
                <span className="text-xs text-muted-foreground">+{s.cc.length}</span>
              ) : null}
              <span className="text-xs text-muted-foreground tabular-nums">
                {[s.issuedNumber, s.when?.slice(0, 16).replace("T", " "), s.sentBy]
                  .filter(Boolean)
                  .join(" · ")}
              </span>
              {s.copyKept ? (
                <span className="text-xs text-muted-foreground">{ui("Copy kept")}</span>
              ) : null}
              {s.reason ? (
                <span className="w-full text-xs text-muted-foreground">{s.reason}</span>
              ) : null}
              {s.problem ? (
                <span className="w-full text-xs text-destructive">{s.problem}</span>
              ) : null}
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
