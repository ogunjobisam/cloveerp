import { createFileRoute } from "@tanstack/react-router";

import {
  ActionBar,
  pickBatch,
  pickFrom,
  pickItem,
  pickLine,
  pickParty,
  pickSite,
  type ActionSpec,
} from "../../components/erp/actions-bar";
import { DocumentPanel } from "../../components/erp/documents";
import { Gate } from "../../components/erp/gate";
import { InquiryBoard } from "../../components/erp/inquiry";
import { KpiRow } from "../../components/erp/kpi";
import { PageHeader } from "../../components/erp/page";
import { ProcessFlow } from "../../components/erp/process-flow";
import { PURCHASING_KPIS } from "../../lib/modules";
import { useT } from "../../lib/i18n";

export const Route = createFileRoute("/procurement/")({
  head: () => ({
    meta: [
      { title: "Purchasing — Clove ERP" },
      {
        name: "description",
        content: "Requisitions, RFQs, purchase orders, receipts and three-way match.",
      },
      { property: "og:title", content: "Purchasing — Clove ERP" },
      {
        property: "og:description",
        content: "Requisitions, RFQs, purchase orders, receipts and three-way match.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
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
const PROCUREMENT_ACTIONS: ActionSpec[] = [
  {
    label: "Convert to a purchase order",
    title: "Turn this requisition into a purchase order",
    description:
      "An approved requisition becomes an order to a supplier. Every line still outstanding is carried across, and the order remembers the requisition it came from — so a part order can be finished later.",
    permission: "procurement.order",
    fn: "erp_convert_document",
    fields: [
      pickParty("provider", "p_party_id", "Supplier", true),
      pickSite("p_site_id", "Site the goods are for", false),
    ],
    emptyNote:
      "Only an approved requisition converts. Submit it and have it approved at this step first.",
    invalidates: ["erp_documents", "erp_commitments"],
    submitLabel: "Create the purchase order",
  },
  {
    label: "Bill a receipt",
    description:
      "The supplier's bill, raised from a posted goods receipt: the quantities and the prices are what arrived, not what somebody typed.",
    permission: "procurement.match",
    fn: "erp_bill_from_receipt",
    fields: [
      pickFrom(
        "erp_documents",
        "document_id",
        ["document_number", "state"],
        "p_receipt_id",
        "Goods receipt",
        { p_type_code: "goods_receipt", p_limit: 100 },
      ),
      {
        kind: "text",
        name: "p_their_reference",
        label: "Supplier's invoice number",
        placeholder: "INV-88213",
        hint: "The number printed on their bill, so it can be matched later.",
      },
      { kind: "date", name: "p_invoice_date", label: "Invoice date" },
      { kind: "date", name: "p_due_date", label: "Due date" },
    ],
    invalidates: [
      "erp_documents",
      "erp_grni",
      "erp_match_workbench",
      "erp_supplier_balances",
      "erp_payables_ageing",
    ],
  },
  {
    label: "Receive against an order",
    permission: "procurement.receive",
    fn: "erp_receive_against",
    fields: [
      pickFrom(
        "erp_documents",
        "document_id",
        ["document_number", "status"],
        "p_receipt_id",
        "Receipt",
        { p_limit: 100 },
      ),
      pickLine("purchase_order"),
      { kind: "number", name: "p_quantity", label: "Quantity", required: true },
      pickBatch(),
    ],
    invalidates: ["erp_grni", "erp_match_workbench"],
  },
  {
    label: "Invoice against an order",
    permission: "procurement.match",
    fn: "erp_invoice_against",
    fields: [
      pickFrom(
        "erp_documents",
        "document_id",
        ["document_number", "status"],
        "p_invoice_id",
        "Invoice",
        { p_limit: 100 },
      ),
      pickLine("purchase_order"),
      { kind: "number", name: "p_quantity", label: "Quantity", required: true },
      {
        kind: "number",
        name: "p_unit_price_minor",
        label: "Unit price",
        hint: "In minor units — pence, cents.",
      },
    ],
    invalidates: ["erp_match_workbench", "erp_grni"],
  },
  {
    label: "Set an order's behaviour",
    description:
      "Standard, blanket, consignment, drop-ship or intercompany. Fixed once the order is sent.",
    permission: "procurement.order",
    fn: "erp_set_order_behaviour",
    fields: [
      pickFrom(
        "erp_documents",
        "document_id",
        ["document_number", "state"],
        "p_document_id",
        "Purchase order",
        { p_type_code: "purchase_order", p_limit: 100 },
      ),
      pickFrom("erp_order_behaviours", "code", ["name"], "p_behaviour", "Behaviour"),
      {
        kind: "date",
        name: "p_valid_to",
        label: "Blanket agreement runs to",
        hint: "For a blanket order only.",
      },
    ],
    invalidates: ["erp_documents", "erp_document"],
  },
  {
    label: "Call off a blanket order",
    description:
      "Raises a standard purchase order against the agreement. Each line consumes a blanket line.",
    permission: "procurement.order",
    fn: "erp_call_off_blanket_order",
    fields: [
      pickFrom(
        "erp_documents",
        "document_id",
        ["document_number", "state"],
        "p_blanket_id",
        "Blanket order",
        { p_type_code: "purchase_order", p_limit: 100 },
      ),
      {
        kind: "text",
        name: "p_lines",
        label: "Lines",
        required: true,
        hint: 'JSON: [{"line_id": "…", "quantity": 10, "required_date": "2026-10-01"}]. The Blanket position question lists the line ids.',
      },
    ],
    mapArgs: (v) => ({
      p_blanket_id: v["p_blanket_id"],
      p_lines: JSON.parse(v["p_lines"] ?? "[]"),
    }),
    invalidates: ["erp_documents"],
  },
  {
    label: "Confirm a drop-ship",
    description:
      "The supplier delivered straight to the customer: both the purchase and the sales order are fulfilled, and no stock moves here.",
    permission: "procurement.receive",
    fn: "erp_confirm_drop_ship",
    fields: [
      pickFrom(
        "erp_documents",
        "document_id",
        ["document_number", "state"],
        "p_purchase_order_id",
        "Drop-ship order",
        { p_type_code: "purchase_order", p_limit: 100 },
      ),
      { kind: "date", name: "p_delivered_on", label: "Delivered on", required: true },
      {
        kind: "text",
        name: "p_reference",
        label: "Carrier reference",
        placeholder: "DPD-4471882",
        hint: "Optional. The consignment or tracking number.",
      },
    ],
    invalidates: ["erp_documents", "erp_document"],
  },
  {
    label: "Route an approval by value",
    description:
      "Stamp which chain a value in a currency would route to, for a department, before raising the document.",
    permission: "procurement.order",
    fn: "erp_stamp_approval_routing",
    fields: [
      {
        kind: "choice",
        name: "p_object_type",
        label: "Object",
        required: true,
        choices: [{ value: "document", label: "Document" }],
      },
      {
        kind: "text",
        name: "p_object_id",
        label: "Object id",
        required: true,
        placeholder: "0f9c1a2e-…",
        hint: "The id of the document being routed. Copy it from the document page.",
      },
      {
        kind: "number",
        name: "p_value_minor",
        label: "Value (minor units)",
        required: true,
      },
      {
        kind: "combo",
        name: "p_currency",
        label: "Currency",
        required: true,
        options: { fn: "erp_currencies", value: "code", label: ["code", "name"] },
      },
      pickFrom(
        "erp_departments",
        "department_id",
        ["code", "name"],
        "p_department_id",
        "Department",
        undefined,
        false,
      ),
    ],
    invalidates: ["erp_document_approval_chain"],
  },
  {
    label: "Resolve a purchase price",
    description: "What should this supplier charge for this product today, and on what basis?",
    permission: "procurement.order",
    fn: "erp_resolve_purchase_price",
    fields: [
      pickItem(),
      pickParty("supplier"),
      { kind: "number", name: "p_quantity", label: "Quantity" },
      pickSite("p_site_id", "Site", false),
    ],
  },
  {
    label: "Qualify a supplier",
    permission: "procurement.order",
    fn: "erp_qualify_supplier",
    fields: [
      pickParty("supplier"),
      {
        kind: "text",
        name: "p_note",
        label: "Note",
        placeholder: "Audit passed, approved for food-grade supply",
        hint: "Why this supplier is qualified.",
      },
    ],
    invalidates: ["erp_supplier_qualification"],
  },
  {
    label: "Allocate a landed cost",
    permission: "procurement.match",
    fn: "erp_allocate_landed_cost",
    fields: [
      pickFrom(
        "erp_landed_costs",
        "landed_cost_id",
        ["charge_code", "description", "receipt"],
        "p_landed_cost_id",
        "Landed cost",
      ),
    ],
  },
];

function Procurement() {
  const { t } = useT();

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={t("nav.procurement", "Purchasing")}>
        Requisition to purchase order to receipt. Receiving posts stock inbound through the same
        bridge a delivery uses outbound.
      </PageHeader>

      <KpiRow kpis={PURCHASING_KPIS} />

      <ProcessFlow
        flow={{
          title: "Purchase to pay, step by step",
          note: "Press a step to see the records sitting there, choose one on the left, and the buttons act on that record.",
          stages: [
            {
              label: "Requisition",
              hint: "Somebody asking for something, before anyone has committed to buying it.",
              fedBy: "Requisitions appear here once somebody raises one.",

              typeCode: "requisition",
              partyRole: "provider",
              recordArg: "p_document_id",
              actionFn: "erp_convert_document",
            },
            {
              label: "Purchase order",
              hint: "The commitment to a supplier. Value bands decide what needs approving before it is sent.",
              fedBy:
                "Orders appear here once a requisition is turned into one, or a planned order is firmed.",

              typeCode: "purchase_order",
              partyRole: "provider",
              recordArg: "p_document_id",
              actionFn: "erp_set_order_behaviour",
            },
            {
              label: "Goods receipt",
              hint: "What arrived. Posting a receipt is what puts stock on the shelf and raises the accrual.",
              fedBy: "Receipts appear here once goods are received against a purchase order.",

              typeCode: "goods_receipt",
              partyRole: "provider",
              recordArg: "p_receipt_id",
              actionFn: "erp_receive_against",
              actionFns: ["erp_bill_from_receipt"],
            },
            {
              label: "Supplier bill",
              hint: "Their invoice, matched to the receipt so the accrual clears and the balance is owed.",
              fedBy: "Bills appear here once a goods receipt is billed at the goods receipt step.",

              typeCode: "purchase_invoice",
              partyRole: "provider",
              recordArg: "p_invoice_id",
              actionFn: "erp_invoice_against",
              createFn: "erp_bill_from_receipt",
            },
            {
              label: "Payment",
              hint: "Bills fall into a payment run, which somebody else approves before it is paid.",
              to: "/finance",
              toLabel: "Open finance",
            },
          ],
        }}
        actions={PROCUREMENT_ACTIONS}
      />

      <ActionBar
        title="Goods-in, matching and qualification"
        note="Goods-in, matching and supplier qualification — the verbs between the documents."
        actions={PROCUREMENT_ACTIONS}
      />

      <InquiryBoard
        inquiries={[
          {
            label: "Blanket position",
            description:
              "What was agreed on a blanket order, what the call-offs have consumed, and what is left, line by line.",
            permission: "procurement.read",
            fn: "erp_blanket_position",
            fields: [
              pickFrom(
                "erp_documents",
                "document_id",
                ["document_number", "state"],
                "p_blanket_id",
                "Blanket order",
                { p_type_code: "purchase_order", p_limit: 100 },
              ),
            ],
          },
        ]}
      />

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
        empty="No purchase orders yet. New raises one, or convert a requisition from the panel above."
      />

      <DocumentPanel
        title="Goods receipts"
        description="Goods arriving. Posting one is what puts the stock on the shelf and raises the GRNI accrual."
        baseType="receipt"
        partyRole="supplier"
        empty="No receipts yet. A receipt is recorded against a purchase order, and posting it is what puts stock on hand."
      />

      <DocumentPanel
        title="Purchase invoices"
        description="The supplier's bill. Registering one clears the goods-received accrual and puts the balance on the supplier."
        baseType="invoice_reference"
        typeCode="purchase_invoice"
        partyRole="supplier"
        empty="No supplier bills yet. Bill a posted goods receipt from the actions above."
      />
    </div>
  );
}
