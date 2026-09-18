import { createFileRoute } from "@tanstack/react-router";

import { AutoPanel, moneyCell } from "../../components/erp/auto";
import {
  ActionBar,
  pickBatch,
  pickFrom,
  pickItem,
  pickLine,
  pickLocation,
  pickParty,
  pickReasonCode,
  pickSite,
  reason,
  type ActionSpec,
} from "../../components/erp/actions-bar";
import { Gate } from "../../components/erp/gate";
import { KpiRow } from "../../components/erp/kpi";
import { PageHeader } from "../../components/erp/page";
import { ProcessFlow, type FlowSpec } from "../../components/erp/process-flow";
import { unstagedActions } from "../../lib/flow-actions";
import { DELIVER_THIS_ORDER, SALES_KPIS } from "../../lib/modules";

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
    label: "Convert to a sales order",
    // erp.convert_document moves the quotation to Accepted as it
    // raises the order, so the step offers it where that move is available and
    // does not offer the bare move beside it.
    transition: "accept",
    title: "Turn this quotation into a sales order",
    description:
      "A quotation the customer has accepted becomes an order. Every line still outstanding is carried across at the quoted price, and the order remembers the quotation it came from.",
    permission: "sales.order",
    fn: "erp_convert_document",
    fields: [
      pickParty("customer", "p_party_id", "Customer", false),
      pickSite("p_site_id", "Site the goods ship from", false),
    ],
    emptyNote: "Only a quotation that has been sent and accepted converts into an order.",
    invalidates: ["erp_documents"],
    submitLabel: "Create the sales order",
  },
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
      // Open lines only: not on a closed or cancelled order. The line row keeps
      // no reservation; erp.reserve_for_line refuses a line that holds stock.
      pickLine("sales_order", "p_document_line_id", "Order line", { openOnly: true }),
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
    label: "Pick the order",
    description:
      "Reserves anything on the order that is not reserved yet, then picks it from the stock that is actually on the shelf. One press does both halves.",
    permission: "sales.despatch",
    fn: "erp_pick_document",
    fields: [
      pickFrom(
        "erp_documents",
        "document_id",
        ["document_number", "state"],
        "p_document_id",
        "Sales order",
        { p_type_code: "sales_order", p_limit: 100, p_actionable: true },
      ),
      pickLocation("p_location_id", "Pick from location", false),
      pickBatch("p_batch_id", "Batch", false),
    ],
    invalidates: ["erp_documents", "erp_document"],
  },
  // Creating a delivery is not here: the Sales order step above offers it with
  // the order already chosen (DELIVER_THIS_ORDER), which is the same form with
  // one fewer question. /logistics still carries the pick-the-order version.
  {
    label: "Set a customer's credit limit",
    description:
      "The most this customer may owe across open orders and unpaid invoices, and whether their orders are held. An order over the limit, or for a customer on hold, is not picked or delivered until somebody releases it.",
    permission: "sales.credit_release",
    fn: "erp_set_credit_limit",
    fields: [
      pickParty("customer", "p_party_id", "Customer"),
      {
        kind: "money",
        name: "p_credit_limit_minor",
        label: "Credit limit",
        currency: "GBP",
        hint: "In pounds. Leave empty for no limit.",
      },
      {
        kind: "choice",
        name: "p_on_hold",
        label: "Hold this customer's orders",
        boolean: true,
        default: "false",
        choices: [
          { value: "false", label: "No" },
          { value: "true", label: "Yes" },
        ],
        hint: "Yes holds every order for this customer until the hold is lifted here. No lifts a hold.",
      },
      {
        ...reason("p_reason", "Reason", true),
        hint: "Why the limit or the hold is changing. Kept with the customer's terms.",
      },
    ],
    invalidates: ["erp_credit_position", "erp_release_sequence", "erp_documents"],
  },
  {
    label: "Release a credit hold",
    permission: "sales.credit_release",
    fn: "erp_release_credit_hold",
    fields: [
      // A hold stops a confirmed order at picking and delivery, so those are
      // the orders a release is for.
      pickFrom(
        "erp_documents",
        "document_id",
        ["document_number", "state"],
        "p_document_id",
        "Confirmed sales order",
        { p_type_code: "sales_order", p_limit: 100, p_states: ["confirmed", "picking"] },
      ),
      reason("p_reason", "Reason", true),
    ],
    invalidates: ["erp_documents", "erp_release_sequence"],
  },
  {
    label: "Raise a customer return",
    permission: "sales.order",
    fn: "erp_raise_customer_return",
    fields: [
      // Posted deliveries only: erp.raise_customer_return checks no state, so
      // this follows what a return is — goods that left — as its suite does.
      // Posted is terminal, so p_actionable would offer none.
      pickFrom(
        "erp_documents",
        "document_id",
        ["document_number", "state"],
        "p_original_document_id",
        "Original document",
        { p_type_code: "delivery", p_limit: 100, p_states: ["posted"] },
      ),
      // The door only checks non-empty, so the register is enforced here.
      pickReasonCode("RETURN_CUSTOMER", "p_reason_code", "Reason code", true),
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

/**
 * The chain this screen is for, named so the action bar can read it.
 *
 * See the note on `/procurement`'s PURCHASE_TO_PAY: a verb a step carries must
 * not be offered a second time on a bar whose heading does not describe it.
 */
const ORDER_TO_CASH: FlowSpec = {
  title: "Order to cash, step by step",
  note: "Press a step to see the records sitting there, choose one on the left, and the buttons act on that record.",
  stages: [
    {
      label: "Quotation",
      hint: "A price offered, before the customer has committed to anything.",
      fedBy: "Quotations appear here once one is raised for a customer.",

      typeCode: "quotation",
      // Being written, or with the customer. Accepted, declined or
      // expired, it is finished; "Show finished" lists it.
      states: ["draft", "sent"],
      partyRole: "customer",
      recordArg: "p_document_id",
      actionFn: "erp_convert_document",
      createFn: "erp_resolve_price",
    },
    {
      label: "Sales order",
      hint: "The commitment. Credit and stock availability both decide whether it can proceed.",
      fedBy: "Orders appear here once a quotation is accepted, or an order is raised directly.",

      typeCode: "sales_order",
      // Every order not yet despatched: a draft, one with its approvers,
      // one confirmed and one being picked.
      states: ["draft", "pending_approval", "confirmed", "picking"],
      // A delivery comes from an order that can still be despatched.
      actionStates: { deliver_this_order: ["confirmed", "picking"] },
      partyRole: "customer",
      // The chosen order is the one the delivery is created from.
      recordArg: "p_order_id",
      actionFn: "deliver_this_order",
      createFn: "erp_promise_date",
    },
    {
      label: "Pick",
      hint: "Reserving and picking in one press: Pick the order takes what it needs and tells you what it could not cover.",
      createFn: "erp_pick_document",
    },
    {
      label: "Delivery",
      hint: "Goods leaving. Posting a delivery is what takes the stock off the shelf.",
      // Not a verb of this step: a step whose only verb needs
      // sales.despatch would be greyed for everybody who only reads.
      fedBy:
        "Deliveries appear here once one is created from a confirmed sales order: choose the order on the sales order step.",

      typeCode: "delivery",
      // Waiting to leave. Posted, the goods have gone.
      states: ["draft"],
      partyRole: "customer",
      recordArg: "p_delivery_id",
      to: "/logistics",
      toLabel: "Open despatch",
    },
    {
      label: "Invoice",
      hint: "The bill, raised from a posted delivery so it says what actually went.",
      fedBy: "Invoices appear here once a delivery is confirmed and invoiced.",

      typeCode: "sales_invoice",
      // Being raised, or issued and owed. Paid or credited, it is settled.
      states: ["draft", "issued"],
      partyRole: "customer",
      recordArg: "p_invoice_id",
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
};

/** Every verb this screen declares, the chain's and the rest. */
const SELLING_VERBS: ActionSpec[] = [...SALES_ACTIONS, DELIVER_THIS_ORDER];

/** The verbs no step of the chain carries. */
const BESIDE_THE_CHAIN: ActionSpec[] = unstagedActions(ORDER_TO_CASH, SELLING_VERBS);

function Sales() {
  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title="Sales">
        Selling something and being paid for it: quote a customer, take the order, pick and deliver
        the goods, invoice what actually went, and apply the cash against it.
      </PageHeader>

      <KpiRow kpis={SALES_KPIS} />

      <ProcessFlow flow={ORDER_TO_CASH} actions={SELLING_VERBS} />

      <ActionBar
        title="The rest of selling"
        note="Work that sits beside the chain above rather than on it: stock reservations, credit limits and holds, and customer returns."
        actions={BESIDE_THE_CHAIN}
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
                { p_type_code: "sales_order", p_limit: 100, p_actionable: true },
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
                { p_type_code: "sales_order", p_limit: 100, p_actionable: true },
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
              // Lines of an order still being prepared. Once an order is
              // confirmed its reservations and picks say where the stock comes
              // from, and the door refuses a line of a committed, cancelled or
              // finished order.
              pickLine("sales_order", "p_line_id", "Sales order line", {
                openOnly: true,
                states: ["draft", "pending_approval"],
              }),
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
          // erp.return_reason_analysis() carries no currency, so this is the
          // organisation's, as moneyCell() defaults it — still pounds and pence
          // rather than a count of pence.
          { header: "Value", cell: moneyCell("value_minor"), numeric: true },
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
    </div>
  );
}
