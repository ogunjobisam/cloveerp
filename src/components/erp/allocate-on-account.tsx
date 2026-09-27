import { useT } from "../../lib/i18n";
import { fill } from "../../lib/interview";
import { formatMinor } from "../../lib/money";
import { canAllocate, onAccountCredit } from "../../lib/on-account";
import { ActionDialog, type Field } from "./action";
import { TOUCH } from "./page";

/**
 * Allocate, on a credit's row of Credit on account (PR13 M5, 20260930400000).
 *
 * Drawn only where erp_on_account_credits says the reader may allocate the
 * credit and names an open invoice of the same customer, company and currency
 * to take it; the invoices offered are those. The amount may be left out, and
 * the door allocates as much as the credit and the invoice allow. The database
 * refuses regardless.
 */

const INVALIDATES = [
  "erp_on_account_credits",
  "erp_receivables_ageing",
  "erp_dunning_worklist",
  "erp_trial_balance",
  "erp_documents",
  "erp_document",
];

const TRIGGER = `${TOUCH} inline-flex shrink-0 items-center justify-center rounded-md border border-input px-4 text-sm font-medium`;

export function AllocateOnAccount({ row }: { row: Record<string, unknown> }) {
  const { ui } = useT();
  const credit = onAccountCredit(row);
  if (!canAllocate(credit)) return null;

  const money = (n: number) => formatMinor(n, credit.currency);
  const fields: Field[] = [
    {
      kind: "choice",
      name: "p_invoice",
      label: "Invoice",
      required: true,
      choices: credit.invoices.map((i) => ({
        value: i.documentId,
        label: `${i.number} — ${money(i.owesMinor)}`,
      })),
    },
    {
      kind: "money",
      name: "p_amount_minor",
      label: "Amount",
      currency: credit.currency,
      hint: "Leave empty to allocate as much as the credit and the invoice allow.",
    },
  ];
  const context = fill(ui("{amount} on account for {customer}"), {
    amount: money(credit.leftMinor),
    customer: credit.customer,
  });
  const first = credit.invoices[0]?.documentId;

  return (
    <ActionDialog
      trigger={
        <button type="button" className={TRIGGER} aria-label={`${ui("Allocate")} ${context}`}>
          {ui("Allocate")}
        </button>
      }
      title="Allocate a credit on account"
      description="Settles one of the customer's open invoices from the credit. The invoice moves to part paid or paid."
      permission="finance.post"
      fn="erp_allocate_on_account"
      fields={fields}
      prefill={{ p_credit_item: credit.creditItemId }}
      {...(first ? { preselect: { p_invoice: first } } : {})}
      context={context}
      invalidates={INVALIDATES}
      submitLabel="Allocate"
    />
  );
}
