import { createFileRoute } from "@tanstack/react-router";

import {
  ActionBar,
  pickFrom,
  pickItem,
  pickLocation,
  reason,
} from "../../components/erp/actions-bar";
import { Gate } from "../../components/erp/gate";
import { PageHeader, RefreshButton } from "../../components/erp/page";
import { DataPanel, Pill, Table } from "../../components/erp/panel";
import { useT } from "../../lib/i18n";

export const Route = createFileRoute("/logistics/release-areas")({
  head: () => ({
    meta: [
      { title: "Release areas and waves — ERPWare" },
      {
        name: "description",
        content:
          "Release areas hold allocated stock, waves allocate in detail against them, shortfalls raise directed replenishment, and paperwork prints only once everything is covered.",
      },
      { property: "og:title", content: "Release areas and waves — ERPWare" },
      {
        property: "og:description",
        content:
          "Pull and push replenishment, minimum and maximum levels, ageing back to bulk, and print gating on full allocation.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <ReleaseAreas />
    </Gate>
  ),
});

type Area = {
  release_area_id: string;
  code: string;
  name: string;
  site_code: string;
  location_code: string | null;
  channel_code: string | null;
  order_type_code: string | null;
  item_classes: string[] | null;
  replenishment_mode: string;
  min_quantity: number | null;
  max_quantity: number | null;
  ageing_hours: number;
  gate_printing: boolean;
  on_hand: number;
  status: string;
};

type Wave = {
  wave_id: string;
  code: string;
  status: string;
  release_area: string;
  site_code: string;
  opened_at: string;
  allocated_at: string | null;
  printed_at: string | null;
  lines: number;
  short_lines: number;
};

type WaveLine = {
  wave_line_id: string;
  item_code: string;
  item_name: string;
  quantity: number;
  allocated_quantity: number;
  shortfall_quantity: number;
  shortfall_cause: string | null;
  status: string;
};

const pickArea = (name = "p_release_area_id", label = "Release area") =>
  pickFrom("erp_release_areas", "release_area_id", ["site_code", "code", "name"], name, label);

const pickWave = (name = "p_wave_id", label = "Wave") =>
  pickFrom("erp_release_waves", "wave_id", ["code", "release_area", "status"], name, label);

function ReleaseAreas() {
  const { ui } = useT();
  const invalidates = ["erp_release_areas", "erp_release_waves", "erp_release_wave_lines"];

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={ui("Release areas")}>
        {ui(
          "Stock in a release area is allocated stock: out of counting scope and out of reach of other demand. A wave allocates in detail against the area, what the area cannot cover raises directed replenishment rather than a shortage, and nothing prints until every line is covered.",
        )}
      </PageHeader>

      <div className="flex justify-end">
        <RefreshButton />
      </div>

      <ActionBar
        note="An area is a scope, not a place on a map: a site, a location, and optionally the channel, order type and item classes it serves."
        actions={[
          {
            label: "Add or amend a release area",
            permission: "logistics.plan",
            fn: "erp_upsert_release_area",
            fields: [
              { kind: "site", name: "p_site_id", label: "Site", required: true },
              { kind: "text", name: "p_code", label: "Code", required: true },
              { kind: "text", name: "p_name", label: "Name", required: true },
              pickLocation("p_location_id", "Location"),
              {
                kind: "choice",
                name: "p_replenishment_mode",
                label: "Replenishment",
                required: true,
                choices: [
                  { value: "pull", label: "Pull — move only what a wave is short" },
                  { value: "push", label: "Push — top up to the maximum" },
                ],
              },
              { kind: "text", name: "p_channel_code", label: "Channel" },
              { kind: "text", name: "p_order_type_code", label: "Order type" },
              {
                kind: "text",
                name: "p_item_classes",
                label: "Item classes",
                hint: "Comma separated. Leave empty to serve any item.",
              },
              { kind: "number", name: "p_min_quantity", label: "Minimum" },
              { kind: "number", name: "p_max_quantity", label: "Maximum" },
              { kind: "number", name: "p_ageing_hours", label: "Ageing (hours)" },
              {
                kind: "choice",
                name: "p_gate_printing",
                label: "Gate printing on full allocation",
                boolean: true,
                choices: [
                  { value: "true", label: "Yes" },
                  { value: "false", label: "No" },
                ],
              },
            ],
            invalidates,
          },
          {
            label: "Age untouched stock back to bulk",
            permission: "logistics.plan",
            fn: "erp_age_back_release_area",
            fields: [pickArea()],
            invalidates,
          },
        ]}
      />

      <ActionBar
        note="The wave is the unit of release: open it, put lines on it, allocate, then print."
        actions={[
          {
            label: "Open a wave",
            permission: "logistics.plan",
            fn: "erp_open_release_wave",
            fields: [
              pickArea(),
              { kind: "text", name: "p_code", label: "Code", hint: "Left empty, one is generated." },
              { kind: "text", name: "p_note", label: "Note" },
            ],
            invalidates,
          },
          {
            label: "Add a line to a wave",
            permission: "logistics.plan",
            fn: "erp_add_wave_line",
            fields: [
              pickWave(),
              pickItem(),
              { kind: "number", name: "p_quantity", label: "Quantity", required: true },
            ],
            invalidates,
          },
          {
            label: "Allocate the wave",
            permission: "logistics.plan",
            fn: "erp_allocate_release_wave",
            fields: [pickWave()],
            invalidates,
          },
          {
            label: "Print the wave",
            permission: "logistics.despatch",
            fn: "erp_print_release_wave",
            fields: [pickWave()],
            invalidates,
          },
        ]}
      />

      <DataPanel<Area>
        title={ui("Release areas")}
        description={ui("What each area serves, how it replenishes, and what is sitting in it now.")}
        fn="erp_release_areas"
        empty={ui("No release areas yet. Allocation runs against the whole site until one exists.")}
      >
        {(rows) => (
          <Table
            columns={[
              ui("Site"),
              ui("Code"),
              ui("Name"),
              ui("Location"),
              ui("Channel"),
              ui("Order type"),
              ui("Item classes"),
              ui("Mode"),
              ui("Min"),
              ui("Max"),
              ui("Ageing"),
              ui("Printing"),
              ui("On hand"),
            ]}
          >
            {rows.map((a) => (
              <tr key={a.release_area_id} className="border-b border-border/60 last:border-0">
                <td className="py-2 pr-4 font-mono text-xs">{a.site_code}</td>
                <td className="py-2 pr-4 font-mono text-xs">{a.code}</td>
                <td className="py-2 pr-4">{a.name}</td>
                <td className="py-2 pr-4 font-mono text-xs">{a.location_code ?? "—"}</td>
                <td className="py-2 pr-4">{a.channel_code ?? ui("Any")}</td>
                <td className="py-2 pr-4">{a.order_type_code ?? ui("Any")}</td>
                <td className="py-2 pr-4">{(a.item_classes ?? []).join(", ") || ui("Any")}</td>
                <td className="py-2 pr-4">
                  <Pill tone="muted">{a.replenishment_mode}</Pill>
                </td>
                <td className="py-2 pr-4 tabular-nums">{a.min_quantity ?? "—"}</td>
                <td className="py-2 pr-4 tabular-nums">{a.max_quantity ?? "—"}</td>
                <td className="py-2 pr-4 tabular-nums">{a.ageing_hours}h</td>
                <td className="py-2 pr-4">
                  {a.gate_printing ? (
                    <Pill tone="ok">{ui("Gated")}</Pill>
                  ) : (
                    <Pill tone="warn">{ui("Open")}</Pill>
                  )}
                </td>
                <td className="py-2 pr-4 tabular-nums">{a.on_hand}</td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<Wave>
        title={ui("Waves")}
        description={ui("A wave with short lines has raised replenishment and cannot print yet.")}
        fn="erp_release_waves"
        args={{ p_limit: 100 }}
        empty={ui("No waves have been opened.")}
      >
        {(rows) => (
          <Table
            columns={[
              ui("Wave"),
              ui("Area"),
              ui("Site"),
              ui("Status"),
              ui("Lines"),
              ui("Short"),
              ui("Opened"),
              ui("Allocated"),
              ui("Printed"),
            ]}
          >
            {rows.map((w) => (
              <tr key={w.wave_id} className="border-b border-border/60 last:border-0">
                <td className="py-2 pr-4 font-mono text-xs">{w.code}</td>
                <td className="py-2 pr-4 font-mono text-xs">{w.release_area}</td>
                <td className="py-2 pr-4 font-mono text-xs">{w.site_code}</td>
                <td className="py-2 pr-4">
                  <Pill
                    tone={
                      w.status === "released" ? "ok" : w.status === "cancelled" ? "muted" : "warn"
                    }
                  >
                    {w.status}
                  </Pill>
                </td>
                <td className="py-2 pr-4 tabular-nums">{w.lines}</td>
                <td className="py-2 pr-4 tabular-nums">{w.short_lines}</td>
                <td className="py-2 pr-4 tabular-nums">
                  {w.opened_at.slice(0, 16).replace("T", " ")}
                </td>
                <td className="py-2 pr-4 tabular-nums">
                  {w.allocated_at ? w.allocated_at.slice(0, 16).replace("T", " ") : "—"}
                </td>
                <td className="py-2 pr-4 tabular-nums">
                  {w.printed_at ? w.printed_at.slice(0, 16).replace("T", " ") : "—"}
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <ActionBar
        note="Cover for a wave you are looking at."
        actions={[
          {
            label: "Re-allocate a short wave",
            permission: "logistics.plan",
            fn: "erp_allocate_release_wave",
            fields: [pickWave(), reason()],
            invalidates,
          },
        ]}
      />

      <DataPanel<WaveLine>
        title={ui("Wave lines")}
        description={ui("Choose a wave above; lines show what allocated and what fell short.")}
        fn="erp_release_wave_lines"
        args={{ p_wave_id: null }}
        empty={ui("Pick a wave to see its lines.")}
      >
        {(rows) => (
          <Table
            columns={[
              ui("Item"),
              ui("Name"),
              ui("Wanted"),
              ui("Allocated"),
              ui("Short"),
              ui("Cause"),
              ui("Status"),
            ]}
          >
            {rows.map((l) => (
              <tr key={l.wave_line_id} className="border-b border-border/60 last:border-0">
                <td className="py-2 pr-4 font-mono text-xs">{l.item_code}</td>
                <td className="py-2 pr-4">{l.item_name}</td>
                <td className="py-2 pr-4 tabular-nums">{l.quantity}</td>
                <td className="py-2 pr-4 tabular-nums">{l.allocated_quantity}</td>
                <td className="py-2 pr-4 tabular-nums">{l.shortfall_quantity}</td>
                <td className="py-2 pr-4">{l.shortfall_cause ?? "—"}</td>
                <td className="py-2 pr-4">
                  <Pill tone={l.status === "allocated" ? "ok" : "warn"}>{l.status}</Pill>
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>
    </div>
  );
}
