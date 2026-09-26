import { createFileRoute } from "@tanstack/react-router";

import { ActionBar, pickDocument } from "../../components/erp/actions-bar";
import { DecisionMoves } from "../../components/erp/decision-moves";
import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { DataPanel, Pill, Table } from "../../components/erp/panel";
import { useT } from "../../lib/i18n";
import { formatMinor } from "../../lib/money";
import { ADJUSTMENT_INVALIDATES, RAISE_STOCK_ADJUSTMENT } from "../../lib/modules";

export const Route = createFileRoute("/inventory/adjustments")({
  head: () => ({
    meta: [
      { title: "Stock adjustments — Clove ERP" },
      {
        name: "description",
        content:
          "Make the system agree with the shelf. A stock adjustment carries the day the count was taken, the reason the stock changed, and, over the organisation's threshold, an approval before anything is written.",
      },
      { property: "og:title", content: "Stock adjustments — Clove ERP" },
      {
        property: "og:description",
        content:
          "Count variances, damage, theft and samples, each dated the day it was found rather than the day it was keyed in, with the cost reaching that month's profit and loss.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <StockAdjustments />
    </Gate>
  ),
});

type AdjustmentRow = {
  document_id: string;
  document_number: string;
  state: string | null;
  site: string | null;
  adjusted_on: string;
  reason_code: string | null;
  reason_note: string | null;
  lines: number;
  found: number;
  missing: number;
  cost_minor: number;
  currency: string | null;
};

/**
 * The tone of an adjustment's state. A draft is the one worth colouring: it has
 * changed nothing and will keep changing nothing until somebody approves it,
 * which is the fact people most often miss about this screen. One waiting for
 * its approver has changed nothing either.
 */
function stateTone(state: string | null): "ok" | "warn" | "muted" {
  if (state === "posted") return "ok";
  if (state === "draft" || state === "pending_approval") return "warn";
  return "muted";
}

function StockAdjustments() {
  const { ui } = useT();
  const invalidates = ADJUSTMENT_INVALIDATES;

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader
        title={ui("Stock adjustments")}
        howItWorks={ui(
          "An adjustment carries the date the count was taken and the reason it changed, and over the organisation's threshold it waits for an approval before anything is written. Its cost is counted on the day the count was taken, not the day it was typed in.",
        )}
      >
        {ui("Making the system agree with the shelf.")}
      </PageHeader>

      <ActionBar
        title="Raise and post an adjustment"
        note="An adjustment is posted as it is raised unless it is worth more than the organisation's threshold, or gives a reason set up to need approval once a threshold is set: then it waits for somebody else to approve it, and is posted as they do. Dating one before today needs the permission to post to the ledger as well, and a closed period refuses it outright."
        actions={[
          RAISE_STOCK_ADJUSTMENT,
          {
            label: "Confirm a stock adjustment",
            title: "Write the count into the books",
            description:
              "Moves the stock and posts the cost to the stock adjustments account, both dated the day the count was taken. What the stock is worth is taken from the books as they stand now: an adjustment dated in the past does not change what earlier despatches were valued at, and no ERP can, because what a despatch took out of stock was recorded once and the layers are gone.",
            permission: "inventory.adjust",
            fn: "erp_post_stock_adjustment",
            fields: [
              pickDocument("stock_adjustment", "p_document_id", "Stock adjustment", true, {
                transition: "post",
              }),
            ],
            invalidates,
          },
        ]}
      />

      <DataPanel<AdjustmentRow>
        title={ui("Stock adjustments")}
        description={ui(
          "Every adjustment with the day the count was taken, its reason, what was found and what was missing, and what the change was worth on the books.",
        )}
        fn="erp_stock_adjustments"
        empty={ui(
          "No adjustments yet. Raise one above when a count finds the shelf and the system disagreeing.",
        )}
      >
        {(rows) => (
          <Table
            columns={[
              ui("Number"),
              ui("Site"),
              ui("Date"),
              ui("State"),
              ui("Reason"),
              ui("Found"),
              ui("Missing"),
              ui("Worth"),
            ]}
          >
            {rows.map((r) => (
              <tr key={r.document_id} className="border-b border-border/60 last:border-0">
                <td className="py-2 pr-4 font-mono text-xs">{r.document_number}</td>
                <td className="py-2 pr-4 font-mono text-xs">{r.site ?? "—"}</td>
                <td className="py-2 pr-4 tabular-nums">{r.adjusted_on}</td>
                <td className="py-2 pr-4">
                  <Pill tone={stateTone(r.state)}>{r.state ?? "—"}</Pill>
                  {/* Approve and Reject, on an adjustment waiting for its
                      approver, to the people its approval asked (PR11 M6).
                      Nothing is drawn until the lifecycle has such a state. */}
                  <DecisionMoves
                    documentId={r.document_id}
                    documentNumber={r.document_number}
                    documentType="stock_adjustment"
                    state={r.state}
                    invalidates={invalidates}
                  />
                </td>
                <td className="py-2 pr-4 font-mono text-xs" title={r.reason_note ?? undefined}>
                  {r.reason_code ?? "—"}
                </td>
                <td className="py-2 pr-4 tabular-nums">{r.found}</td>
                <td className="py-2 pr-4 tabular-nums">{r.missing}</td>
                <td className="py-2 pr-4 tabular-nums">
                  {r.cost_minor === 0 ? "—" : formatMinor(r.cost_minor, r.currency ?? "GBP")}
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>
    </div>
  );
}
