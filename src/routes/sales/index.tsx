import { createFileRoute } from "@tanstack/react-router";

import { AutoPanel } from "../../components/erp/auto";
import {
  ActionBar,
  pickBatch,
  pickFrom,
  pickItem,
  pickLine,
  pickLocation,
  pickParty,
  pickSite,
  reason,
  type ActionSpec,
} from "../../components/erp/actions-bar";
import { DocumentPanel } from "../../components/erp/documents";
import { Gate } from "../../components/erp/gate";
import { KpiRow } from "../../components/erp/kpi";
import { PageHeader } from "../../components/erp/page";
import { ProcessFlow } from "../../components/erp/process-flow";
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
const SALES_ACTIONS: ActionSpec[] = [
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
      {
        kind: "text",
        name: "p_policy_code",
        label: "Policy code",
        placeholder: "FEFO",
        hint: "Optional. Leave empty to use the product's usual rule.",
      },
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
      {
        kind: "combo",
        name: "p_reason_code",
        label: "Reason code",
        required: true,
        options: { fn: "erp_reason_codes", value: "code", label: ["code", "name"] },
      },
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
];

function Sales() {
  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title="Sales">
        Quote to order to delivery, on the same document spine purchasing uses in the opposite
        direction.
      </PageHeader>

      <KpiRow kpis={SALES_KPIS} />

      <ProcessFlow
        flow={{
          title: "Order to cash, step by step",
          note: "Each box is a step in the chain and shows what is sitting there now. The button on a box is the verb that moves work to the next one.",
          stages: [
            {
              label: "Quotation",
              hint: "A price offered, before the customer has committed to anything.",
              typeCode: "quotation",
              actionFn: "erp_resolve_price",
            },
            {
              label: "Sales order",
              hint: "The commitment. Credit and stock availability both decide whether it can proceed.",
              typeCode: "sales_order",
              actionFn: "erp_promise_date",
            },
            {
              label: "Pick",
              hint: "Stock reserved against the line, then picked from the location holding it.",
              actionFn: "erp_reserve_for_line",
            },
            {
              label: "Delivery",
              hint: "Goods leaving. Posting a delivery is what takes the stock off the shelf.",
              typeCode: "delivery",
              to: "/logistics",
              toLabel: "Open despatch",
            },
            {
              label: "Invoice",
              hint: "The bill, raised from a posted delivery so it says what actually went.",
              typeCode: "sales_invoice",
              to: "/finance",
              toLabel: "Open finance",
            },
            {
              label: "Cash",
              hint: "Money received, applied against the invoices it settles.",
              to: "/finance",
              toLabel: "Apply cash",
            },
          ],
        }}
        actions={SALES_ACTIONS}
      />

      <ActionBar
        title="Pricing, promise, credit and returns"
        note="The verbs that sit between the documents: pricing, stock promise, credit and returns."
        actions={SALES_ACTIONS}
      />

      <ActionBar
        title="Orders that are fulfilled elsewhere"
        note="A drop-ship is bought from a supplier who delivers to the customer; an intercompany order is mirrored into the company that supplies it. Stock identity pins a line to a batch, location or handling unit."
        actions={[
          {
            label: "Raise a drop-ship order",
            description:
              "A purchase order to the supplier, addressed to the customer, priced from the catalogue and linked line by line to this sales order.",
            permission: "procurement.order",
            fn: "erp_raise_drop_ship_order",
            fields: [
              pickFrom(
                "erp_documents",
                "document_id",
                ["document_number", "state"],
                "p_sales_order_id",
                "Sales order",
                { p_type_code: "sales_order", p_limit: 100 },
              ),
              pickParty("supplier", "p_supplier_party_id", "Supplier"),
            ],
            invalidates: ["erp_documents"],
          },
          {
            label: "Raise an intercompany order",
            description:
              "Mirrors this sales order as a purchase order in the buying company, at its site, in its currency.",
            permission: "procurement.order",
            fn: "erp_raise_intercompany_order",
            fields: [
              pickFrom(
                "erp_documents",
                "document_id",
                ["document_number", "state"],
                "p_sales_order_id",
                "Sales order",
                { p_type_code: "sales_order", p_limit: 100 },
              ),
              pickSite("p_site_id", "Receiving site"),
            ],
            invalidates: ["erp_documents"],
          },
          {
            label: "Pin a line's stock identity",
            description:
              "The batch, location or handling unit a sales line must be fulfilled from.",
            permission: "sales.order",
            fn: "erp_set_line_stock_identity",
            fields: [
              pickLine("sales_order", "p_line_id", "Sales order line"),
              pickBatch("p_batch_id", "Batch", false),
              pickLocation("p_location_id", "Location", false),
              {
                kind: "text",
                name: "p_container_id",
                label: "Handling unit id",
                placeholder: "0f9c1a2e-…",
                hint: "Optional. The pallet or tote this line must ship on.",
              },
            ],
            invalidates: ["erp_document"],
          },
        ]}
      />

      <AutoPanel
        title="Return reasons"
        description="Why customers have returned goods over the last ninety days, by reason code."
        fn="erp_return_reasons"
        args={{ p_days: 90 }}
        empty="No returns in the window. Customer returns raised with a reason code are counted here."
        rowKey={(r, i) => String(r["reason_code"] ?? i)}
        columns={[
          { header: "Reason", cell: "reason_code" },
          { header: "Returns", cell: "returns", numeric: true },
          { header: "Value", cell: "value_minor", numeric: true },
          { header: "Share %", cell: "share_pct", numeric: true },
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
