import { createFileRoute } from "@tanstack/react-router";

import {
  ActionBar,
  pickFrom,
  pickItem,
  pickParty,
  pickSite,
  reason,
} from "../../components/erp/actions-bar";
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

      <ActionBar
        note="The verbs that sit between the documents: pricing, stock promise, credit and returns."
        actions={[
          {
            label: "Resolve a price",
            description: "What would this customer pay for this item today?",
            permission: "sales.price",
            fn: "erp_resolve_price",
            fields: [
              pickItem(),
              pickParty("customer"),
              { kind: "number", name: "p_quantity", label: "Quantity" },
            ],
          },
          {
            label: "Promise a date",
            permission: "sales.order",
            fn: "erp_promise_date",
            fields: [
              pickItem(),
              pickSite(),
              { kind: "number", name: "p_quantity", label: "Quantity", required: true },
            ],
          },
          {
            label: "Reserve stock for a line",
            permission: "sales.order",
            fn: "erp_reserve_for_line",
            fields: [
              { kind: "text", name: "p_document_line_id", label: "Document line id", required: true },
              { kind: "text", name: "p_policy_code", label: "Policy code" },
            ],
          },
          {
            label: "Release a credit hold",
            permission: "sales.credit_release",
            fn: "erp_release_credit_hold",
            fields: [
              pickFrom(
                "erp_documents",
                "document_id",
                ["document_number", "status"],
                "p_document_id",
                "Document",
                { p_limit: 100 },
              ),
              reason("p_reason", "Reason", true),
            ],
          },
          {
            label: "Raise a customer return",
            permission: "sales.order",
            fn: "erp_raise_customer_return",
            fields: [
              pickFrom(
                "erp_documents",
                "document_id",
                ["document_number", "status"],
                "p_original_document_id",
                "Original document",
                { p_limit: 100 },
              ),
              { kind: "text", name: "p_reason_code", label: "Reason code", required: true },
              reason("p_reason", "Reason", true),
              {
                kind: "choice",
                name: "p_outcome",
                label: "Outcome",
                choices: [
                  { value: "credit", label: "Credit" },
                  { value: "replace", label: "Replace" },
                  { value: "repair", label: "Repair" },
                ],
              },
            ],
          },
        ]}
      />


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
