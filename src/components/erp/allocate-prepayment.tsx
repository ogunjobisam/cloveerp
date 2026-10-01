import { useT } from "../../lib/i18n";
import { fill } from "../../lib/interview";
import { formatMinor } from "../../lib/money";
import { canAllocatePrepayment, supplierPrepayment } from "../../lib/prepayment";
import { ActionDialog, type Field } from "./action";
import { TOUCH } from "./page";

/**
 * Allocate, on a prepayment's row of Supplier prepayments (20261004900000).
 *
 * A bill registered against the prepaid order takes the prepayment by itself;
 * this is for the rest: a bill that names another order, or none. Drawn only
 * where erp_supplier_prepayments says the reader may allocate the prepayment
 * and names an open bill of the same supplier, company and currency to take
 * it; the bills offered are those. The amount may be left out, and the door
 * allocates as much as the prepayment and the bill allow. The database refuses
 * regardless.
 */

const INVALIDATES = [
  "erp_supplier_prepayments",
  "erp_order_prepayment",
  "erp_supplier_balances",
  "erp_payables_ageing",
  "erp_trial_balance",
  "erp_documents",
  "erp_document",
];

const TRIGGER = `${TOUCH} inline-flex shrink-0 items-center justify-center rounded-md border border-input px-4 text-sm font-medium`;

export function AllocatePrepayment({ row }: { row: Record<string, unknown> }) {
  const { ui } = useT();
  const prepayment = supplierPrepayment(row);
  if (!canAllocatePrepayment(prepayment)) return null;

  const money = (n: number) => formatMinor(n, prepayment.currency);
  const fields: Field[] = [
    {
      kind: "choice",
      name: "p_bill",
      label: "Bill",
      required: true,
      choices: prepayment.bills.map((b) => ({
        value: b.documentId,
        label: `${b.number} — ${money(b.owesMinor)}`,
      })),
    },
    {
      kind: "money",
      name: "p_amount_minor",
      label: "Amount",
      currency: prepayment.currency,
      hint: "Leave empty to allocate as much as the prepayment and the bill allow.",
    },
  ];
  const context = fill(ui("{amount} prepaid to {supplier}"), {
    amount: money(prepayment.leftMinor),
    supplier: prepayment.supplier,
  });
  const first = prepayment.bills[0]?.documentId;

  return (
    <ActionDialog
      trigger={
        <button type="button" className={TRIGGER} aria-label={`${ui("Allocate")} ${context}`}>
          {ui("Allocate")}
        </button>
      }
      title="Allocate a prepayment"
      description="Pays one of the supplier's open bills from the prepayment. The bill moves to part paid or paid."
      permission="finance.post"
      fn="erp_allocate_prepayment"
      fields={fields}
      prefill={{ p_order: prepayment.orderId }}
      {...(first ? { preselect: { p_bill: first } } : {})}
      context={`${prepayment.orderNumber} · ${context}`}
      invalidates={INVALIDATES}
      submitLabel="Allocate"
    />
  );
}
