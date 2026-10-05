import { createFileRoute } from "@tanstack/react-router";

import {
  ActionBar,
  pickCurrency,
  pickFrom,
  pickItem,
  pickParty,
  reason,
} from "../../components/erp/actions-bar";
import { Gate } from "../../components/erp/gate";
import { InquiryBoard } from "../../components/erp/inquiry";
import { PageHeader } from "../../components/erp/page";
import { DataPanel, Pill, Table } from "../../components/erp/panel";
import { ConfigTransfer } from "../../components/erp/transfer";
import { useT } from "../../lib/i18n";
import { formatMinor } from "../../lib/money";

export const Route = createFileRoute("/master-data/item-supply")({
  head: () => ({
    meta: [
      { title: "Product-suppliers — Clove ERP" },
      {
        name: "description",
        content:
          "Who each product is bought from, at what preference and split, per site — with approved-supplier enforcement on regulated products.",
      },
      { property: "og:title", content: "Product-suppliers — Clove ERP" },
      {
        property: "og:description",
        content:
          "Default suppliers, preference ranks, sourcing splits, lead times and approved-for-use status for every purchased product.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <ItemSupply />
    </Gate>
  ),
});

type SupplierRow = {
  item_supplier_id: string;
  item_code: string;
  item_name: string;
  supplier: string;
  site_code: string | null;
  preference_rank: number;
  is_default: boolean;
  split_pct: number | null;
  is_approved_for_use: boolean;
  supplier_item_code: string | null;
  lead_time_days: number | null;
  min_order_quantity: number | null;
  valid_from: string;
  valid_to: string | null;
  status: string;
};

/** One price a supplier charges for a product, from erp_supplier_prices. */
type SupplierPriceRow = {
  item_price_id: string;
  item_code: string;
  item_name: string;
  supplier: string;
  amount_minor: number;
  currency: string;
  minor_units: number;
  min_quantity: number;
  valid_from: string;
  valid_to: string | null;
  state: "in_force" | "starts_later" | "ended";
};

function ItemSupply() {
  const { ui } = useT();
  const invalidates = ["erp_item_suppliers"];
  const pricesChanged = ["erp_supplier_prices", "erp_resolve_purchase_price"];

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader
        title={ui("Product-suppliers")}
        howItWorks={ui(
          "A regulated product cannot default to a supplier that is not on the approved list, and the shares recorded against a product's suppliers may not add to more than the whole.",
        )}
      >
        {ui(
          "One supplier is the default for a product at a site; the rest are ranked alternatives.",
        )}
      </PageHeader>

      <ConfigTransfer
        objectType="item_supplier"
        title="Default suppliers as a file"
        description="Products, business partners and sites are named by code, so a file written elsewhere still loads here."
        invalidates={["erp_item_suppliers", "erp_supplier_qualification"]}
      />

      <ActionBar
        title="Supplier defaults"
        note="Set the default once. Replenishment, planning and manual purchasing all resolve through it, so a missing default is a stopped order, not a silent guess."
        actions={[
          {
            label: "Set or amend a supplier for a product",
            permission: "master_data.write",
            fn: "erp_set_item_supplier",
            fields: [
              pickItem(),
              { ...pickParty("supplier", "p_party_id", "Supplier"), required: true },
              { kind: "site", name: "p_site_id", label: "Site (leave empty for everywhere)" },
              { kind: "number", name: "p_preference_rank", label: "Preference rank" },
              {
                kind: "choice",
                name: "p_is_default",
                label: "Default supplier",
                boolean: true,
                choices: [
                  { value: "true", label: "Yes" },
                  { value: "false", label: "No" },
                ],
              },
              {
                kind: "number",
                name: "p_split_pct",
                label: "Sourcing split (%)",
                hint: "A share recorded for the buyer, not a division the system performs: purchasing resolves one supplier. The shares against a product may not add to more than the whole.",
              },
              {
                kind: "choice",
                name: "p_is_approved_for_use",
                label: "Approved for use",
                boolean: true,
                choices: [
                  { value: "true", label: "Yes" },
                  { value: "false", label: "No" },
                ],
              },
              {
                kind: "text",
                name: "p_supplier_item_code",
                label: "Supplier's own code",
                placeholder: "NW-4471",
                hint: "What the supplier calls this product on their paperwork.",
              },
              { kind: "number", name: "p_lead_time_days", label: "Lead time (days)" },
              { kind: "number", name: "p_min_order_quantity", label: "Minimum order quantity" },
              reason(),
            ],
            invalidates,
          },
          {
            label: "End a supplier relationship",
            permission: "master_data.write",
            fn: "erp_end_item_supplier",
            fields: [
              pickFrom(
                "erp_item_suppliers",
                "item_supplier_id",
                ["item_code", "supplier"],
                "p_item_supplier_id",
                "Product and supplier",
              ),
              { ...reason(), required: true },
            ],
            invalidates,
          },
        ]}
      />

      <DataPanel<SupplierRow>
        title={ui("Suppliers by product")}
        description={ui(
          "Rank one is used unless a site-specific row overrides it. An unapproved row is never resolved.",
        )}
        fn="erp_item_suppliers"
        empty={ui(
          "No product has a supplier yet, so purchasing cannot resolve where to buy anything. Set one under Supplier defaults above.",
        )}
      >
        {(rows) => (
          <Table
            columns={[
              ui("Product"),
              ui("Name"),
              ui("Supplier"),
              ui("Supplier's own code"),
              ui("Site"),
              ui("Rank"),
              ui("Default"),
              ui("Split"),
              ui("Approved"),
              ui("Days to arrive"),
              ui("Minimum"),
              ui("Status"),
            ]}
          >
            {rows.map((r) => (
              <tr key={r.item_supplier_id} className="border-b border-border/60 last:border-0">
                <td className="py-2 pr-4 font-mono text-xs">{r.item_code}</td>
                <td className="py-2 pr-4">{r.item_name}</td>
                <td className="py-2 pr-4">{r.supplier}</td>
                <td className="py-2 pr-4 font-mono text-xs">{r.supplier_item_code ?? "—"}</td>
                <td className="py-2 pr-4 font-mono text-xs">{r.site_code ?? ui("Everywhere")}</td>
                <td className="py-2 pr-4 tabular-nums">{r.preference_rank}</td>
                <td className="py-2 pr-4">
                  {r.is_default ? <Pill tone="ok">{ui("Default")}</Pill> : "—"}
                </td>
                <td className="py-2 pr-4 tabular-nums">
                  {r.split_pct === null ? "—" : `${r.split_pct}%`}
                </td>
                <td className="py-2 pr-4">
                  {r.is_approved_for_use ? (
                    <Pill tone="ok">{ui("Yes")}</Pill>
                  ) : (
                    <Pill tone="warn">{ui("No")}</Pill>
                  )}
                </td>
                <td className="py-2 pr-4 tabular-nums">{r.lead_time_days ?? "—"}</td>
                <td className="py-2 pr-4 tabular-nums">{r.min_order_quantity ?? "—"}</td>
                <td className="py-2 pr-4">
                  <Pill tone={r.status === "active" ? "ok" : "muted"}>{r.status}</Pill>
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <ActionBar
        title="Supplier prices"
        note="What a supplier charges for a product, from a day. A purchase order line left without a price takes it; a line already on an order keeps the price it has."
        actions={[
          {
            label: "Set the supplier's price",
            permission: "master_data.write",
            fn: "erp_set_supplier_price",
            fields: [
              pickItem(),
              { ...pickParty("supplier", "p_party_id", "Supplier"), required: true },
              {
                kind: "number",
                name: "p_unit_price",
                label: "Price each",
                required: true,
                placeholder: "12.50",
                hint: "In the currency below, for one stock unit of the product.",
              },
              pickCurrency(),
              {
                kind: "number",
                name: "p_min_quantity",
                label: "Minimum quantity",
                hint: "The price applies to an order line of at least this many. Leave empty for any quantity.",
              },
              {
                kind: "date",
                name: "p_valid_from",
                label: "Valid from",
                hint: "Today if left empty. A price cannot start in the past.",
              },
              {
                kind: "date",
                name: "p_valid_to",
                label: "Valid to",
                hint: "Leave empty for no end. The price stops applying on this day.",
              },
              reason(),
            ],
            invalidates: pricesChanged,
          },
          {
            label: "End a supplier's price",
            permission: "master_data.write",
            fn: "erp_end_supplier_price",
            fields: [
              {
                kind: "select",
                name: "p_item_price_id",
                label: "Price to end",
                required: true,
                options: {
                  fn: "erp_supplier_prices",
                  value: "item_price_id",
                  label: ["item_code", "supplier", "currency"],
                  keep: (row) => row["state"] !== "ended",
                  describe: (row) =>
                    `${String(row["item_code"])} — ${String(row["supplier"])}, ${formatMinor(
                      Number(row["amount_minor"]),
                      String(row["currency"]),
                      Number(row["minor_units"]),
                    )} from ${String(row["valid_from"])}`,
                },
              },
              {
                kind: "date",
                name: "p_on",
                label: "Stops applying on",
                hint: "Today if left empty. One that has not started yet is withdrawn.",
              },
              reason(),
            ],
            invalidates: pricesChanged,
          },
        ]}
      />

      <DataPanel<SupplierPriceRow>
        title={ui("Supplier prices")}
        description={ui(
          "The price a purchase order line takes when nobody types one, by supplier and from the day it applies. Find a purchase price answers the same.",
        )}
        fn="erp_supplier_prices"
        empty={ui(
          "No supplier has a price yet, so a purchase order line takes none unless one is typed. Set one under Supplier prices above.",
        )}
      >
        {(rows) => (
          <Table
            columns={[
              ui("Product"),
              ui("Name"),
              ui("Supplier"),
              ui("Price each"),
              ui("Minimum"),
              ui("Valid from"),
              ui("Valid to"),
              ui("Status"),
            ]}
          >
            {rows.map((r) => (
              <tr key={r.item_price_id} className="border-b border-border/60 last:border-0">
                <td className="py-2 pr-4 font-mono text-xs">{r.item_code}</td>
                <td className="py-2 pr-4">{r.item_name}</td>
                <td className="py-2 pr-4">{r.supplier}</td>
                <td className="py-2 pr-4 tabular-nums">
                  {formatMinor(r.amount_minor, r.currency, r.minor_units)}
                </td>
                <td className="py-2 pr-4 tabular-nums">
                  {Number(r.min_quantity) > 0 ? r.min_quantity : "—"}
                </td>
                <td className="py-2 pr-4 tabular-nums">{r.valid_from}</td>
                <td className="py-2 pr-4 tabular-nums">{r.valid_to ?? "—"}</td>
                <td className="py-2 pr-4">
                  {r.state === "in_force" ? (
                    <Pill tone="ok">{ui("In force")}</Pill>
                  ) : r.state === "starts_later" ? (
                    <Pill tone="warn">{ui("Starts later")}</Pill>
                  ) : (
                    <Pill tone="muted">{ui("Ended")}</Pill>
                  )}
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <InquiryBoard
        inquiries={[
          {
            fn: "erp_resolve_item_supplier",
            label: "Who would this be bought from?",
            description:
              "The same resolution replenishment and planning use, including the site override and the approval check.",
            fields: [pickItem(), { kind: "site", name: "p_site_id", label: "Site" }],
          },
        ]}
      />
    </div>
  );
}
