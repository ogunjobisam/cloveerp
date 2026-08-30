import { createFileRoute } from "@tanstack/react-router";

import { DocumentPanel } from "../../components/erp/documents";
import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";

export const Route = createFileRoute("/procurement/")({
  head: () => ({ meta: [{ title: "Procurement — ERPWare" }] }),
  component: () => (
    <Gate>
      <Procurement />
    </Gate>
  ),
});

/**
 * The module the documentation calls the point of the whole exercise, which
 * until now had no screen.
 *
 * `README.md` and `docs/ARCHITECTURE.md` both name procurement as the first
 * module and the one that proves the thesis. It has three state machines, a
 * value-banded approval chain, numbering rules, a thirteen-case suite, and it
 * was reachable from a SQL client and nowhere else.
 *
 * It is the same component as `/sales` with different base type codes and the
 * opposite party role — which is either evidence for the thesis or a very
 * short file, depending on how generous you are feeling.
 */
function Procurement() {
  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title="Procurement">
        Requisition to purchase order to goods receipt. Receiving posts stock inbound through the
        same bridge a delivery uses outbound.
      </PageHeader>

      <DocumentPanel
        title="Requisitions"
        description="Somebody asking for something, before anyone has committed to buying it."
        baseType="requisition"
        partyRole="supplier"
        empty="No requisitions yet. New raises one."
      />

      <DocumentPanel
        title="Purchase orders"
        description="Commitments to a supplier. Value bands decide what needs approving before it is sent."
        baseType="purchase_order"
        partyRole="supplier"
        empty="No purchase orders yet."
      />

      <DocumentPanel
        title="Goods receipts"
        description="Goods arriving. Posting one is what puts the stock on the shelf and raises the GRNI accrual."
        baseType="receipt"
        partyRole="supplier"
        empty="No receipts yet."
      />
    </div>
  );
}
