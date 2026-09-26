import { createFileRoute } from "@tanstack/react-router";

import { ActionBar, pickDocument } from "../../components/erp/actions-bar";
import { DecisionMoves } from "../../components/erp/decision-moves";
import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { DataPanel, Pill, Table } from "../../components/erp/panel";
import { useT } from "../../lib/i18n";
import { formatMinor } from "../../lib/money";
import { RAISE_TRANSFER_ORDER, TRANSFER_INVALIDATES } from "../../lib/modules";

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
 * fact a warehouse most often has to be told twice. Waiting for approval is
 * the other: nothing can be loaded until somebody else decides it
 * (20260928200000). Discrepancy is kept for a transfer raised before then.
 */
function stateTone(state: string | null): "ok" | "warn" | "muted" {
  if (state === "received" || state === "closed") return "ok";
  if (state === "in_transit" || state === "pending_approval" || state === "discrepancy") {
    return "warn";
  }
  return "muted";
}

function SiteTransfers() {
  const { ui } = useT();
  const invalidates = TRANSFER_INVALIDATES;

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader
        title={ui("Site transfers")}
        howItWorks={ui(
          "The goods leave the first site's shelves when they are loaded and stay that site's stock, at the same value, until they are booked in at the other end.",
        )}
      >
        {ui("Moving stock from one of your warehouses to another.")}
      </PageHeader>

      <ActionBar
        title="Raise and move a transfer"
        note="A transfer order is approved before anything leaves a shelf, despatched when the lorry is loaded, and received when it arrives. The value crosses at the last step, in one figure, so both sites always add up to what the company holds."
        actions={[
          RAISE_TRANSFER_ORDER,
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
                  {/* Approve and Reject, on a transfer over its threshold,
                      to the people its approval asked (PR11 M6). */}
                  <DecisionMoves
                    documentId={r.document_id}
                    documentNumber={r.document_number}
                    documentType="transfer_order"
                    state={r.state}
                    invalidates={invalidates}
                  />
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
