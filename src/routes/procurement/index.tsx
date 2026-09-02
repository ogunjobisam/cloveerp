import { createFileRoute } from "@tanstack/react-router";

import {
  ActionBar,
  pickFrom,
  pickItem,
  pickLine,
  pickParty,
  pickSite,
} from "../../components/erp/actions-bar";
import { DocumentPanel } from "../../components/erp/documents";
import { Gate } from "../../components/erp/gate";
import { KpiRow } from "../../components/erp/kpi";
import { PageHeader } from "../../components/erp/page";
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
function Procurement() {
  const { t } = useT();

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={t("nav.procurement", "Purchasing")}>
        Requisition to purchase order to receipt. Receiving posts stock inbound through the same
        bridge a delivery uses outbound.
      </PageHeader>

      <KpiRow kpis={PURCHASING_KPIS} />

      <ActionBar
        note="Receiving, matching and supplier qualification — the verbs between the documents."
        actions={[
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
              pickFrom("erp_batches", "batch_id", ["batch_number", "item"], "p_batch_id", "Batch"),
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
            label: "Resolve a purchase price",
            description: "What should this supplier charge for this item today, and on what basis?",
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
            fields: [pickParty("supplier"), { kind: "text", name: "p_note", label: "Note" }],
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
