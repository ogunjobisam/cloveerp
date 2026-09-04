import { createFileRoute } from "@tanstack/react-router";

import { AutoPanel } from "../../components/erp/auto";
import {
  ActionBar,
  pickFrom,
  pickItem,
  pickLine,
  pickParty,
  pickSite,
  reason,
} from "../../components/erp/actions-bar";
import { DocumentPanel } from "../../components/erp/documents";
import { Gate } from "../../components/erp/gate";
import { KpiRow } from "../../components/erp/kpi";
import { PageHeader } from "../../components/erp/page";
import { SALES_KPIS } from "../../lib/modules";

export const Route = createFileRoute("/sales/")({
  head: () => ({ meta: [{ title: "Sales — Clove ERP" }] }),
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
        Quote to order to delivery, on the same document spine purchasing uses in the opposite
        direction.
      </PageHeader>

      <KpiRow kpis={SALES_KPIS} />

      <ActionBar
        title="Pricing, promise, credit and returns"
        note="The verbs that sit between the documents: pricing, stock promise, credit and returns."
        actions={[
          {
            label: "Resolve a price",
            description: "What would this customer pay for this product today?",
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
              pickLine("sales_order", "p_document_line_id", "Order line"),
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

      <AutoPanel
        title="Release sequence"
        description="Open demand in the order it should be released: promise date first, then credit standing, then value."
        fn="erp_release_sequence"
        empty="Nothing open to release. Confirmed sales order lines appear here in the order they should be released."
        rowKey={(r, i) => String(r["line_id"] ?? i)}
        columns={[
          { header: "#", cell: "rank", numeric: true },
          { header: "Order", cell: "document_number" },
          { header: "Customer", cell: "customer" },
          { header: "Product", cell: "item" },
          { header: "Quantity", cell: "quantity", numeric: true },
          { header: "Required", cell: "required_date" },
          { header: "Credit", cell: "credit_status" },
          { header: "Available", cell: "available", numeric: true },
          { header: "Ship in full", cell: "can_ship_in_full" },
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
        empty="No sales orders yet. New raises one, or accept a quotation from the panel above."
      />

      <DocumentPanel
        title="Deliveries"
        description="Goods leaving. Posting one is what takes the stock off the shelf."
        baseType="delivery"
        partyRole="customer"
        empty="No deliveries yet. A delivery is raised against a sales order, and posting it is what takes the stock off the shelf."
      />

      {/* An invoice raised from a delivery had nowhere to be read: it exists as
          a draft until someone posts it, and posting is what puts the debt on
          the customer's account. */}
      <DocumentPanel
        title="Sales invoices"
        description="What the customer owes. Posting one raises the receivable and the revenue."
        baseType="invoice_reference"
        typeCode="sales_invoice"
        partyRole="customer"
        empty="No sales invoices yet. Invoice a delivery from the Financials module, then post it here."
      />
    </div>
  );
}
