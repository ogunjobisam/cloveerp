import { createFileRoute } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";

import { ActionButton, ActionDialog } from "../../components/erp/action";
import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { DataPanel, Pill, Table } from "../../components/erp/panel";
import { callErp } from "../../lib/erp";
import { useT } from "../../lib/i18n";

export const Route = createFileRoute("/inventory/forecast")({
  head: () => ({
    meta: [
      { title: "Stock forecast — Clove ERP" },
      {
        name: "description",
        content:
          "Usage per day, lead time, reorder point and days of cover for every stocked product, with the date it must be reordered by and how much to buy.",
      },
      { property: "og:title", content: "Stock forecast — Clove ERP" },
      {
        property: "og:description",
        content:
          "What is running out, when it runs out, and how much to order — measured from what has actually been going out.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <StockForecast />
    </Gate>
  ),
});

/**
 * The buying question, answered in one row.
 *
 * The figures were all on file and none of them were beside each other: the
 * balance in stock, what has been going out, the lead time to replace it and
 * the reorder point the organisation set. A buyer had to hold four screens in
 * their head, which is how a product runs out while its purchase order is
 * still being thought about.
 *
 * Usage here is measured rather than forecast — what actually left over the
 * window. A demand plan is a different instrument, and it lives in Planning.
 */
type ForecastRow = {
  item_id: string;
  item_code: string;
  item_name: string | null;
  site_id: string;
  site_code: string;
  on_hand: number;
  on_order: number;
  demand: number;
  usage_days: number;
  usage_quantity: number;
  usage_per_day: number;
  lead_time_days: number;
  lead_time_demand: number;
  safety_stock: number | null;
  reorder_point: number | null;
  order_up_to: number | null;
  min_order_quantity: number | null;
  order_multiple: number | null;
  supplier: string | null;
  supplier_party_id: string | null;
  days_cover: number | null;
  reorder_by: string | null;
  suggest_quantity: number;
  state: string;
};

/** The configured purchase-order type, and the permission it really needs. */
type DocType = {
  document_type_id: string;
  code: string;
  name: string;
  base_type_code: string;
  create_permission: string;
};

/**
 * The order, raised from the line that says it is needed.
 *
 * The forecast already knows the product, the site, the supplier and how much
 * to buy. Sending the buyer to Purchasing to retype all four is the step this
 * removes: one press, the quantity already filled in, and the order exists.
 */
function OrderAction({ row, type }: { row: ForecastRow; type: DocType | undefined }) {
  const { ui } = useT();

  if (!type) return null;
  if (!row.supplier_party_id)
    return (
      <span className="text-xs text-muted-foreground" title={ui("No supplier is set up for this product")}>
        {ui("No supplier")}
      </span>
    );

  return (
    <ActionDialog
      trigger={<ActionButton variant="secondary">{ui("Order")}</ActionButton>}
      title={ui("Raise a purchase order")}
      description={ui(
        "The supplier, the site and the product come from this line. Only the quantity and the date you need it by are left to confirm.",
      )}
      context={`${row.item_code} → ${row.supplier ?? ""} (${row.site_code})`}
      permission={type.create_permission}
      fn="erp_create_document_full"
      fields={[
        {
          kind: "number",
          name: "quantity",
          label: ui("Quantity"),
          required: true,
          default: String(row.suggest_quantity > 0 ? row.suggest_quantity : ""),
          hint: ui(
            "Suggested from the reorder point, what is already on order and the order multiple.",
          ),
        },
        { kind: "date", name: "required_date", label: ui("Required date") },
      ]}
      mapArgs={(v) => ({
        p_type_code: type.code,
        p_party_id: row.supplier_party_id,
        p_site_id: row.site_id,
        p_required_date: v["required_date"] || null,
        p_lines: [
          {
            item_id: row.item_id,
            quantity: Number(v["quantity"] ?? 0),
            description: row.item_name ?? null,
          },
        ],
      })}
      alsoSubmit={{ label: ui("Create and send"), args: { p_transition: "auto" } }}
      invalidates={["erp_documents", "erp_document", "erp_stock_forecast"]}
      submitLabel={ui("Create")}
    />
  );
}


const qty = (n: number | null | undefined, dp = 2) =>
  n === null || n === undefined
    ? "—"
    : new Intl.NumberFormat(undefined, { maximumFractionDigits: dp }).format(n);

const day = (iso: string | null) =>
  iso
    ? new Date(iso).toLocaleDateString(undefined, {
        day: "numeric",
        month: "short",
        year: "numeric",
      })
    : "—";

const tone = (state: string) =>
  state === "out of stock" || state === "order now"
    ? "bad"
    : state === "below safety"
      ? "warn"
      : state === "covered"
        ? "ok"
        : "muted";

function StockForecast() {
  const { ui } = useT();

  // The tenant's own purchase-order type: its code, and the permission the
  // database will actually check before letting the button raise one.
  const { data: types } = useQuery({
    queryKey: ["erp_document_types", { p_base_type_code: "purchase_order" }],
    queryFn: () =>
      callErp<DocType[]>("erp_document_types", { p_base_type_code: "purchase_order" }),
  });
  const poType = types?.[0];


  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={ui("Stock forecast")}>
        {ui(
          "How fast each product has actually been going out, how long it takes to replace, and therefore when it has to be ordered. Days of cover is the balance divided by the daily usage; the reorder-by date is the day the balance reaches the reorder point, so ordering after it is late by definition. What is already on purchase order is counted, so a product waiting on a delivery is not ordered twice.",
        )}
      </PageHeader>

      <DataPanel<ForecastRow>
        title={ui("What to order, and by when")}
        description={ui(
          "Ordered by urgency. Where no reorder point has been set, the one the product's own history implies is shown instead, so nothing is left unanswerable.",
        )}
        fn="erp_stock_forecast"
        args={{ p_days: 90 }}
        empty={ui(
          "Nothing to forecast yet. A product needs stock, a movement out, or a purchase order against it before there is anything to measure.",
        )}
      >
        {(rows) => (
          <Table
            columns={[
              ui("Site"),
              ui("Product"),
              ui("On hand"),
              ui("On order"),
              ui("Ordered by customers"),
              ui("Used per day"),
              ui("Lead time"),
              ui("Reorder point"),
              ui("Days of cover"),
              ui("Order by"),
              ui("Order quantity"),
              ui("Supplier"),
              ui("State"),
              ui("Order"),
            ]}

          >
            {rows.map((r) => (
              <tr
                key={`${r.site_id}:${r.item_id}`}
                className="border-b border-border/60 last:border-0"
              >
                <td className="py-2 pr-4 font-mono text-xs">{r.site_code}</td>
                <td className="py-2 pr-4">
                  <span className="font-mono text-xs">{r.item_code}</span>
                  {r.item_name ? (
                    <span className="ml-2 text-muted-foreground">{r.item_name}</span>
                  ) : null}
                </td>
                <td className="py-2 pr-4 tabular-nums">{qty(r.on_hand)}</td>
                <td className="py-2 pr-4 tabular-nums">{qty(r.on_order)}</td>
                <td className="py-2 pr-4 tabular-nums">{qty(r.demand)}</td>
                <td className="py-2 pr-4 tabular-nums">{qty(r.usage_per_day, 3)}</td>
                <td className="py-2 pr-4 tabular-nums">
                  {r.lead_time_days ? `${r.lead_time_days}d` : "—"}
                </td>
                <td className="py-2 pr-4 tabular-nums">{qty(r.reorder_point)}</td>
                <td className="py-2 pr-4 tabular-nums">{qty(r.days_cover, 1)}</td>
                <td className="py-2 pr-4">{day(r.reorder_by)}</td>
                <td className="py-2 pr-4 tabular-nums">
                  {r.suggest_quantity > 0 ? qty(r.suggest_quantity) : "—"}
                </td>
                <td className="py-2 pr-4">{r.supplier ?? "—"}</td>
                <td className="py-2 pr-4">
                  <Pill tone={tone(r.state)}>{ui(r.state)}</Pill>
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<ForecastRow>
        title={ui("How the figures were worked out")}
        description={ui(
          "The same products with what sits behind the answer: the quantity measured, over how many days, the demand that falls inside the lead time, and the policy figures the organisation set.",
        )}
        fn="erp_stock_forecast"
        args={{ p_days: 90 }}
        empty={ui("Nothing measured yet, so there is nothing to explain.")}
      >
        {(rows) => (
          <Table
            columns={[
              ui("Site"),
              ui("Product"),
              ui("Used"),
              ui("Over"),
              ui("Used per day"),
              ui("Lead time"),
              ui("Demand in the lead time"),
              ui("Safety stock"),
              ui("Order up to"),
              ui("Minimum"),
              ui("Multiple"),
            ]}
          >
            {rows.map((r) => (
              <tr
                key={`why:${r.site_id}:${r.item_id}`}
                className="border-b border-border/60 last:border-0"
              >
                <td className="py-2 pr-4 font-mono text-xs">{r.site_code}</td>
                <td className="py-2 pr-4 font-mono text-xs">{r.item_code}</td>
                <td className="py-2 pr-4 tabular-nums">{qty(r.usage_quantity)}</td>
                <td className="py-2 pr-4 tabular-nums">{`${r.usage_days}d`}</td>
                <td className="py-2 pr-4 tabular-nums">{qty(r.usage_per_day, 3)}</td>
                <td className="py-2 pr-4 tabular-nums">
                  {r.lead_time_days ? `${r.lead_time_days}d` : "—"}
                </td>
                <td className="py-2 pr-4 tabular-nums">{qty(r.lead_time_demand)}</td>
                <td className="py-2 pr-4 tabular-nums">{qty(r.safety_stock)}</td>
                <td className="py-2 pr-4 tabular-nums">{qty(r.order_up_to)}</td>
                <td className="py-2 pr-4 tabular-nums">{qty(r.min_order_quantity)}</td>
                <td className="py-2 pr-4 tabular-nums">{qty(r.order_multiple)}</td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>
    </div>
  );
}
