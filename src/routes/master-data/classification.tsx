import { createFileRoute } from "@tanstack/react-router";

import { ActionBar, pickFrom, pickItem } from "../../components/erp/actions-bar";
import { Gate } from "../../components/erp/gate";
import { InquiryBoard } from "../../components/erp/inquiry";
import { PageHeader, RefreshButton } from "../../components/erp/page";
import { DataPanel, Pill, Table } from "../../components/erp/panel";
import { RpcButton } from "../../components/erp/rpc-button";
import { ConfigTransfer } from "../../components/erp/transfer";
import { useT } from "../../lib/i18n";

export const Route = createFileRoute("/master-data/classification")({
  head: () => ({
    meta: [
      { title: "Product classification and coding — Clove ERP" },
      {
        name: "description",
        content:
          "Classification axes and values, code templates composed from them, and the assignments that record which classification produced each item code.",
      },
      { property: "og:title", content: "Product classification and coding — Clove ERP" },
      {
        property: "og:description",
        content:
          "Structured classification, derived code templates with sequences and check characters, completeness gaps and divergence reporting.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <Classification />
    </Gate>
  ),
});

const pickAxis = (name = "p_axis_id", label = "Axis", required = true) => ({
  ...pickFrom("erp_classification_axes", "axis_id", ["code", "name"], name, label),
  required,
});

const pickTemplate = (name = "p_template_id", label = "Code template") =>
  pickFrom("erp_code_templates", "template_id", ["code", "name"], name, label);

type Axis = {
  axis_id: string;
  code: string;
  name: string;
  seq: number;
  is_mandatory: boolean;
  item_classes: string[] | null;
  value_count: number;
  status: string;
};

type Value = {
  value_id: string;
  axis_code: string;
  code: string;
  name: string;
  abbreviation: string | null;
  parent_code: string | null;
  status: string;
};

type Template = {
  template_id: string;
  code: string;
  name: string;
  version: number;
  segments: unknown;
  next_value: number;
  status: string;
};

type Gap = {
  item_id: string;
  item_code: string;
  item_name: string;
  item_class: string;
  axis_code: string;
  axis_name: string;
};

type Assignment = {
  assignment_id: string;
  item_id: string;
  item_name: string;
  composed_code: string;
  template_code: string | null;
  template_version: number | null;
  assigned_at: string;
  assigned_by: string | null;
};

type Divergence = {
  item_id: string;
  item_code: string;
  item_name: string;
  template_code: string | null;
  template_version: number | null;
  coded_as: Record<string, unknown>;
  classified_as: Record<string, unknown>;
  assigned_at: string;
};

const summarise = (value: unknown) => {
  const entries = Object.entries((value ?? {}) as Record<string, unknown>);
  if (entries.length === 0) return "—";
  return entries.map(([k, v]) => `${k}=${String(v)}`).join(", ");
};

function Classification() {
  const { ui } = useT();
  const invalidates = [
    "erp_classification_axes",
    "erp_classification_values",
    "erp_classification_gaps",
    "erp_code_templates",
    "erp_item_code_assignments",
    "erp_code_divergences",
  ];

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={ui("Classification and coding")}>
        {ui(
          "Meaning lives in the classification, not in the code. A code is composed from the classification by a versioned template, recorded once, and never silently rewritten — if the classification later changes, the divergence is reported rather than hidden.",
        )}
      </PageHeader>

      <div className="flex flex-wrap justify-end gap-2">
        <RpcButton
          label="Seed a demo configuration"
          fn="erp_seed_demo_configuration"
          permission="administration.configure"
          confirm="This adds sample axes, values, a code template, supplier defaults and a release area. Running it twice changes nothing the second time."
          invalidates={[
            "erp_classification_axes",
            "erp_classification_values",
            "erp_code_templates",
            "erp_classification_gaps",
            "erp_item_suppliers",
            "erp_release_areas",
          ]}
        />
        <RefreshButton />
      </div>

      <div className="grid gap-4 xl:grid-cols-3">
        <ConfigTransfer
          objectType="classification_axis"
          title="Axes as a file"
          description="Download what is configured, edit it, check it, load it."
          invalidates={["erp_classification_axes", "erp_classification_gaps"]}
        />
        <ConfigTransfer
          objectType="classification_value"
          title="Values as a file"
          description="Each row names its axis by code; a parent value may be named the same way."
          invalidates={["erp_classification_values", "erp_classification_gaps"]}
        />
        <ConfigTransfer
          objectType="code_template"
          title="Code templates as a file"
          description="Segments travel as JSON in a single column, so a template round-trips intact."
          invalidates={["erp_code_templates", "erp_code_divergences"]}
        />
      </div>

      <ActionBar
        note="Axes are the questions asked of every item; values are the permitted answers."
        actions={[
          {
            label: "Add or amend an axis",
            permission: "master_data.write",
            fn: "erp_upsert_classification_axis",
            fields: [
              { kind: "text", name: "p_code", label: "Code", required: true },
              { kind: "text", name: "p_name", label: "Name", required: true },
              {
                kind: "choice",
                name: "p_is_mandatory",
                label: "Mandatory",
                boolean: true,
                choices: [
                  { value: "true", label: "Yes" },
                  { value: "false", label: "No" },
                ],
              },
              {
                kind: "text",
                name: "p_item_classes",
                label: "Only for item classes",
                hint: "Comma separated. Leave empty to apply to every item.",
              },
              { kind: "number", name: "p_seq", label: "Order" },
            ],
            invalidates,
          },
          {
            label: "Add or amend a value",
            permission: "master_data.write",
            fn: "erp_upsert_classification_value",
            fields: [
              pickAxis(),
              { kind: "text", name: "p_code", label: "Code", required: true },
              { kind: "text", name: "p_name", label: "Name", required: true },
              {
                kind: "text",
                name: "p_abbreviation",
                label: "Abbreviation",
                required: true,
                hint: "What the code template uses for this value.",
              },
              pickFrom(
                "erp_classification_values",
                "value_id",
                ["axis_code", "code", "name"],
                "p_parent_value_id",
                "Parent value",
              ),
            ],
            invalidates,
          },
          {
            label: "Classify an item",
            permission: "master_data.write",
            fn: "erp_classify_item",
            fields: [
              pickItem(),
              pickAxis(),
              pickFrom(
                "erp_classification_values",
                "value_id",
                ["axis_code", "code", "name"],
                "p_value_id",
                "Value",
              ),
              { kind: "date", name: "p_valid_from", label: "Valid from" },
            ],
            invalidates,
          },
        ]}
      />

      <ActionBar
        note="A template composes a code from ordered segments: an axis abbreviation, a literal, a sequence, or a check character."
        actions={[
          {
            label: "Add or amend a code template",
            permission: "master_data.write",
            fn: "erp_upsert_code_template",
            fields: [
              { kind: "text", name: "p_code", label: "Code", required: true },
              { kind: "text", name: "p_name", label: "Name", required: true },
              {
                kind: "text",
                name: "p_segments",
                label: "Segments (JSON)",
                required: true,
                hint: 'For example [{"kind":"axis","axis":"FAMILY","length":3},{"kind":"literal","text":"-"},{"kind":"sequence","length":4},{"kind":"check"}]',
              },
              { kind: "text", name: "p_item_classes", label: "Only for item classes" },
              {
                kind: "choice",
                name: "p_casing",
                label: "Casing",
                choices: [
                  { value: "upper", label: "Upper case" },
                  { value: "lower", label: "Lower case" },
                  { value: "none", label: "As entered" },
                ],
              },
            ],
            invalidates,
          },
          {
            label: "Create a classified item",
            permission: "master_data.write",
            fn: "erp_create_classified_item",
            fields: [
              { ...pickTemplate(), required: true },
              { kind: "text", name: "p_name", label: "Item name", required: true },
              { kind: "text", name: "p_item_class", label: "Item class", required: true },
              {
                kind: "text",
                name: "p_classification",
                label: "Classification (JSON)",
                required: true,
                hint: 'Axis code to value code, for example {"FAMILY":"WIDGET","GRADE":"A"}',
              },
              {
                kind: "choice",
                name: "p_is_batch_controlled",
                label: "Batch controlled",
                boolean: true,
                choices: [
                  { value: "true", label: "Yes" },
                  { value: "false", label: "No" },
                ],
              },
            ],
            invalidates,
          },
        ]}
      />

      <DataPanel<Axis>
        title={ui("Classification axes")}
        description={ui("A mandatory axis must be answered before an item can be created.")}
        fn="erp_classification_axes"
        empty={ui("No axes yet. Until one exists, items carry no structured meaning.")}
      >
        {(rows) => (
          <Table
            columns={[
              ui("Code"),
              ui("Name"),
              ui("Order"),
              ui("Mandatory"),
              ui("Item classes"),
              ui("Values"),
              ui("Status"),
            ]}
          >
            {rows.map((a) => (
              <tr key={a.axis_id} className="border-b border-border/60 last:border-0">
                <td className="py-2 pr-4 font-mono text-xs">{a.code}</td>
                <td className="py-2 pr-4">{a.name}</td>
                <td className="py-2 pr-4 tabular-nums">{a.seq}</td>
                <td className="py-2 pr-4">
                  {a.is_mandatory ? <Pill tone="warn">{ui("Yes")}</Pill> : "—"}
                </td>
                <td className="py-2 pr-4">{(a.item_classes ?? []).join(", ") || ui("All")}</td>
                <td className="py-2 pr-4 tabular-nums">{a.value_count}</td>
                <td className="py-2 pr-4">
                  <Pill tone={a.status === "active" ? "ok" : "muted"}>{a.status}</Pill>
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<Value>
        title={ui("Values")}
        description={ui("The permitted answers, and the abbreviation each contributes to a code.")}
        fn="erp_classification_values"
        empty={ui("No values yet.")}
      >
        {(rows) => (
          <Table
            columns={[
              ui("Axis"),
              ui("Code"),
              ui("Name"),
              ui("Abbreviation"),
              ui("Parent"),
              ui("Status"),
            ]}
          >
            {rows.map((v) => (
              <tr key={v.value_id} className="border-b border-border/60 last:border-0">
                <td className="py-2 pr-4 font-mono text-xs">{v.axis_code}</td>
                <td className="py-2 pr-4 font-mono text-xs">{v.code}</td>
                <td className="py-2 pr-4">{v.name}</td>
                <td className="py-2 pr-4 font-mono text-xs">{v.abbreviation ?? "—"}</td>
                <td className="py-2 pr-4 font-mono text-xs">{v.parent_code ?? "—"}</td>
                <td className="py-2 pr-4">
                  <Pill tone={v.status === "active" ? "ok" : "muted"}>{v.status}</Pill>
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<Template>
        title={ui("Code templates")}
        description={ui("Versioned. Amending a template never rewrites codes already assigned.")}
        fn="erp_code_templates"
        empty={ui("No templates yet. Item codes would then be typed by hand.")}
      >
        {(rows) => (
          <Table
            columns={[
              ui("Code"),
              ui("Name"),
              ui("Version"),
              ui("Segments"),
              ui("Next number"),
              ui("Status"),
            ]}
          >
            {rows.map((t) => (
              <tr key={t.template_id} className="border-b border-border/60 last:border-0">
                <td className="py-2 pr-4 font-mono text-xs">{t.code}</td>
                <td className="py-2 pr-4">{t.name}</td>
                <td className="py-2 pr-4 tabular-nums">{t.version}</td>
                <td className="py-2 pr-4 font-mono text-xs">{JSON.stringify(t.segments)}</td>
                <td className="py-2 pr-4 tabular-nums">{t.next_value}</td>
                <td className="py-2 pr-4">
                  <Pill tone={t.status === "active" ? "ok" : "muted"}>{t.status}</Pill>
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<Gap>
        title={ui("Completeness gaps")}
        description={ui("Items that are missing an answer a mandatory axis requires.")}
        fn="erp_classification_gaps"
        empty={ui("Every item answers every mandatory axis.")}
      >
        {(rows) => (
          <Table columns={[ui("Item"), ui("Name"), ui("Item class"), ui("Unanswered axis")]}>
            {rows.map((g) => (
              <tr
                key={`${g.item_id}-${g.axis_code}`}
                className="border-b border-border/60 last:border-0"
              >
                <td className="py-2 pr-4 font-mono text-xs">{g.item_code}</td>
                <td className="py-2 pr-4">{g.item_name}</td>
                <td className="py-2 pr-4">{g.item_class}</td>
                <td className="py-2 pr-4">
                  <Pill tone="warn">{g.axis_name}</Pill>
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<Assignment>
        title={ui("Code assignments")}
        description={ui("Append-only: the code, the template version that composed it, and when.")}
        fn="erp_item_code_assignments"
        args={{ p_limit: 200 }}
        empty={ui("No codes have been composed yet.")}
      >
        {(rows) => (
          <Table
            columns={[ui("Code"), ui("Item"), ui("Template"), ui("Version"), ui("When"), ui("By")]}
          >
            {rows.map((a) => (
              <tr key={a.assignment_id} className="border-b border-border/60 last:border-0">
                <td className="py-2 pr-4 font-mono text-xs">{a.composed_code}</td>
                <td className="py-2 pr-4">{a.item_name}</td>
                <td className="py-2 pr-4 font-mono text-xs">{a.template_code ?? "—"}</td>
                <td className="py-2 pr-4 tabular-nums">{a.template_version ?? "—"}</td>
                <td className="py-2 pr-4 tabular-nums">
                  {a.assigned_at.slice(0, 16).replace("T", " ")}
                </td>
                <td className="py-2 pr-4">{a.assigned_by ?? "—"}</td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<Divergence>
        title={ui("Code divergences")}
        description={ui(
          "Items whose classification has moved on from the one their code was composed from. Reported, never silently recoded.",
        )}
        fn="erp_code_divergences"
        empty={ui("No item has diverged from the classification behind its code.")}
      >
        {(rows) => (
          <Table columns={[ui("Item"), ui("Name"), ui("Coded as"), ui("Classified as")]}>
            {rows.map((d) => (
              <tr key={d.item_id} className="border-b border-border/60 last:border-0">
                <td className="py-2 pr-4 font-mono text-xs">{d.item_code}</td>
                <td className="py-2 pr-4">{d.item_name}</td>
                <td className="py-2 pr-4">{summarise(d.coded_as)}</td>
                <td className="py-2 pr-4">{summarise(d.classified_as)}</td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <InquiryBoard
        inquiries={[
          {
            fn: "erp_preview_item_code",
            label: "What code would this produce?",
            description: "A preview never consumes a sequence number.",
            fields: [
              { ...pickTemplate(), required: true },
              {
                kind: "text",
                name: "p_classification",
                label: "Classification (JSON)",
                required: true,
              },
            ],
          },
          {
            fn: "erp_item_classification",
            label: "How is this item classified?",
            description: "Every axis answered for one item.",
            fields: [pickItem()],
          },
        ]}
      />
    </div>
  );
}
