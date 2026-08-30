import { createFileRoute } from "@tanstack/react-router";

import { ActionBar, pickFrom, pickItem, pickParty, reason } from "../../components/erp/actions-bar";
import { Gate } from "../../components/erp/gate";
import { InquiryBoard } from "../../components/erp/inquiry";
import { PageHeader, RefreshButton } from "../../components/erp/page";
import { DataPanel, Pill, Table } from "../../components/erp/panel";
import { ConfigTransfer } from "../../components/erp/transfer";
import { useT } from "../../lib/i18n";

export const Route = createFileRoute("/master-data/item-supply")({
  head: () => ({
    meta: [
      { title: "Item supply and default suppliers — ERPWare" },
      {
        name: "description",
        content:
          "Who each item is bought from, at what preference and split, per site — with approved-supplier enforcement on regulated items.",
      },
      { property: "og:title", content: "Item supply and default suppliers — ERPWare" },
      {
        property: "og:description",
        content:
          "Default suppliers, preference ranks, sourcing splits, lead times and approved-for-use status for every purchased item.",
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

function ItemSupply() {
  const { ui } = useT();
  const invalidates = ["erp_item_suppliers"];

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={ui("Item supply")}>
        {ui(
          "One supplier is the default for an item at a site; the rest are ranked alternatives. A regulated item cannot default to a supplier that is not on the approved list, and the sourcing split may not exceed the whole requirement.",
        )}
      </PageHeader>

      <div className="flex justify-end">
        <RefreshButton />
      </div>

      <ConfigTransfer
        objectType="item_supplier"
        title="Default suppliers as a file"
        description="Items, parties and sites are named by code, so a file written elsewhere still loads here."
        invalidates={["erp_item_suppliers", "erp_supplier_qualification"]}
      />

      <ActionBar
        note="Set the default once. Replenishment, planning and manual purchasing all resolve through it, so a missing default is a stopped order, not a silent guess."
        actions={[
          {
            label: "Set or amend a supplier for an item",
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
                hint: "Leave empty unless the requirement is deliberately divided.",
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
              { kind: "text", name: "p_supplier_item_code", label: "Supplier's own code" },
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
                "Item and supplier",
              ),
              { ...reason(), required: true },
            ],
            invalidates,
          },
        ]}
      />

      <DataPanel<SupplierRow>
        title={ui("Suppliers by item")}
        description={ui(
          "Rank one is used unless a site-specific row overrides it. An unapproved row is never resolved.",
        )}
        fn="erp_item_suppliers"
        empty={ui("No item has a supplier yet. Purchasing cannot resolve anything until one does.")}
      >
        {(rows) => (
          <Table
            columns={[
              ui("Item"),
              ui("Name"),
              ui("Supplier"),
              ui("Site"),
              ui("Rank"),
              ui("Default"),
              ui("Split"),
              ui("Approved"),
              ui("Lead time"),
              ui("Minimum"),
              ui("Status"),
            ]}
          >
            {rows.map((r) => (
              <tr key={r.item_supplier_id} className="border-b border-border/60 last:border-0">
                <td className="py-2 pr-4 font-mono text-xs">{r.item_code}</td>
                <td className="py-2 pr-4">{r.item_name}</td>
                <td className="py-2 pr-4">{r.supplier}</td>
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
