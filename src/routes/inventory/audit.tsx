import { createFileRoute } from "@tanstack/react-router";

import { ActionBar, codeField, pickFrom } from "../../components/erp/actions-bar";
import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { DataPanel, Pill, Table } from "../../components/erp/panel";
import { useT } from "../../lib/i18n";
import { formatMinor } from "../../lib/money";

export const Route = createFileRoute("/inventory/audit")({
  head: () => ({
    meta: [
      { title: "Stock audit — Clove ERP" },
      {
        name: "description",
        content:
          "Every location holding stock, the quantity and value standing in it, when it was last counted and by how much the count differed.",
      },
      { property: "og:title", content: "Stock audit — Clove ERP" },
      {
        property: "og:description",
        content:
          "Book quantity against counted quantity, location by location, with the variance and what it is worth.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <StockAudit />
    </Gate>
  ),
});

/**
 * The audit is the book beside the count, per place.
 *
 * The count tasks worklist already showed a variance — one task at a time,
 * which is the wrong unit for an audit. An auditor asks about a location, and
 * the answer has to include the locations nobody has counted: a bin with no
 * count task raised against it is invisible in a list of count tasks and is
 * precisely the thing being looked for. So every active location appears here,
 * counted or not, and "never counted" is a state rather than a blank.
 */
type AuditRow = {
  location_id: string;
  location: string;
  location_name: string | null;
  location_type: string;
  is_blocked: boolean;
  count_class: string | null;
  site: string;
  products: number;
  quantity: number;
  value_minor: number;
  currency: string;
  last_counted_at: string | null;
  counted_quantity: number | null;
  variance: number | null;
  variance_value_minor: number;
  counts_open: number;
  state: "counting" | "never counted" | "variance" | "agreed";
};

type AuditLine = {
  location_code: string;
  location_name: string | null;
  site_code: string;
  item_code: string;
  item_name: string | null;
  quantity: number;
  unit_cost_minor: number;
  value_minor: number;
  currency: string;
  last_counted_at: string | null;
  expected_quantity: number | null;
  counted_quantity: number | null;
  variance: number | null;
  variance_value_minor: number;
  count_status: string | null;
};

const day = (iso: string | null) =>
  iso
    ? new Date(iso).toLocaleDateString(undefined, {
        day: "numeric",
        month: "short",
        year: "numeric",
      })
    : "—";

const qty = (n: number | null | undefined) =>
  n == null ? "—" : new Intl.NumberFormat(undefined, { maximumFractionDigits: 3 }).format(n);

/** A variance reads as a signed number, because its direction is the point. */
const signed = (n: number | null | undefined) => {
  if (n == null) return "—";
  if (n === 0) return "0";
  return `${n > 0 ? "+" : ""}${qty(n)}`;
};

const stateTone = (state: AuditRow["state"]) =>
  state === "variance"
    ? "bad"
    : state === "never counted"
      ? "warn"
      : state === "counting"
        ? "muted"
        : "ok";

const countTask = () =>
  pickFrom("erp_count_tasks", "task_id", ["item", "location", "status"], "p_task_id", "Count task");

function StockAudit() {
  const { ui } = useT();
  const invalidates = [
    "erp_stock_audit",
    "erp_stock_audit_lines",
    "erp_count_tasks",
    "erp_count_accuracy",
    "erp_stock_health",
    "erp_stock_valuation",
  ];

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={ui("Stock audit")}>
        {ui(
          "What the book says is standing in each place, what it is worth, and what the last count actually found. A place nobody has counted shows as never counted rather than as agreement — an untested balance is not a verified one. Nothing here changes stock: post a count and the correction is made as a movement, with a reason.",
        )}
      </PageHeader>

      <ActionBar
        title="Counting"
        note="Raise tasks from a counting programme, record what was found, then post it. Posting is what moves the stock: until then the count is an observation, not a correction."
        actions={[
          {
            label: "Raise count tasks",
            description: "Ask a counting programme for its next set of places to count.",
            permission: "inventory.count",
            fn: "erp_raise_count_tasks",
            fields: [codeField("p_programme_code", "Programme", "COUNT-A")],
            invalidates,
          },
          {
            label: "Record a count",
            description: "What the counter found in the place. The variance is worked out from it.",
            permission: "inventory.count",
            fn: "erp_record_count",
            fields: [
              countTask(),
              { kind: "number", name: "p_quantity", label: "Counted quantity", required: true },
            ],
            invalidates,
          },
          {
            label: "Post a count",
            description: "Accept the difference and correct the stock by it.",
            permission: "inventory.count",
            fn: "erp_post_count",
            fields: [countTask()],
            invalidates,
          },
        ]}
      />

      <DataPanel<AuditRow>
        title={ui("Balances by location")}
        description={ui(
          "Every active place at every site, whether or not anything stands in it, with the last count against it.",
        )}
        fn="erp_stock_audit"
        empty={ui(
          "No locations to audit yet. Add locations under Warehouse layout, and receive stock into them, and each one is listed here with its balance.",
        )}
      >
        {(rows) => (
          <Table
            columns={[
              ui("Site"),
              ui("Location"),
              ui("Kind"),
              ui("Products"),
              ui("On hand"),
              ui("Value"),
              ui("Last counted"),
              ui("Counted"),
              ui("Variance"),
              ui("Variance value"),
              ui("State"),
            ]}
          >
            {rows.map((r) => (
              <tr key={r.location_id} className="border-b border-border/60 last:border-0">
                <td className="py-2 pr-4 font-mono text-xs">{r.site}</td>
                <td className="py-2 pr-4">
                  <span className="font-mono text-xs">{r.location}</span>
                  {r.location_name ? (
                    <span className="ml-2 text-muted-foreground">{r.location_name}</span>
                  ) : null}
                </td>
                <td className="py-2 pr-4">{r.location_type}</td>
                <td className="py-2 pr-4 tabular-nums">{r.products}</td>
                <td className="py-2 pr-4 tabular-nums">{qty(r.quantity)}</td>
                <td className="py-2 pr-4 tabular-nums">{formatMinor(r.value_minor, r.currency)}</td>
                <td className="py-2 pr-4">{day(r.last_counted_at)}</td>
                <td className="py-2 pr-4 tabular-nums">{qty(r.counted_quantity)}</td>
                <td className="py-2 pr-4 tabular-nums">{signed(r.variance)}</td>
                <td className="py-2 pr-4 tabular-nums">
                  {r.variance_value_minor === 0
                    ? "—"
                    : formatMinor(r.variance_value_minor, r.currency)}
                </td>
                <td className="py-2 pr-4">
                  <Pill tone={stateTone(r.state)}>
                    {r.is_blocked ? ui("blocked") : ui(r.state)}
                  </Pill>
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<AuditLine>
        title={ui("Balances by product within a location")}
        description={ui(
          "The same audit one line deeper: which product the quantity is, what it costs, and what the last count expected against what it found. Value in a bin is its share of the product's valuation at that site, not a separate cost.",
        )}
        fn="erp_stock_audit_lines"
        empty={ui(
          "No stock standing anywhere and no counts raised. Receive a purchase order and put it away, and the lines appear here.",
        )}
      >
        {(rows) => (
          <Table
            columns={[
              ui("Site"),
              ui("Location"),
              ui("Product"),
              ui("On hand"),
              ui("Unit cost"),
              ui("Value"),
              ui("Expected"),
              ui("Counted"),
              ui("Variance"),
              ui("Last counted"),
              ui("Count"),
            ]}
          >
            {rows.map((l) => (
              <tr
                key={`${l.location_code}:${l.item_code}`}
                className="border-b border-border/60 last:border-0"
              >
                <td className="py-2 pr-4 font-mono text-xs">{l.site_code}</td>
                <td className="py-2 pr-4 font-mono text-xs">{l.location_code}</td>
                <td className="py-2 pr-4">
                  <span className="font-mono text-xs">{l.item_code}</span>
                  {l.item_name ? (
                    <span className="ml-2 text-muted-foreground">{l.item_name}</span>
                  ) : null}
                </td>
                <td className="py-2 pr-4 tabular-nums">{qty(l.quantity)}</td>
                <td className="py-2 pr-4 tabular-nums">
                  {formatMinor(l.unit_cost_minor, l.currency)}
                </td>
                <td className="py-2 pr-4 tabular-nums">{formatMinor(l.value_minor, l.currency)}</td>
                <td className="py-2 pr-4 tabular-nums">{qty(l.expected_quantity)}</td>
                <td className="py-2 pr-4 tabular-nums">{qty(l.counted_quantity)}</td>
                <td className="py-2 pr-4 tabular-nums">{signed(l.variance)}</td>
                <td className="py-2 pr-4">{day(l.last_counted_at)}</td>
                <td className="py-2 pr-4">
                  {l.count_status ? (
                    <Pill tone={l.variance ? "bad" : "muted"}>{l.count_status}</Pill>
                  ) : (
                    <Pill tone="warn">{ui("never counted")}</Pill>
                  )}
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>
    </div>
  );
}
