import { createFileRoute } from "@tanstack/react-router";

import { ActionBar, pickDocument, pickSite } from "../../components/erp/actions-bar";
import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { DataPanel, Pill, Table } from "../../components/erp/panel";
import { useT } from "../../lib/i18n";
import { formatMinor } from "../../lib/money";

export const Route = createFileRoute("/inventory/adjustments")({
  head: () => ({
    meta: [
      { title: "Stock adjustments — Clove ERP" },
      {
        name: "description",
        content:
          "Make the system agree with the shelf. A stock adjustment carries the day the count was taken, the reason the stock changed, and an approval before anything is written.",
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
 * which is the fact people most often miss about this screen.
 */
function stateTone(state: string | null): "ok" | "warn" | "muted" {
  if (state === "posted") return "ok";
  if (state === "draft") return "warn";
  return "muted";
}

function StockAdjustments() {
  const { ui } = useT();
  const invalidates = [
    "erp_stock_adjustments",
    "erp_stock_health",
    "erp_stock_valuation",
    "erp_trial_balance",
  ];

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={ui("Stock adjustments")}>
        {ui(
          "Making the system agree with the shelf. An adjustment carries the date the count was taken, the reason it changed, and an approval before anything is written — and its cost reaches the stock adjustments account in your profit and loss on that date, not on the day it was keyed in.",
        )}
      </PageHeader>

      <ActionBar
        title="Raise and post an adjustment"
        note="An adjustment is approved before anything is written, because a write-off nobody agreed to is stock disappearing off the books. Dating one before today needs the permission to post to the ledger as well, and a closed period refuses it outright."
        actions={[
          {
            label: "Raise a stock adjustment",
            title: "Say what the stock really is",
            description:
              "Nothing changes yet: the adjustment is a draft until it is approved and posted. Quantities are what you found, not what you want to change by — put stock found as a positive number and stock missing as a negative one.",
            permission: "inventory.adjust",
            fn: "erp_raise_stock_adjustment",
            fields: [
              {
                ...pickSite("p_site_id", "Which shelf"),
                hint: "The site whose stock the count was taken at.",
              },
              // A combo, not a select: the register is offered, and a reason of
              // the warehouse's own words on the day is still possible, which
              // is what erp_check_reason_code allows for a code nobody keeps.
              {
                kind: "combo",
                name: "p_reason_code",
                label: "Why it changed",
                required: true,
                placeholder: "COUNT_VARIANCE",
                hint: "Pick a reason from the register, or type one of your own. Some reasons are set up to need a note beside them.",
                options: {
                  fn: "erp_reason_codes",
                  value: "code",
                  label: ["category", "code", "name"],
                },
              },
              {
                kind: "text",
                name: "p_note",
                label: "What happened",
                required: false,
                placeholder: "A pallet went over in the racking",
                hint: "Say what happened, in a sentence. Some reasons are set up to require this.",
              },
              {
                kind: "rows",
                name: "p_lines",
                label: "What the count found",
                addLabel: "Add a product",
                hint: "One row per product. Positive for stock found, negative for stock missing. No prices: what the change is worth is whatever the books already say the stock is worth.",
                columns: [
                  {
                    name: "item_id",
                    label: "Product",
                    kind: "select",
                    options: { fn: "erp_items", value: "item_id", label: ["code", "name"] },
                  },
                  { name: "quantity", label: "Change", kind: "number", placeholder: "-2" },
                ],
              },
              {
                kind: "date",
                name: "p_adjusted_on",
                label: "When the count was taken",
                hint: "The day the fact was true, which is not always today. A date before today needs the permission to post to the ledger, because it moves cost between months; a closed month refuses it; and a date after today is refused outright.",
              },
            ],
            invalidates,
          },
          {
            label: "Post a stock adjustment",
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
