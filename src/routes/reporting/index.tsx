import { createFileRoute } from "@tanstack/react-router";

import { AutoPanel, StatusPill } from "../../components/erp/auto";
import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { useT } from "../../lib/i18n";

export const Route = createFileRoute("/reporting/")({
  head: () => ({
    meta: [
      { title: "Reporting — ERPWare" },
      {
        name: "description",
        content:
          "Data quality, duplicate candidates, budget position and specification coverage, read from the same tables the operations use.",
      },
      { property: "og:title", content: "Reporting — ERPWare" },
      {
        property: "og:description",
        content: "Data quality, duplicates, budget position and specification coverage.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <Reporting />
    </Gate>
  ),
});

function Reporting() {
  const { t } = useT();

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={t("module.reporting", "Reporting")}>
        There is no reporting copy of the data. These read the operational tables, which is why a
        figure here and a figure on an operations screen cannot disagree.
      </PageHeader>

      <AutoPanel
        title="Data quality"
        description="Completeness and validity of master records."
        fn="erp_data_quality"
        empty="No master data to assess yet."
        rowKey={(r, i) => `${String(r["object_type"] ?? i)}-${String(r["check_code"] ?? i)}`}
        columns={[
          { header: "Object", cell: "object_type" },
          { header: "Check", cell: "check_code" },
          { header: "Records", cell: "records", numeric: true },
          { header: "Failing", cell: "failing", numeric: true },
          { header: "Score %", cell: "score_pct", numeric: true },
        ]}
      />

      <AutoPanel
        title="Duplicate candidates"
        description="Likely duplicate parties, for merge with a survivor and a reason."
        fn="erp_duplicate_candidates"
        args={{ p_object_type: "party" }}
        empty="No likely duplicates."
        rowKey={(r, i) => `${String(r["left_code"] ?? i)}-${String(r["right_code"] ?? i)}`}
        columns={[
          { header: "Record", cell: "left_code" },
          { header: "Candidate", cell: "right_code" },
          { header: "Score", cell: "similarity", numeric: true },
          { header: "Basis", cell: "basis" },
        ]}
      />

      <AutoPanel
        title="Specification coverage"
        description="Part 5 of the foundation specification, section by section, measured against the database."
        fn="erp_part5_summary"
        empty="Coverage could not be measured."
        rowKey={(r, i) => `${String(r["section"] ?? i)}-${i}`}
        columns={[
          { header: "Section", cell: "section" },
          { header: "Title", cell: "title" },
          { header: "Present", cell: "present", numeric: true },
          { header: "Expected", cell: "expected", numeric: true },
          { header: "Coverage %", cell: "coverage_pct", numeric: true },
          { header: "State", cell: (r) => <StatusPill value={r["state"]} /> },
        ]}
      />
    </div>
  );
}
