import { createFileRoute } from "@tanstack/react-router";

import {
  ActionBar,
  pickFrom,
  pickItem,
  pickLocation,
  pickSite,
  codeField,
} from "../../components/erp/actions-bar";
import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { DataPanel, Pill, Table } from "../../components/erp/panel";
import { useT } from "../../lib/i18n";

export const Route = createFileRoute("/inventory/warehouse")({
  head: () => ({
    meta: [
      { title: "Warehouse layout — Clove ERP" },
      {
        name: "description",
        content:
          "Zones, aisles and bins, what each holds, and the storage rules that decide where a product is put away to and picked from.",
      },
      { property: "og:title", content: "Warehouse layout — Clove ERP" },
      {
        property: "og:description",
        content:
          "Set up locations and bins, say where each product belongs, and have put-away, replenishment and picking follow them.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <WarehouseLayout />
    </Gate>
  ),
});

/** The kinds of place stock can stand in. */
const LOCATION_TYPES = [
  { value: "receiving", label: "Goods in (receiving)" },
  { value: "zone", label: "Zone" },
  { value: "bulk", label: "Bulk storage" },
  { value: "pick", label: "Pick face" },
  { value: "staging", label: "Staging" },
  { value: "despatch", label: "Despatch" },
  { value: "quarantine", label: "Quarantine" },
  { value: "production", label: "Production" },
  { value: "damages", label: "Damages" },
  { value: "scrap", label: "Scrap" },
  { value: "transit", label: "In transit" },
  { value: "virtual", label: "Virtual" },
];

const PICKABLE = [
  { value: "true", label: "Yes — pickers are sent here" },
  { value: "false", label: "No — reserve only" },
];

const RULE_KINDS = [
  { value: "putaway", label: "Put away — where goods received are taken to" },
  { value: "pick_face", label: "Pick face — where this product is picked from" },
];

type LocationRow = {
  location_id: string;
  code: string;
  name: string | null;
  site: string;
  location_type: string;
  parent: string | null;
  depth: number | null;
  capacity_quantity: number | null;
  capacity_uom: string | null;
  count_class: string | null;
  on_hand: number;
  is_pickable: boolean;
  is_blocked: boolean;
  block_reason_code: string | null;
};

type RuleRow = {
  storage_rule_id: string;
  site: string;
  rule_kind: string;
  scope: string;
  item: string | null;
  item_name: string | null;
  item_class: string | null;
  location: string;
  location_name: string | null;
  priority: number;
  max_quantity: number | null;
  is_blocked: boolean;
};

const pickRule = () =>
  pickFrom(
    "erp_storage_rules",
    "storage_rule_id",
    ["site", "rule_kind", "scope", "location"],
    "p_storage_rule_id",
    "Storage rule",
  );

const pickPlace = (label = "Location") => pickLocation("p_location_id", label, true);

function WarehouseLayout() {
  const { ui } = useT();
  const invalidates = ["erp_locations", "erp_storage_rules"];

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={ui("Warehouse layout")}>
        {ui(
          "A warehouse is a shape, not a list: zones hold aisles, aisles hold bins, and a storage rule says which product belongs where. Put-away sends goods to the place the rules name, replenishment tops up the pick face they name, and picking prefers it once the first-expired rule has chosen the stock.",
        )}
      </PageHeader>

      <ActionBar
        title="Locations and bins"
        note="Give a place a parent to nest it — a bin inside an aisle inside a zone. A place that is not pickable is reserve: stock stands there, but pickers are not sent to it."
        actions={[
          {
            label: "Add a location",
            permission: "administration.configure",
            fn: "erp_create_location",
            fields: [
              pickSite(),
              codeField("p_code", "Code", "LEE-A-01-02", {
                fn: "erp_locations",
                value: "code",
                label: ["site", "code", "name"],
              }),
              {
                kind: "text",
                name: "p_name",
                label: "Name",
                placeholder: "Aisle A, bay 1, level 2",
                hint: "Optional. The code is what people scan.",
              },
              {
                kind: "choice",
                name: "p_location_type",
                label: "Kind of place",
                required: true,
                choices: LOCATION_TYPES,
              },
              pickLocation("p_parent_location_id", "Sits inside", false),
              {
                kind: "choice",
                name: "p_is_pickable",
                label: "Pickable",
                boolean: true,
                choices: PICKABLE,
              },
              {
                kind: "number",
                name: "p_capacity_quantity",
                label: "Holds at most",
                hint: "Optional. Put-away skips a place that is already full.",
              },
              {
                kind: "text",
                name: "p_capacity_uom",
                label: "Capacity unit",
                placeholder: "EA",
                hint: "Optional. What the capacity above is counted in.",
              },
              {
                kind: "text",
                name: "p_count_class",
                label: "Count class",
                placeholder: "A",
                hint: "Optional. How often this place is cycle counted.",
              },
            ],
            invalidates,
          },
          {
            label: "Amend a location",
            permission: "administration.configure",
            fn: "erp_update_location",
            fields: [
              pickPlace("Location to amend"),
              {
                kind: "text",
                name: "p_name",
                label: "Name",
                placeholder: "Aisle A, bay 1, level 2",
                hint: "Leave empty to keep the name it has.",
              },
              {
                kind: "choice",
                name: "p_location_type",
                label: "Kind of place",
                choices: LOCATION_TYPES,
              },
              pickLocation("p_parent_location_id", "Sits inside", false),
              {
                kind: "choice",
                name: "p_is_pickable",
                label: "Pickable",
                boolean: true,
                choices: PICKABLE,
              },
              { kind: "number", name: "p_capacity_quantity", label: "Holds at most" },
              {
                kind: "text",
                name: "p_capacity_uom",
                label: "Capacity unit",
                placeholder: "EA",
                hint: "What the amount above is counted in.",
              },
              {
                kind: "text",
                name: "p_count_class",
                label: "Count class",
                placeholder: "A",
                hint: "How often this place is cycle counted.",
              },
            ],
            invalidates,
          },
          {
            label: "Block a location",
            title: "Block a location",
            description:
              "Nothing is put away to a blocked place and nothing is picked from it. The stock standing in it stays where it is.",
            permission: "administration.configure",
            fn: "erp_block_location",
            fields: [
              pickPlace("Location to block"),
              {
                kind: "text",
                name: "p_reason_code",
                label: "Reason",
                placeholder: "DAMAGED-RACK",
              },
            ],
            invalidates,
          },
          {
            label: "Unblock a location",
            permission: "administration.configure",
            fn: "erp_unblock_location",
            fields: [pickPlace("Location to unblock")],
            invalidates,
          },
        ]}
      />

      <DataPanel<LocationRow>
        title={ui("Locations")}
        description={ui(
          "Every place at every site, with what sits above it, what it holds, and what is standing in it now.",
        )}
        fn="erp_locations"
        empty={ui(
          "No locations yet. Add one above — until a site has a goods-in place and somewhere to store, nothing can be received.",
        )}
      >
        {(rows) => (
          <Table
            columns={[
              ui("Site"),
              ui("Code"),
              ui("Name"),
              ui("Kind"),
              ui("Sits inside"),
              ui("Holds"),
              ui("Count class"),
              ui("On hand"),
              ui("Pickable"),
            ]}
          >
            {rows.map((l) => (
              <tr key={l.location_id} className="border-b border-border/60 last:border-0">
                <td className="py-2 pr-4 font-mono text-xs">{l.site}</td>
                <td className="py-2 pr-4 font-mono text-xs">{l.code}</td>
                <td className="py-2 pr-4">{l.name ?? "—"}</td>
                <td className="py-2 pr-4">{l.location_type}</td>
                <td className="py-2 pr-4 font-mono text-xs">{l.parent ?? "—"}</td>
                <td className="py-2 pr-4 tabular-nums">
                  {l.capacity_quantity == null
                    ? "—"
                    : `${l.capacity_quantity} ${l.capacity_uom ?? ""}`.trim()}
                </td>
                <td className="py-2 pr-4">{l.count_class ?? "—"}</td>
                <td className="py-2 pr-4 tabular-nums">{l.on_hand}</td>
                <td className="py-2 pr-4">
                  <Pill tone={l.is_blocked ? "warn" : l.is_pickable ? "ok" : "muted"}>
                    {l.is_blocked
                      ? (l.block_reason_code ?? ui("blocked"))
                      : l.is_pickable
                        ? ui("yes")
                        : ui("no")}
                  </Pill>
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <ActionBar
        title="Storage rules"
        note="Name a product, or a product class, or neither — a rule naming the product beats a rule naming its class, which beats a rule naming everything. Lower priority numbers are tried first."
        actions={[
          {
            label: "Add a storage rule",
            permission: "inventory.adjust",
            fn: "erp_create_storage_rule",
            fields: [
              pickSite(),
              {
                kind: "choice",
                name: "p_rule_kind",
                label: "What the rule decides",
                required: true,
                choices: RULE_KINDS,
              },
              pickPlace("Where it belongs"),
              { ...pickItem("p_item_id", "Product"), required: false },
              {
                kind: "text",
                name: "p_item_class",
                label: "Or a product class",
                placeholder: "CHILLED",
                hint: "Leave both empty and the rule covers every product at the site.",
              },
              {
                kind: "number",
                name: "p_priority",
                label: "Priority",
                hint: "Lower is tried first. 100 unless you say otherwise.",
              },
              {
                kind: "number",
                name: "p_max_quantity",
                label: "Fill to at most",
                hint: "Optional. Once the place holds this much, the next rule is used.",
              },
            ],
            invalidates,
          },
          {
            label: "Withdraw a storage rule",
            permission: "inventory.adjust",
            fn: "erp_remove_storage_rule",
            fields: [pickRule()],
            invalidates,
          },
        ]}
      />

      <DataPanel<RuleRow>
        title={ui("Storage rules")}
        description={ui(
          "What put-away, replenishment and picking read. With no rule at a site, put-away falls back to the first open bulk location and picking to the nearest pick face.",
        )}
        fn="erp_storage_rules"
        empty={ui(
          "No storage rules yet. Goods are still put away and picked — just to whichever open place comes first, rather than where you would have put them.",
        )}
      >
        {(rows) => (
          <Table
            columns={[
              ui("Site"),
              ui("Rule"),
              ui("Applies to"),
              ui("Place"),
              ui("Priority"),
              ui("Fill to"),
              ui("State"),
            ]}
          >
            {rows.map((r) => (
              <tr key={r.storage_rule_id} className="border-b border-border/60 last:border-0">
                <td className="py-2 pr-4 font-mono text-xs">{r.site}</td>
                <td className="py-2 pr-4">
                  <Pill tone="muted">
                    {r.rule_kind === "pick_face" ? ui("Pick face") : ui("Put away")}
                  </Pill>
                </td>
                <td className="py-2 pr-4">
                  {r.item ? `${r.item} — ${r.item_name ?? ""}`.trim() : (r.item_class ?? r.scope)}
                </td>
                <td className="py-2 pr-4 font-mono text-xs">{r.location}</td>
                <td className="py-2 pr-4 tabular-nums">{r.priority}</td>
                <td className="py-2 pr-4 tabular-nums">{r.max_quantity ?? "—"}</td>
                <td className="py-2 pr-4">
                  {r.is_blocked ? (
                    <Pill tone="warn">{ui("Place blocked")}</Pill>
                  ) : (
                    <Pill tone="ok">{ui("In force")}</Pill>
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
