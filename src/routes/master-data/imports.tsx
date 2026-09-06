import { createFileRoute } from "@tanstack/react-router";

import { ActionBar } from "../../components/erp/actions-bar";
import { AutoPanel, StatusPill, shortDate } from "../../components/erp/auto";
import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { RpcButton } from "../../components/erp/rpc-button";
import { useT } from "../../lib/i18n";

export const Route = createFileRoute("/master-data/imports")({
  head: () => ({
    meta: [
      { title: "Imports — Clove ERP" },
      {
        name: "description",
        content:
          "Staged import batches with preview, validation, load and rollback — the governed way records arrive in bulk.",
      },
      { property: "og:title", content: "Imports — Clove ERP" },
      {
        property: "og:description",
        content: "Staged imports with preview, validation, load and rollback.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <Imports />
    </Gate>
  ),
});

function Imports() {
  const { t } = useT();

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={t("module.imports", "Imports")}>
        An import is staged, previewed row by row, validated against the same rules a keyed entry
        would face, then loaded — and it can be rolled back as a unit, because it was recorded as
        one.
      </PageHeader>

      <ActionBar
        title="Staging a batch"
        note="Rows are staged as they were received and validated before anything is written. Master data rows name the record by code; a settlement statement is one statement per batch, a row per payout line."
        actions={[
          {
            label: "Stage an import",
            permission: "master_data.import",
            fn: "erp_stage_import",
            fields: [
              {
                kind: "choice",
                name: "p_object_type",
                label: "What the rows are",
                required: true,
                choices: [
                  { value: "party", label: "Business partners" },
                  { value: "item", label: "Products" },
                  { value: "settlement_statement", label: "Settlement statement" },
                ],
              },
              {
                kind: "text",
                name: "p_rows",
                label: "Rows",
                required: true,
                hint: 'JSON array of objects, for example [{"code": "ACME", "name": "Acme Ltd"}].',
              },
              {
                kind: "text",
                name: "p_code",
                label: "Batch code",
                hint: "Left empty, one is generated.",
              },
              {
                kind: "text",
                name: "p_source",
                label: "Source",
                hint: "Where the file came from. Default manual.",
              },
            ],
            mapArgs: (v) => ({
              p_object_type: v["p_object_type"],
              p_rows: JSON.parse(v["p_rows"] ?? "[]"),
              p_code: v["p_code"] || null,
              p_source: v["p_source"] || "manual",
            }),
            invalidates: ["erp_import_batches"],
          },
        ]}
      />

      <AutoPanel
        title="Import batches"
        description="Every batch keeps its rows, its errors and its outcome."
        fn="erp_import_batches"
        empty="No imports staged. Stage a batch from a file, preview it row by row, and load it only once the errors are nil."
        rowKey={(r) => String(r["batch_id"])}
        columns={[
          { header: "Batch", cell: "code" },
          { header: "Object", cell: "object_type" },
          { header: "Rows", cell: "row_count", numeric: true },
          { header: "Errors", cell: "error_count", numeric: true },
          { header: "Staged", cell: (r) => shortDate(r["created_at"]) },
          { header: "Status", cell: (r) => <StatusPill value={r["status"]} /> },
          {
            header: "Actions",
            cell: (r) => (
              <span className="flex flex-wrap gap-2">
                <RpcButton
                  label="Validate"
                  fn="erp_validate_import"
                  args={{ p_batch_id: r["batch_id"] }}
                  permission="master_data.import"
                  invalidates={["erp_import_batches"]}
                />
                <RpcButton
                  label="Load"
                  fn="erp_load_import"
                  args={{ p_batch_id: r["batch_id"] }}
                  permission="master_data.import"
                  invalidates={["erp_import_batches", "erp_items", "erp_parties"]}
                />
                <RpcButton
                  label="Roll back"
                  fn="erp_rollback_import"
                  args={{ p_batch_id: r["batch_id"] }}
                  permission="master_data.import"
                  confirm="Roll this batch back? Every record it loaded is reversed."
                  invalidates={["erp_import_batches", "erp_items", "erp_parties"]}
                />
              </span>
            ),
          },
        ]}
      />
    </div>
  );
}
