import { useQuery } from "@tanstack/react-query";

import { callErp, hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import {
  confirmationWords,
  orderConfirmation,
  type OrderConfirmation,
} from "../../lib/supplier-confirmation";
import { ActionButton, ActionDialog, ErrorNote, type Field } from "./action";
import { LoadingRows, Prose } from "./page";
import { Pill, Table } from "./panel";
import { useErpSession } from "./session-context";

/**
 * A sent purchase order's answer from its supplier, on its page
 * (20261004990000): awaiting, confirmed, changes proposed or declined, who
 * answered and how, what each line was confirmed at, and the buyer's moves —
 * accept or reject proposed changes, record an answer given by phone or reply,
 * and cancel an order nothing has been received against. The database refuses
 * regardless.
 */

const INVALIDATES = [
  "erp_purchase_order_confirmation",
  "erp_awaiting_confirmations",
  "erp_document",
  "erp_documents",
  "erp_available_transitions",
];

export function SupplierConfirmation({
  documentId,
  context,
}: {
  documentId: string;
  context: string;
}) {
  const { ui } = useT();
  const { session } = useErpSession();
  const mayRead = hasPermission(session, "procurement.read");
  const { data, error, isPending } = useQuery({
    queryKey: ["erp_purchase_order_confirmation", { p_order: documentId }],
    queryFn: () => callErp<unknown>("erp_purchase_order_confirmation", { p_order: documentId }),
    enabled: mayRead,
  });
  if (!mayRead) return null;
  // What was read is kept while a later read fails, with the failure beside
  // it, so a form open over the section is not taken away (J-34). Its place
  // is held while it is first read, so the sections below it do not move
  // under a pointer when it lands (J-128).
  if (error && data === undefined) return <ErrorNote error={error} />;
  if (isPending) return <LoadingRows rows={1} />;
  const c = orderConfirmation(data);
  if (!c) return <ErrorNote error={error} />;
  const status = confirmationWords(c.status);
  const open = c.state === "sent" || c.state === "partially_received";

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <h2 className="text-sm font-semibold">{ui("Supplier confirmation")}</h2>
          <Prose className="mt-0.5 text-xs text-muted-foreground">
            {ui(
              "What the supplier said about this order: taken as it is, taken with changes, or declined. They answer from the link in the order's email; you can record an answer they gave you.",
            )}
          </Prose>
        </div>
        <Pill tone={status.tone}>{ui(status.words)}</Pill>
      </div>

      <Facts c={c} />

      {c.status === "changes_proposed" && c.proposal.length > 0 ? (
        <Proposal c={c} context={context} />
      ) : null}

      {c.lines.some((l) => l.confirmedQuantity !== null) ? (
        <div className="mt-3">
          <Table columns={[ui("Line"), ui("Item"), ui("Ordered"), ui("Confirmed"), ui("By")]}>
            {c.lines.map((l) => (
              <tr key={l.lineId} className="border-b border-border/60 last:border-0">
                <td className="py-2 pr-4 tabular-nums">{l.lineNo}</td>
                <td className="py-2 pr-4">{l.description}</td>
                <td className="py-2 pr-4 tabular-nums">{l.quantity}</td>
                <td className="py-2 pr-4 tabular-nums">{l.confirmedQuantity ?? "—"}</td>
                <td className="py-2 tabular-nums">{l.confirmedDate ?? l.requiredDate ?? "—"}</td>
              </tr>
            ))}
          </Table>
        </div>
      ) : null}

      <div className="mt-4 flex flex-wrap gap-2">
        {open && c.mayRecord && c.status !== "withdrawn" ? (
          <RecordAnswer c={c} context={context} />
        ) : null}
        {c.state === "sent" && c.mayCancel && !c.receivedAny ? (
          <ActionDialog
            trigger={<ActionButton variant="secondary">{ui("Cancel this order")}</ActionButton>}
            title="Cancel this order"
            description="Cancels the order before anything has arrived. The supplier's link stops working; tell them yourself."
            permission="procurement.approve"
            fn="erp_cancel_sent_order"
            fields={[
              {
                kind: "text",
                name: "p_reason",
                label: "Why it is cancelled",
                required: true,
                placeholder: "The supplier discontinued the item",
                hint: "Kept with the order for the supplier and the auditor.",
              },
            ]}
            prefill={{ p_order: c.orderId }}
            context={context}
            invalidates={INVALIDATES}
            submitLabel="Cancel the order"
          />
        ) : null}
      </div>
      {error ? (
        <div className="mt-3">
          <ErrorNote error={error} />
        </div>
      ) : null}
    </section>
  );
}

function Facts({ c }: { c: OrderConfirmation }) {
  const { ui } = useT();
  const rows: [string, string | null][] = [
    [
      ui("Answered"),
      c.respondedAt
        ? `${c.respondedAt.slice(0, 16).replace("T", " ")} · ${
            c.respondedVia === "buyer" ? ui("recorded by the buyer") : ui("by the supplier")
          }`
        : null,
    ],
    [ui("Waiting since"), c.status === "awaiting" ? (c.awaitingSince?.slice(0, 10) ?? null) : null],
    [ui("Their reference"), c.supplierReference],
    [ui("Their note"), c.note],
    [ui("Your note"), c.decisionNote],
  ];
  const shown = rows.filter((r): r is [string, string] => r[1] !== null && r[1] !== "");
  if (shown.length === 0) return null;
  return (
    <dl className="mt-3 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
      {shown.map(([k, v]) => (
        <div key={k} className="contents">
          <dt className="text-muted-foreground">{k}</dt>
          <dd className="min-w-0 break-words">{v}</dd>
        </div>
      ))}
    </dl>
  );
}

