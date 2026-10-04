import { useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";

import { callErp } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { formatMinor } from "../../lib/money";
import { orderPrepayment, showsPrepayment } from "../../lib/prepayment";
import { ActionButton, ActionDialog, ErrorNote } from "./action";
import { LoadingRows, Prose } from "./page";

/**
 * A purchase order's prepayment (20261004900000): what the supplier asked for
 * before the goods, what the payment run has paid, what their bills have taken
 * and what they still hold, with the payments that paid it.
 *
 * Request is offered where public.erp_order_prepayment says the reader may ask
 * (procurement.order on an approved, sent or received order). The amount is
 * the whole prepayment wanted, so the same form changes it, and nought
 * withdraws whatever has not been paid. The door refuses regardless. Nothing is
 * drawn on an order nobody prepaid and the reader may not prepay.
 */

const INVALIDATES = [
  "erp_order_prepayment",
  "erp_supplier_prepayments",
  "erp_document",
  "erp_documents",
];

export function OrderPrepayment({ documentId, context }: { documentId: string; context: string }) {
  const { ui } = useT();
  const { data, error, isPending } = useQuery({
    queryKey: ["erp_order_prepayment", { p_order: documentId }],
    queryFn: () => callErp<unknown>("erp_order_prepayment", { p_order: documentId }),
  });
  const prepayment = orderPrepayment(data);
  // What was read is kept while a later read fails, with the failure beside
  // it, so a form open over the section is not taken away (J-34). Its place
  // is held while it is first read, so nothing below it moves when it lands
  // (J-128).
  if (error && data === undefined) return <ErrorNote error={error} />;
  if (isPending) return <LoadingRows rows={1} />;
  if (!showsPrepayment(prepayment)) return <ErrorNote error={error} />;

  const money = (n: number) => formatMinor(n, prepayment.currency);
  const asked = prepayment.requestedMinor > 0 || prepayment.paidMinor > 0;
  const figures: [string, string][] = [
    [ui("Asked for"), money(prepayment.requestedMinor)],
    [ui("Paid"), money(prepayment.paidMinor)],
    [ui("Used by bills"), money(prepayment.usedMinor)],
    [ui("Left with the supplier"), money(prepayment.leftMinor)],
    [
      ui("Due"),
      prepayment.dueMinor > 0 && prepayment.dueOn
        ? `${money(prepayment.dueMinor)} · ${prepayment.dueOn}`
        : money(prepayment.dueMinor),
    ],
  ];

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <h2 className="text-sm font-semibold">{ui("Prepayment")}</h2>
          <Prose className="mt-0.5 text-xs text-muted-foreground">
            {ui(
              "Money the supplier asked for before the goods. The next payment run pays it, and their bill takes it when it arrives.",
            )}
          </Prose>
        </div>
        {prepayment.mayRequest ? (
          <ActionDialog
            trigger={
              <ActionButton variant="secondary">
                {asked ? ui("Change the prepayment") : ui("Request a prepayment")}
              </ActionButton>
            }
            title={asked ? "Change the prepayment" : "Request a prepayment"}
            description="Ask for part or all of this order to be paid before the goods. The whole amount wanted, not an extra amount."
            permission="procurement.order"
            fn="erp_request_prepayment"
            fields={[
              {
                kind: "money",
                name: "p_amount_minor",
                label: "Amount in advance",
                currency: prepayment.currency,
                required: true,
                hint: "Nought withdraws whatever has not been paid yet.",
              },
              {
                kind: "date",
                name: "p_due_on",
                label: "Pay by",
                hint: "The payment run that reaches this date pays it.",
              },
              {
                kind: "text",
                name: "p_reason",
                label: "Reason",
                placeholder: "Their pro-forma or deposit invoice",
              },
            ]}
            prefill={{ p_order: prepayment.orderId }}
            context={context}
            invalidates={INVALIDATES}
            submitLabel="Ask"
          />
        ) : null}
      </div>

      {asked ? (
        <dl className="mt-4 grid grid-cols-2 gap-x-4 gap-y-2 text-sm sm:grid-cols-5">
          {figures.map(([label, value]) => (
            <div key={label} className="min-w-0">
              <dt className="text-xs text-muted-foreground">{label}</dt>
              <dd className="tabular-nums">{value}</dd>
            </div>
          ))}
        </dl>
      ) : null}
      {asked && prepayment.reason ? (
        <dl className="mt-3 min-w-0 text-sm">
          <dt className="text-xs text-muted-foreground">{ui("Reason")}</dt>
          <dd className="break-words">{prepayment.reason}</dd>
        </dl>
      ) : null}

      {prepayment.payments.length > 0 ? (
        <ul className="mt-3 flex flex-wrap gap-x-4 gap-y-1 text-sm">
          {prepayment.payments.map((p) => (
            <li key={p.documentId}>
              <Link
                to="/documents/$documentId"
                params={{ documentId: p.documentId }}
                className="underline underline-offset-2"
              >
                {p.number}
              </Link>{" "}
              <span className="tabular-nums text-muted-foreground">{money(p.paidMinor)}</span>
            </li>
          ))}
        </ul>
      ) : null}
      {error ? (
        <div className="mt-3">
          <ErrorNote error={error} />
        </div>
      ) : null}
    </section>
  );
}
