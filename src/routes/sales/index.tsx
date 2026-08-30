import { createFileRoute } from "@tanstack/react-router";

import { DocumentPanel } from "../../components/erp/documents";
import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";

export const Route = createFileRoute("/sales/")({
  head: () => ({ meta: [{ title: "Sales — ERPWare" }] }),
  component: () => (
    <Gate>
      <Sales />
    </Gate>
  ),
});

/**
 * Quotation to order to delivery.
 *
 * None of this is a table of its own: all three are configured document types
 * on one spine, and posting a delivery moves stock through the same function a
 * goods receipt uses, with the sign coming from the movement type.
 *
 * Which is why this file is three lines of content and no logic. The base type
 * codes are product content; everything else — the tenant's own type code, its
 * numbering, its lifecycle, the permission to raise one — comes from the
 * database.
 */
function Sales() {
  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title="Sales">
        Quotation to order to delivery, on the same document spine procurement uses in the opposite
        direction.
      </PageHeader>

      <DocumentPanel
        title="Quotations"
        description="Offers, before they are orders."
        baseType="quotation"
        partyRole="customer"
        empty="No quotations yet. New raises one."
      />

      <DocumentPanel
        title="Sales orders"
        description="Commitments to a customer. Discount and credit bands decide what needs approving."
        baseType="sales_order"
        partyRole="customer"
        empty="No sales orders yet."
      />

      <DocumentPanel
        title="Deliveries"
        description="Goods leaving. Posting one is what takes the stock off the shelf."
        baseType="delivery"
        partyRole="customer"
        empty="No deliveries yet."
      />
    </div>
  );
}
