import { createFileRoute } from "@tanstack/react-router";

import { ActionBar } from "../../components/erp/actions-bar";
import { AutoPanel, StatusPill } from "../../components/erp/auto";
import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { useT } from "../../lib/i18n";

export const Route = createFileRoute("/finance/cost-centres")({
  head: () => ({
    meta: [
      { title: "Cost centres — Clove ERP" },
      {
        name: "description",
        content:
          "The cost centres every posting is analysed by, taken from the document's own cost centre, its department, or the site it happened at.",
      },
      { property: "og:title", content: "Cost centres — Clove ERP" },
      {
        property: "og:description",
        content:
          "Add, rename, group and retire cost centres, and see how many posted lines each one already carries.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <CostCentres />
    </Gate>
  ),
});

/**
 * Cost centres, without asking anyone to type one.
 *
 * A cost centre nobody fills in is a cost centre nobody reports on, so the
 * value is derived: the document's own cost centre if it names one, then its
 * department, then the site it happened at. This screen is where the list of
 * permitted values lives, and retiring one is a status rather than a deletion
 * so the history that carries it still reads.
 */
function CostCentres() {
  const { t } = useT();

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={t("nav.finance_cost_centres", "Cost centres")}>
        Every journal line is stamped with a cost centre derived from the document: its own cost
        centre, then its department, then its site. Add the ones this organisation reports on here;
        the profit and loss and the balance sheet can then be read for one of them alone.
      </PageHeader>

      <ActionBar
        title="Maintain cost centres"
        note="A code is short and permanent — LEE-WH, ADMIN, SALES. Retiring a cost centre sets it inactive; the postings that already carry it keep it."
        actions={[
          {
            label: "Add or amend a cost centre",
            permission: "finance.configure",
            fn: "erp_upsert_cost_centre",
            fields: [
              {
                kind: "text",
                name: "p_code",
                label: "Code",
                required: true,
                placeholder: "LEE-WH",
                hint: "Short, and the same one the site or department uses where it maps to one.",
              },
              {
                kind: "text",
                name: "p_name",
                label: "Name",
                required: true,
                placeholder: "Leeds warehouse",
              },
              {
                kind: "select",
                name: "p_parent_code",
                label: "Groups under",
                options: { fn: "erp_cost_centres", value: "code", label: ["code", "name"] },
                hint: "Optional. Use it to roll several cost centres into one heading.",
              },
              { kind: "date", name: "p_valid_from", label: "In use from" },
              { kind: "date", name: "p_valid_to", label: "In use until" },
              {
                kind: "choice",
                name: "p_status",
                label: "Status",
                required: true,
                choices: [
                  { value: "active", label: "Active" },
                  { value: "inactive", label: "Retired" },
                ],
              },
            ],
            mapArgs: (v) => ({
              p_code: v["p_code"],
              p_name: v["p_name"],
              p_parent_code: v["p_parent_code"] || null,
              p_valid_from: v["p_valid_from"] || null,
              p_valid_to: v["p_valid_to"] || null,
              p_status: v["p_status"] ?? "active",
            }),
            invalidates: ["erp_cost_centres", "erp_dimension_values"],
          },
        ]}
      />

      <AutoPanel
        title="Cost centres"
        description="What this organisation analyses its results by, and how much has already been posted to each."
        fn="erp_cost_centres"
        empty="No cost centre yet. Every site and department already here becomes one as soon as you add it above."
        rowKey={(r, i) => String(r["cost_centre_id"] ?? i)}
        columns={[
          { header: "Code", cell: "code" },
          { header: "Name", cell: "name" },
          { header: "Groups under", cell: "parent" },
          { header: "Posted lines", cell: "posted_lines", numeric: true },
          { header: "Status", cell: (r) => <StatusPill value={r["status"]} /> },
        ]}
      />
    </div>
  );
}
