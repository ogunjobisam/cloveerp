import { createFileRoute } from "@tanstack/react-router";

import { ActionBar, pickDocument, pickSite } from "../../components/erp/actions-bar";
import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { DataPanel, Pill, Table } from "../../components/erp/panel";
import { useT } from "../../lib/i18n";
import { formatMinor } from "../../lib/money";

export const Route = createFileRoute("/inventory/transfers")({
  head: () => ({
    meta: [
      { title: "Site transfers — Clove ERP" },
      {
        name: "description",
        content:
          "Move stock between your own warehouses: raise a transfer order, despatch it, and book it in when it arrives. Both sites' quantities and both sites' valuations stay right.",
      },
      { property: "og:title", content: "Site transfers — Clove ERP" },
      {
        property: "og:description",
        content:
          "Stock leaves one depot's shelves, stands in transit while it travels, and arrives on another's — carrying its value with it and touching no profit or loss account.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <SiteTransfers />
    </Gate>
  ),
});

type TransferRow = {
  document_id: string;
  document_number: string;
  state: string | null;
  from_site: string | null;
  to_site: string | null;
  document_date: string;
  required_date: string | null;
  lines: number;
  quantity: number;
  in_transit: number;
  value_moved_minor: number;
  currency: string | null;
};

/**
 * The tone of a transfer's state. On the road is the one worth colouring:
 * that stock is the despatching site's and pickable by nobody, which is the
 * fact a warehouse most often has to be told twice.
 */
function stateTone(state: string | null): "ok" | "warn" | "muted" {
  if (state === "received" || state === "closed") return "ok";
  if (state === "in_transit" || state === "discrepancy") return "warn";
  return "muted";
}

function SiteTransfers() {
  const { ui } = useT();
  const invalidates = ["erp_transfer_orders", "erp_stock_health", "erp_stock_valuation"];

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={ui("Site transfers")}>
        {ui(
          "Moving stock from one of your warehouses to another. The goods leave the first site's shelves when they are loaded and stand in that site's transit place, still its stock and still its value, until they are booked in at the other end. Nothing is bought or sold on the way, so no profit or loss account moves.",
        )}
      </PageHeader>

      <ActionBar
        title="Raise and move a transfer"
        note="A transfer order is approved before anything leaves a shelf, despatched when the lorry is loaded, and received when it arrives. The value crosses at the last step, in one figure, so both sites always add up to what the company holds."
        actions={[
          {
            label: "Raise a transfer order",
            title: "Send stock to another site",
            description:
              "Both sites must belong to the same company. Nothing moves yet: the order is a draft until it is approved.",
            permission: "inventory.move",
            fn: "erp_raise_transfer_order",
            fields: [
              {
                ...pickSite("p_from_site_id", "From site"),
                hint: "Where the goods are now.",
              },
              {
                ...pickSite("p_to_site_id", "To site"),
                hint: "Where the goods are going. A different site, and the same company.",
              },
              {
                kind: "rows",
                name: "p_lines",
                label: "What is being moved",
                addLabel: "Add a product",
                hint: "One row per product. No prices: a transfer moves goods at what they already cost.",
                columns: [
                  {
                    name: "item_id",
                    label: "Product",
                    kind: "select",
                    options: { fn: "erp_items", value: "item_id", label: ["code", "name"] },
                  },
                  { name: "quantity", label: "Quantity", kind: "number", placeholder: "20" },
                ],
              },
              {
                kind: "date",
                name: "p_required_date",
                label: "Needed by",
                hint: "Optional. When the other site needs them.",
              },
              {
                kind: "text",
                name: "p_reference",
                label: "Reference",
                placeholder: "CON-4471",
                hint: "Optional. A consignment note or your own reference.",
              },
            ],
            invalidates,
          },
          {
            label: "Despatch a transfer",
            title: "Load the goods",
            description:
              "Takes the goods off the despatching site's shelves and stands them in that site's transit place. They are still that site's stock and still its value until they arrive.",
            permission: "inventory.move",
            fn: "erp_despatch_transfer",
            fields: [pickDocument("transfer_order", "p_document_id", "Transfer order")],
            invalidates,
          },
          {
            label: "Receive a transfer",
            title: "Book the goods in",
            description:
              "Books the goods onto the receiving site's shelves. The quantity and the value both cross here, for the same figure, so the company holds exactly what it held before.",
            permission: "inventory.move",
            fn: "erp_receive_transfer",
            fields: [pickDocument("transfer_order", "p_document_id", "Transfer order")],
            invalidates,
          },
        ]}
      />

      <DataPanel<TransferRow>
        title={ui("Transfer orders")}
        description={ui(
          "Every transfer with both its sites, what it is moving, how much of that is on the road right now, and what the receiving site was given for it.",
        )}
        fn="erp_transfer_orders"
        empty={ui(
          "No transfers yet. Raise one above to move stock from one of your sites to another.",
        )}
      >
        {(rows) => (
          <Table
            columns={[
              ui("Number"),
              ui("From"),
              ui("To"),
              ui("State"),
              ui("Quantity"),
              ui("On the road"),
              ui("Value moved"),
            ]}
          >
            {rows.map((r) => (
              <tr key={r.document_id} className="border-b border-border/60 last:border-0">
                <td className="py-2 pr-4 font-mono text-xs">{r.document_number}</td>
                <td className="py-2 pr-4 font-mono text-xs">{r.from_site ?? "—"}</td>
                <td className="py-2 pr-4 font-mono text-xs">{r.to_site ?? "—"}</td>
                <td className="py-2 pr-4">
                  <Pill tone={stateTone(r.state)}>{r.state ?? "—"}</Pill>
                </td>
                <td className="py-2 pr-4 tabular-nums">{r.quantity}</td>
                <td className="py-2 pr-4 tabular-nums">{r.in_transit}</td>
                <td className="py-2 pr-4 tabular-nums">
                  {r.value_moved_minor === 0
                    ? "—"
                    : formatMinor(r.value_moved_minor, r.currency ?? "GBP")}
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>
    </div>
  );
}