function Proposal({ c, context }: { c: OrderConfirmation; context: string }) {
  const { ui } = useT();
  return (
    <div className="mt-4 rounded-lg border border-border p-3">
      <h3 className="text-sm font-medium">{ui("The supplier proposed")}</h3>
      <div className="mt-2">
        <Table
          columns={[
            ui("Line"),
            ui("Ordered"),
            ui("They can send"),
            ui("Wanted by"),
            ui("They say"),
          ]}
        >
          {c.proposal.map((p) => (
            <tr key={p.lineId} className="border-b border-border/60 last:border-0">
              <td className="py-2 pr-4 tabular-nums">{p.lineNo}</td>
              <td className="py-2 pr-4 tabular-nums">{p.orderedQuantity}</td>
              <td className="py-2 pr-4 tabular-nums">{p.quantity}</td>
              <td className="py-2 pr-4 tabular-nums">{p.requiredDate ?? "—"}</td>
              <td className="py-2 tabular-nums">{p.date ?? "—"}</td>
            </tr>
          ))}
        </Table>
      </div>
      {c.mayRecord ? (
        <div className="mt-3 flex flex-wrap gap-2">
          <ActionDialog
            trigger={<ActionButton>{ui("Accept the changes")}</ActionButton>}
            title="Accept the supplier's changes"
            description="The order's quantities change to what the supplier can send, and each line keeps the date they gave."
            permission="procurement.order"
            fn="erp_decide_supplier_changes"
            fields={[]}
            prefill={{ p_order: c.orderId, p_accept: true }}
            context={context}
            invalidates={INVALIDATES}
            submitLabel="Accept"
          />
          <ActionDialog
            trigger={<ActionButton variant="secondary">{ui("Reject the changes")}</ActionButton>}
            title="Reject the supplier's changes"
            description="The order is unchanged and waits for a new answer. The supplier sees your note when they open their link."
            permission="procurement.order"
            fn="erp_decide_supplier_changes"
            fields={[
              {
                kind: "text",
                name: "p_note",
                label: "What you need instead",
                required: true,
                placeholder: "We need all ten by the date",
                hint: "Shown to the supplier with the order.",
              },
            ]}
            prefill={{ p_order: c.orderId, p_accept: false }}
            context={context}
            invalidates={INVALIDATES}
            submitLabel="Reject"
          />
        </div>
      ) : null}
    </div>
  );
}

function RecordAnswer({ c, context }: { c: OrderConfirmation; context: string }) {
  const { ui } = useT();
  const fields: Field[] = [
    {
      kind: "choice",
      name: "decision",
      label: "What the supplier said",
      required: true,
      choices: [
        { value: "confirm", label: "They will send it" },
        { value: "decline", label: "They cannot take it" },
      ],
    },
    {
      kind: "text",
      name: "supplier_reference",
      label: "Their reference",
      placeholder: "SO-1234",
      hint: "Optional. Their own order number.",
    },
    {
      kind: "text",
      name: "note",
      label: "What they said",
      placeholder: "Two coats on back order",
      hint: "Needed when they cannot take it.",
    },
    {
      kind: "rows",
      name: "lines",
      label: "Lines they changed",
      columns: [
        {
          name: "line_id",
          label: "Line",
          kind: "select",
          options: {
            fn: "erp_document_lines",
            args: { p_document_id: c.orderId, p_limit: 500 },
            value: "line_id",
            label: ["item", "quantity"],
          },
        },
        { name: "quantity", label: "They can send", kind: "number", placeholder: "8" },
        { name: "date", label: "By", kind: "date" },
      ],
      addLabel: "Add a changed line",
    },
  ];
  return (
    <ActionDialog
      trigger={
        <ActionButton variant="secondary">{ui("Record the supplier's answer")}</ActionButton>
      }
      title="Record the supplier's answer"
      description="For an answer the supplier gave by phone or email. Lines left out are taken as ordered; a changed line waits for you to accept it."
      permission="procurement.order"
      fn="erp_record_supplier_confirmation"
      fields={fields}
      mapArgs={(v, picked) => {
        // mapArgs is handed what was typed: the quantities as text.
        const lines = (picked?.rows["lines"] ?? [])
          .filter((row) => (row["line_id"] ?? "") !== "")
          .map((row) => ({
            line_id: row["line_id"],
            ...((row["quantity"] ?? "") !== "" ? { quantity: Number(row["quantity"]) } : {}),
            ...(row["date"] ? { date: row["date"] } : {}),
          }));
        return {
          p_order: c.orderId,
          p_response: {
            decision: v["decision"] ?? "confirm",
            ...(v["supplier_reference"] ? { supplier_reference: v["supplier_reference"] } : {}),
            ...(v["note"] ? { note: v["note"] } : {}),
            ...(lines.length > 0 ? { lines } : {}),
          },
        };
      }}
      context={context}
      invalidates={INVALIDATES}
      submitLabel="Record"
    />
  );
}
