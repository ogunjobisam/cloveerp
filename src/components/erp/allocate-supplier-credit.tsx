import { useT } from "../../lib/i18n";
import { fill } from "../../lib/interview";
import { formatMinor } from "../../lib/money";
import { canAllocateCredit, supplierCredit } from "../../lib/supplier-return";
import { ActionDialog, type Field } from "./action";
import { TOUCH } from "./page";

/**
 * Allocate, on a credit note's row of Supplier credit notes (20261004910000).
 *
 * A credit note pays the bill it credits as it is issued, and the order's
 * next bill takes what is left; this is for the rest. Drawn only where
 * erp_supplier_credit_notes says the reader may allocate the credit and names
 * an open bill of the same supplier, company and currency to take it. The
 * amount may be left out. The database refuses regardless.
 */

const INVALIDATES = [
  "erp_supplier_credit_notes",
  "erp_supplier_return",
  "erp_supplier_balances",
  "erp_payables_ageing",
  "erp_trial_balance",
  "erp_documents",
  "erp_document",
];

const TRIGGER = `${TOUCH} inline-flex shrink-0 items-center justify-center rounded-md border border-input px-4 text-sm font-medium`;

export function AllocateSupplierCredit({ row }: { row: Record<string, unknown> }) {
  const { ui } = useT();
  const credit = supplierCredit(row);
  if (!canAllocateCredit(credit)) return null;

  const money = (n: number) => formatMinor(n, credit.currency);
  const fields: Field[] = [
    {
      kind: "choice",
      name: "p_bill",
      label: "Bill",
      required: true,
      choices: credit.bills.map((b) => ({
        value: b.documentId,
        label: `${b.number} — ${money(b.owesMinor)}`,
      })),
    },
    {
      kind: "money",
      name: "p_amount_minor",
      label: "Amount",
      currency: credit.currency,
      hint: "Leave empty to allocate as much as the credit and the bill allow.",
    },
  ];
  const context = fill(ui("{amount} credited by {supplier}"), {
    amount: money(credit.leftMinor),
    supplier: credit.supplier,
  });
  const first = credit.bills[0]?.documentId;

  return (
    <ActionDialog
      trigger={
        <button type="button" className={TRIGGER} aria-label={`${ui("Allocate")} ${context}`}>
          {ui("Allocate")}
        </button>
      }
      title="Allocate a supplier credit"
      description="Pays one of the supplier's open bills from the credit note. The bill moves to part paid or paid."
      permission="finance.post"
      fn="erp_allocate_supplier_credit"
      fields={fields}
      prefill={{ p_credit_note: credit.creditNoteId }}
      {...(first ? { preselect: { p_bill: first } } : {})}
      context={`${credit.creditNoteNumber} · ${context}`}
      invalidates={INVALIDATES}
      submitLabel="Allocate"
    />
  );
}
