import { createFileRoute, Link } from "@tanstack/react-router";

import { ActionBar, pickFrom, pickItem, pickParty } from "../../components/erp/actions-bar";
import { RpcButton } from "../../components/erp/rpc-button";
import { AutoPanel, StatusPill, moneyCell, shortDate } from "../../components/erp/auto";

import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { useT } from "../../lib/i18n";
import { approvalStep, approvalSubject } from "../../lib/plain-words";

/** One picker for the four doors that take a mass change; the status is shown
 *  because applying wants a previewed one and reversing an applied one. */
const pickMassChange = () =>
  pickFrom(
    "erp_mass_changes",
    "mass_change_id",
    ["code", "object_type", "status"],
    "p_mass_change_id",
    "Mass change",
  );

export const Route = createFileRoute("/governance/")({
  // ?task=<id> arrives from an approval email, so the task a person was asked
  // about is marked on My approvals. Optional, so every existing link to this
  // screen stays valid without it.
  validateSearch: (search: Record<string, unknown>): { task?: string } =>
    typeof search["task"] === "string" && search["task"] !== "" ? { task: search["task"] } : {},
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
  const { task } = Route.useSearch();

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
            label: "Preview a mass change",
            description:
              "Works out which records the selector matches and what each would become. A mass change is applied only after it has been previewed.",
            permission: "master_data.write",
            fn: "erp_preview_mass_change",
            fields: [pickMassChange()],
            invalidates: ["erp_mass_changes"],
          },
          {
            label: "Apply a mass change",
            description:
              "Applies an approved mass change to every record it names. Each record's old value is kept, so the whole change can be reversed as one.",
            permission: "master_data.write",
            fn: "erp_apply_mass_change",
            fields: [{ ...pickMassChange(), hint: "Only a previewed mass change can be applied." }],
            invalidates: ["erp_mass_changes", "erp_change_requests", "erp_items", "erp_parties"],
          },
          {
            label: "Reverse a mass change",
            description: "Puts every record the mass change touched back as it was.",
            permission: "master_data.write",
            fn: "erp_reverse_mass_change",
            fields: [{ ...pickMassChange(), hint: "Only an applied mass change can be reversed." }],
            invalidates: ["erp_mass_changes", "erp_change_requests", "erp_items", "erp_parties"],
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
              // A picker's source is fixed, so it cannot follow the object type;
              // one picker per kind, and mapArgs sends whichever matches.
              {
                ...pickItem("p_item_id", "Product"),
                required: false,
                hint: "Only when the object is a product.",
              },
              {
                ...pickParty(undefined, "p_party_id", "Business partner", false),
                hint: "Only when the object is a business partner.",
              },
              {
                kind: "text",
                name: "p_proposed",
                label: "Proposed change",
                required: true,
                hint: 'JSON, for example {"name":"New name"}.',
              },
              {
                kind: "text",
                name: "p_reason",
                label: "Reason",
                placeholder: "Corrected after the supplier's notice",
                hint: "Optional. Shown to whoever approves this.",
              },
            ],
            invalidates: ["erp_change_requests", "erp_my_approvals"],
            mapArgs: (v) => ({
              p_object_type: v["p_object_type"],
              p_object_id:
                (v["p_object_type"] === "item" ? v["p_item_id"] : v["p_party_id"]) || null,
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
              {
                kind: "text",
                name: "p_reason",
                label: "Reason",
                placeholder: "Annual price review",
                hint: "Optional. Shown to whoever approves this.",
              },
            ],
            invalidates: ["erp_change_requests", "erp_mass_changes"],
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
        empty="Nothing is waiting on you. When somebody needs your approval for something, it appears here for you to approve or reject."
        rowKey={(r) => String(r["task_id"])}
        highlight={task ?? null}
        columns={[
          // What is being approved: the document by its number, linked to it,
          // with its type, partner and value. It said OBJECT "document".
          {
            header: "Approving",
            cell: (r) =>
              typeof r["document_id"] === "string" ? (
                <Link
                  to="/documents/$documentId"
                  params={{ documentId: r["document_id"] }}
                  className="underline underline-offset-2"
                >
                  {approvalSubject(r)}
                </Link>
              ) : (
                approvalSubject(r)
              ),
          },
          { header: "Business partner", cell: "partner" },
          { header: "Value", cell: moneyCell("value_minor", "currency"), numeric: true },
          { header: "Requested by", cell: "requested_by" },
          { header: "Requested", cell: (r) => shortDate(r["requested_at"]) },
          { header: "Step", cell: (r) => approvalStep(r) },
          { header: "Status", cell: (r) => <StatusPill value={r["status"]} /> },
          {
            header: "Decide",
            cell: (r) => (
              <span className="flex gap-2">
                <RpcButton
                  label="Approve"
                  fn="erp_decide_approval"
                  args={{ p_task_id: r["task_id"], p_approve: true }}
                  invalidates={["erp_my_approvals", "erp_change_requests"]}
                />
                <RpcButton
                  label="Reject"
                  fn="erp_decide_approval"
                  args={{ p_task_id: r["task_id"], p_approve: false }}
                  invalidates={["erp_my_approvals", "erp_change_requests"]}
                />
              </span>
            ),
          },
        ]}
      />

      {/*
        What happened to everything else.

        "Is it approved yet?" and "who approved that?" were answerable only on
        the administrator's organisation screen, which an approver has no
        reason to open and may not be allowed to. The same door is read here,
        beside the tasks it becomes history of, so the two halves of one
        question sit on one screen.

        It is the routing record: each step of each approval, the person it
        went to, and the person it would have gone to had nobody been covering
        for them. What was decided is kept against the record itself, so the
        subject links to it — a document page says "Approved by …" for every
        step of its own approval.

        The door asks for the audit permission and the panel says so plainly
        when the account does not hold it. That is deliberate: an approver who
        cannot read the history should be told the history exists, not shown a
        screen that pretends it does not.
      */}
      <AutoPanel
        title="Approval history"
        description="Every approval that has been raised, and each step of it: what it was for, who asked, and who it went to. Open the record to see what was decided."
        fn="erp_approval_audit"
        args={{ p_limit: 50 }}
        empty="Nothing has been through approval yet. Once something has, every step of it is kept here — what it was for, who asked, and who it went to."
        rowKey={(r) => `${String(r["stamp_id"])}-${String(r["seq"])}`}
        columns={[
          { header: "When", cell: (r) => shortDate(r["resolved_at"]) },
          {
            header: "Approving",
            cell: (r) =>
              r["object_type"] === "document" && typeof r["object_id"] === "string" ? (
                <Link
                  to="/documents/$documentId"
                  params={{ documentId: r["object_id"] }}
                  className="underline underline-offset-2"
                >
                  {approvalSubject(r)}
                </Link>
              ) : (
                approvalSubject(r)
              ),
          },
          { header: "Value", cell: moneyCell("value_minor", "currency"), numeric: true },
          { header: "Requested by", cell: "requester" },
          { header: "Step", cell: "seq", numeric: true },
          { header: "Went to", cell: "approver" },
          {
            header: "Covering for",
            cell: (r) => (r["covered"] === true ? String(r["approver_of_record"] ?? "—") : "—"),
          },
        ]}
      />

      {/* The panel above reads the routing stamp, which is written when a
          request is captured, so it can say who each step went to and not what
          they decided. This one reads the decision itself. */}
      <AutoPanel
        title="Decisions"
        description="Every approval decided in this organisation, newest first."
        fn="erp_approval_decisions"
        args={{ p_limit: 50 }}
        empty="Nothing has been decided yet. Approvals appear here once somebody approves or rejects them."
        rowKey={(r) => String(r["task_id"])}
        columns={[
          { header: "Decided", cell: (r) => shortDate(r["decided_at"]) },
          {
            header: "Approving",
            cell: (r) =>
              typeof r["document_id"] === "string" ? (
                <Link
                  to="/documents/$documentId"
                  params={{ documentId: r["document_id"] }}
                  className="underline underline-offset-2"
                >
                  {approvalSubject(r)}
                </Link>
              ) : (
                approvalSubject(r)
              ),
          },
          { header: "Value", cell: moneyCell("value_minor", "currency"), numeric: true },
          { header: "Step", cell: "step" },
          { header: "Outcome", cell: "outcome" },
          { header: "Decided by", cell: "decided_by" },
          {
            header: "Own request",
            cell: (r) => (r["own_request"] === true ? "Yes" : "—"),
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
