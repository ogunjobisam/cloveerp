import { createFileRoute } from "@tanstack/react-router";

import { ActionButton } from "../../components/erp/action";
import { AutoPanel, StatusPill, shortDate } from "../../components/erp/auto";
import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { useT } from "../../lib/i18n";

export const Route = createFileRoute("/governance/")({
  head: () => ({
    meta: [
      { title: "Change requests and approvals — ERPWare" },
      {
        name: "description",
        content:
          "The governed path for master data: propose a change, preview it, have it approved, then apply it.",
      },
      { property: "og:title", content: "Change requests and approvals — ERPWare" },
      {
        property: "og:description",
        content: "Propose, preview, approve and apply master data changes.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <Governance />
    </Gate>
  ),
});

function Governance() {
  const { t } = useT();

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={t("module.governance", "Change requests and approvals")}>
        Master data does not change because somebody typed into a form. A change is proposed against
        a specific record, shown as a before-and-after, approved by whoever the rule names, and only
        then applied — with the whole sequence kept.
      </PageHeader>

      <AutoPanel
        title="My approvals"
        description="Tasks assigned to you, directly or through a role you hold."
        fn="erp_my_approvals"
        empty="Nothing is waiting on you."
        rowKey={(r) => String(r["task_id"])}
        columns={[
          { header: "Object", cell: "object_type" },
          { header: "Requested by", cell: "requested_by" },
          { header: "Requested", cell: (r) => shortDate(r["requested_at"]) },
          { header: "Step", cell: "step_code" },
          { header: "Status", cell: (r) => <StatusPill value={r["status"]} /> },
          {
            header: "Decide",
            cell: (r) => (
              <span className="flex gap-2">
                <ActionButton
                  label="Approve"
                  fn="erp_decide_approval"
                  args={{ p_task_id: r["task_id"], p_decision: "approved" }}
                  permission="administration.approve"
                  invalidate={["erp_my_approvals", "erp_change_requests"]}
                />
                <ActionButton
                  label="Reject"
                  fn="erp_decide_approval"
                  args={{ p_task_id: r["task_id"], p_decision: "rejected" }}
                  permission="administration.approve"
                  invalidate={["erp_my_approvals", "erp_change_requests"]}
                />
              </span>
            ),
          },
        ]}
      />

      <AutoPanel
        title="Change requests"
        description="Proposed master data changes and where each one has got to."
        fn="erp_change_requests"
        empty="No change requests. Master data is currently as proposed."
        rowKey={(r) => String(r["change_request_id"])}
        columns={[
          { header: "Object", cell: "object_type" },
          { header: "Record", cell: "object_label" },
          { header: "Reason", cell: "reason" },
          { header: "Raised", cell: (r) => shortDate(r["created_at"]) },
          { header: "Status", cell: (r) => <StatusPill value={r["status"]} /> },
          {
            header: "Action",
            cell: (r) =>
              r["status"] === "draft" ? (
                <ActionButton
                  label="Submit"
                  fn="erp_submit_change_request"
                  args={{ p_change_request_id: r["change_request_id"] }}
                  permission="master_data.write"
                  invalidate={["erp_change_requests", "erp_my_approvals"]}
                />
              ) : r["status"] === "approved" ? (
                <ActionButton
                  label="Apply"
                  fn="erp_apply_change_request"
                  args={{ p_change_request_id: r["change_request_id"] }}
                  permission="master_data.write"
                  invalidate={["erp_change_requests", "erp_items", "erp_parties"]}
                />
              ) : (
                <span className="text-xs text-muted-foreground">—</span>
              ),
          },
        ]}
      />
    </div>
  );
}
