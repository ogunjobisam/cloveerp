import { createFileRoute } from "@tanstack/react-router";

import { AutoPanel, StatusPill, shortDate } from "../../components/erp/auto";
import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { useT } from "../../lib/i18n";

export const Route = createFileRoute("/quality/")({
  head: () => ({
    meta: [
      { title: "Quality and recall — ERPWare" },
      {
        name: "description",
        content:
          "Quality events, inspections, supplier qualification and recall execution with a regulatory clock.",
      },
      { property: "og:title", content: "Quality and recall — ERPWare" },
      {
        property: "og:description",
        content: "Quality events, inspections and recall execution against a regulatory clock.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <Quality />
    </Gate>
  ),
});

function Quality() {
  const { t } = useT();

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={t("module.quality", "Quality and recall")}>
        A recall is not a report. It is an operation with a clock, a scope derived from genealogy,
        and a record of every action taken against it.
      </PageHeader>

      <AutoPanel
        title="Quality events"
        description="Non-conformance, complaint, deviation and their investigations."
        fn="erp_quality_events"
        empty="No quality events open."
        rowKey={(r) => String(r["event_id"])}
        columns={[
          { header: "Reference", cell: "reference" },
          { header: "Kind", cell: "event_kind" },
          { header: "Severity", cell: (r) => <StatusPill value={r["severity"]} /> },
          { header: "Title", cell: "title" },
          { header: "Item", cell: "item" },
          { header: "Due", cell: (r) => shortDate(r["due_at"]) },
          { header: "Status", cell: (r) => <StatusPill value={r["status"]} /> },
        ]}
      />

      <AutoPanel
        title="Inspections"
        description="Awaiting disposition. Stock stays unavailable until one is recorded."
        fn="erp_inspections"
        empty="Nothing awaiting inspection."
        rowKey={(r) => String(r["inspection_id"])}
        columns={[
          { header: "Reference", cell: "reference" },
          { header: "Item", cell: "item" },
          { header: "Batch", cell: "batch" },
          { header: "Quantity", cell: "quantity", numeric: true },
          { header: "Disposition", cell: (r) => <StatusPill value={r["disposition"]} /> },
          { header: "Status", cell: (r) => <StatusPill value={r["status"]} /> },
        ]}
      />

      <AutoPanel
        title="Recalls"
        description="Scope, clock and progress. The deadline is a configured regulatory clock, not a note."
        fn="erp_recalls"
        empty="No recalls. This is the panel you want to stay empty."
        rowKey={(r) => String(r["recall_id"])}
        columns={[
          { header: "Reference", cell: "reference" },
          { header: "Title", cell: "title" },
          { header: "Class", cell: "classification" },
          { header: "Initiated", cell: (r) => shortDate(r["initiated_at"]) },
          { header: "Deadline", cell: (r) => shortDate(r["regulatory_deadline"]) },
          { header: "Status", cell: (r) => <StatusPill value={r["status"]} /> },
        ]}
      />

      <AutoPanel
        title="Supplier qualification"
        description="Who is approved to supply what, and until when."
        fn="erp_supplier_qualifications"
        empty="No supplier qualifications recorded."
        rowKey={(r, i) => `${String(r["party"] ?? i)}-${i}`}
        columns={[
          { header: "Supplier", cell: "party" },
          { header: "Qualified", cell: (r) => shortDate(r["qualified_at"]) },
          { header: "Valid to", cell: (r) => shortDate(r["valid_to"]) },
          { header: "Status", cell: (r) => <StatusPill value={r["status"]} /> },
        ]}
      />
    </div>
  );
}
