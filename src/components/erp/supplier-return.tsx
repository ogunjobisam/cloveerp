import { useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";

import { callErp } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { formatMinor } from "../../lib/money";
import { canReceiveReplacement, supplierReturn } from "../../lib/supplier-return";
import { ActionButton, ActionDialog, ErrorNote } from "./action";
import { Prose } from "./page";

/**
 * Goods sent back to a supplier, on the return's own page (20261004910000):
 * what for, the supplier's return authorisation, what is left of its credit,
 * and, for a replacement, what is still awaited and the receipts that brought
 * it.
 *
 * Receive the replacement is offered where public.erp_supplier_return says
 * the reader may (procurement.receive on an issued return for replacement that
 * still awaits something). It opens and posts a goods receipt against the
 * return. The door refuses regardless.
 */

const INVALIDATES = [
  "erp_supplier_return",
  "erp_document",
  "erp_documents",
  "erp_stock_health",
  "erp_stock_valuation",
];

export function SupplierReturn({ documentId, context }: { documentId: string; context: string }) {
  const { ui } = useT();
  const { data, error } = useQuery({
    queryKey: ["erp_supplier_return", { p_return: documentId }],
    queryFn: () => callErp<unknown>("erp_supplier_return", { p_return: documentId }),
  });
  const ret = supplierReturn(data);
  if (error) return <ErrorNote error={error} />;
  if (!ret) return null;

  const replacement = ret.outcome === "replacement";

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <h2 className="text-sm font-semibold">
            {replacement ? ui("Sent back for a replacement") : ui("Credit")}
          </h2>
          {replacement ? (
            <Prose className="mt-0.5 text-xs text-muted-foreground">
              {ui(
                "The supplier sends the same goods again. Nothing is credited; the replacement is received here, against this return.",
              )}
            </Prose>
          ) : null}
        </div>
        {canReceiveReplacement(ret) ? (
          <ActionDialog
            trigger={
              <ActionButton variant="secondary">{ui("Receive the replacement")}</ActionButton>
            }
            title="Receive the goods the supplier sent again"
            description="A goods receipt against this return, posted as it is made. The goods go back on the shelf and nothing is billed."
            permission="procurement.receive"
            fn="erp_receive_replacement"
            fields={[
              {
                kind: "number",
                name: "p_quantity",
                label: "Quantity",
                hint: "Leave empty to receive everything still awaited.",
              },
            ]}
            prefill={{ p_return: ret.returnId }}
            context={context}
            invalidates={INVALIDATES}
            submitLabel="Receive"
          />
        ) : null}
      </div>

      <dl className="mt-4 grid grid-cols-2 gap-x-4 gap-y-2 text-sm sm:grid-cols-3">
        <div className="min-w-0">
          <dt className="text-xs text-muted-foreground">{ui("Return authorisation")}</dt>
          <dd>{ret.rma ?? "—"}</dd>
        </div>
        {replacement ? (
          <div className="min-w-0">
            <dt className="text-xs text-muted-foreground">{ui("Still awaited")}</dt>
            <dd className="tabular-nums">{ret.awaited}</dd>
          </div>
        ) : (
          <div className="min-w-0">
            <dt className="text-xs text-muted-foreground">{ui("Credit left")}</dt>
            <dd className="tabular-nums">{formatMinor(ret.creditLeftMinor, ret.currency)}</dd>
          </div>
        )}
      </dl>

      {ret.receipts.length > 0 ? (
        <ul className="mt-3 flex flex-wrap gap-x-4 gap-y-1 text-sm">
          {ret.receipts.map((r) => (
            <li key={r.documentId}>
              <Link
                to="/documents/$documentId"
                params={{ documentId: r.documentId }}
                className="underline underline-offset-2"
              >
                {r.number}
              </Link>
            </li>
          ))}
        </ul>
      ) : null}
    </section>
  );
}
