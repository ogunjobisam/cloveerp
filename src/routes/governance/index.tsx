import { createFileRoute } from "@tanstack/react-router";

import { ActionBar } from "../../components/erp/actions-bar";
import { RpcButton } from "../../components/erp/rpc-button";
import { AutoPanel, StatusPill, shortDate } from "../../components/erp/auto";

import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { useT } from "../../lib/i18n";

export const Route = createFileRoute("/governance/")({
  head: () => ({
    meta: [
      { title: "Change requests and approvals — Clove ERP" },
      {
        name: "description",
        content:
          "The governed path for master data: propose a change, preview it, have it approved, then apply it.",
      },
      { property: "og:title", content: "Change requests and approvals — Clove ERP" },
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

      <ActionBar
        title="Proposing a change"
        note="Proposing a change, and the mass change that proposes the same edit against many records."
        actions={[
          {
            label: "Apply a mass change",
            description:
              "Applies an approved mass change to every record it names. Each record's old value is kept, so the whole change can be reversed as one.",
            permission: "master_data.write",
            fn: "erp_apply_mass_change",
            fields: [
              {
                kind: "text",
                name: "p_mass_change_id",
                label: "Mass change id",
                required: true,
                placeholder: "0f9c1a2e-…",
                hint: "Copy the id from the mass change listed on this page.",
              },
            ],
            invalidates: ["erp_change_requests", "erp_items", "erp_parties"],
          },
          {
            label: "Reverse a mass change",
            description: "Puts every record the mass change touched back as it was.",
            permission: "master_data.write",
            fn: "erp_reverse_mass_change",
            fields: [
              {
                kind: "text",
                name: "p_mass_change_id",
                label: "Mass change id",
                required: true,
                placeholder: "0f9c1a2e-…",
                hint: "Copy the id from the mass change listed on this page.",
              },
            ],
            invalidates: ["erp_change_requests", "erp_items", "erp_parties"],
          },
          {
            label: "Open a change request",
            permission: "master_data.write",
            fn: "erp_open_change_request",
            fields: [
              {
                kind: "choice",
                name: "p_object_type",
                label: "Object",
                required: true,
                choices: [
                  { value: "item", label: "Product" },
                  { value: "party", label: "Business partner" },
                ],
              },
              {
                kind: "text",
                name: "p_object_id",
                label: "Record id",
                required: true,
                placeholder: "0f9c1a2e-…",
                hint: "The id of the product or business partner being changed — copy it from Master data.",
              },
              {
                kind: "text",
                name: "p_proposed",
                label: "Proposed change",
                required: true,
                hint: 'JSON, for example {"name":"New name"}.',
              },
              { kind: "text", name: "p_reason", label: "Reason" },
            ],
            invalidates: ["erp_change_requests", "erp_my_approvals"],
            mapArgs: (v) => ({
              p_object_type: v["p_object_type"],
              p_object_id: v["p_object_id"],
              p_proposed: JSON.parse(v["p_proposed"] ?? "{}"),
              ...(v["p_reason"] ? { p_reason: v["p_reason"] } : {}),
            }),
          },
          {
            label: "Open a mass change",
            permission: "master_data.write",
            fn: "erp_open_mass_change",
            fields: [
              {
                kind: "choice",
                name: "p_object_type",
                label: "Object",
                required: true,
                choices: [
                  { value: "item", label: "Product" },
                  { value: "party", label: "Business partner" },
                ],
              },
              {
                kind: "text",
                name: "p_selector",
                label: "Selector",
                required: true,
                hint: 'JSON, for example {"item_class":"finished_good"}.',
              },
              { kind: "text", name: "p_changes", label: "Changes", required: true, hint: "JSON." },
              { kind: "text", name: "p_reason", label: "Reason" },
            ],
            invalidates: ["erp_change_requests"],
            mapArgs: (v) => ({
              p_object_type: v["p_object_type"],
              p_selector: JSON.parse(v["p_selector"] ?? "{}"),
              p_changes: JSON.parse(v["p_changes"] ?? "{}"),
              ...(v["p_reason"] ? { p_reason: v["p_reason"] } : {}),
            }),
          },
        ]}
      />

      <AutoPanel
        title="My approvals"
        description="Tasks assigned to you, directly or through a role you hold."
        fn="erp_my_approvals"
        empty="Nothing is waiting on you. Requests appear here when an approval band routes one to you."
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
                <RpcButton
                  label="Approve"
                  fn="erp_decide_approval"
                  args={{ p_task_id: r["task_id"], p_decision: "approved" }}
                  invalidates={["erp_my_approvals", "erp_change_requests"]}
                />
                <RpcButton
                  label="Reject"
                  fn="erp_decide_approval"
                  args={{ p_task_id: r["task_id"], p_decision: "rejected" }}
                  invalidates={["erp_my_approvals", "erp_change_requests"]}
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
                <RpcButton
                  label="Submit"
                  fn="erp_submit_change_request"
                  args={{ p_change_request_id: r["change_request_id"] }}
                  permission="master_data.write"
                  invalidates={["erp_change_requests", "erp_my_approvals"]}
                />
              ) : r["status"] === "approved" ? (
                <RpcButton
                  label="Apply"
                  fn="erp_apply_change_request"
                  args={{ p_change_request_id: r["change_request_id"] }}
                  permission="master_data.write"
                  invalidates={["erp_change_requests", "erp_items", "erp_parties"]}
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
