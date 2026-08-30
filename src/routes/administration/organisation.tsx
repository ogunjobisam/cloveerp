import { createFileRoute } from "@tanstack/react-router";

import { type Field } from "../../components/erp/action";
import { ActionBar, pickFrom, reason } from "../../components/erp/actions-bar";
import { Gate } from "../../components/erp/gate";
import { InquiryBoard } from "../../components/erp/inquiry";
import { PageHeader, RefreshButton } from "../../components/erp/page";
import { DataPanel, Pill, Table } from "../../components/erp/panel";
import { useT } from "../../lib/i18n";

export const Route = createFileRoute("/administration/organisation")({
  head: () => ({
    meta: [
      { title: "Organisation and approval routing — ERPWare" },
      {
        name: "description",
        content:
          "Departments, membership, value bands and named approver assignments — the configuration that decides who approves what.",
      },
      { property: "og:title", content: "Organisation and approval routing — ERPWare" },
      {
        property: "og:description",
        content:
          "Departments, membership, value bands and named approver assignments, with a preview of the chain a request would take.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <Organisation />
    </Gate>
  ),
});

/** The object types a routing rule can be written against. */
const OBJECT_TYPES = [
  { value: "requisition", label: "Requisition" },
  { value: "purchase_order", label: "Purchase order" },
  { value: "sales_order", label: "Sales order" },
  { value: "supplier_invoice", label: "Supplier invoice" },
  { value: "payment_run", label: "Payment run" },
  { value: "change_request", label: "Change request" },
];

const pickDepartment = (
  name = "p_department_id",
  label = "Department",
  required = true,
): Field => ({
  kind: "select",
  name,
  label,
  required,
  options: { fn: "erp_departments", value: "department_id", label: ["code", "name"] },
});

const pickPrincipal = (name: string, label: string, required = true): Field => ({
  kind: "select",
  name,
  label,
  required,
  options: { fn: "erp_principals", value: "id", label: ["display_name"] },
});

type Delegation = {
  delegation_id: string;
  delegator: string | null;
  delegate: string | null;
  kind: string;
  object_type: string | null;
  lower_bound_minor: number | null;
  upper_bound_minor: number | null;
  reason: string | null;
  valid_from: string;
  valid_to: string | null;
  in_force: boolean;
  status: string;
};

type AuditRow = {
  stamp_id: number;
  resolved_at: string;
  object_type: string;
  department_code: string | null;
  requester: string | null;
  seq: number;
  source: string;
  rule_id: string | null;
  rule_version: number | null;
  approver: string | null;
  approver_of_record: string | null;
  covered: boolean;
  cover_kind: string | null;
};

type Department = {
  department_id: string;
  code: string;
  name: string;
  manager: string | null;
  parent_code: string | null;
  default_cost_centre: string | null;
  member_count: number;
  band_count: number;
  valid_from: string;
  valid_to: string | null;
  status: string;
};

type Member = {
  membership_id: string;
  display_name: string | null;
  department_code: string;
  is_primary: boolean;
  valid_from: string;
  valid_to: string | null;
  status: string;
};

type Band = {
  band_id: string;
  department_code: string;
  object_type: string;
  seq: number;
  lower_bound_minor: number;
  upper_bound_minor: number | null;
  currency: string;
  is_parallel: boolean;
  rerun_lower_bands: boolean;
  vacancy: string;
  version: number;
  status: string;
};

type Assignment = {
  assignment_id: string;
  subject_kind: string;
  subject_label: string | null;
  object_type: string;
  approver: string | null;
  mode: string;
  lower_bound_minor: number | null;
  upper_bound_minor: number | null;
  status: string;
};

type Stamp = {
  stamp_id: number;
  object_type: string;
  department_code: string | null;
  value_minor: number | null;
  currency: string | null;
  resolved_at: string;
  resolved_by: string | null;
  resolved_chain: { steps?: { seq: number; source: string }[] };
};

function money(minor: number | null | undefined, currency: string | null | undefined) {
  if (minor === null || minor === undefined) return "—";
  return `${currency ?? ""} ${(minor / 100).toLocaleString(undefined, {
    minimumFractionDigits: 2,
  })}`.trim();
}

function Organisation() {
  const { ui } = useT();
  const invalidates = [
    "erp_departments",
    "erp_department_members",
    "erp_approval_bands",
    "erp_approver_assignments",
  ];

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={ui("Organisation and approval routing")}>
        {ui(
          "A department is one object: it routes an approval and it carries the posting. Bands decide who approves by value; a named assignment overrides that for a person, a role or a whole department.",
        )}
      </PageHeader>

      <div className="flex justify-end">
        <RefreshButton />
      </div>

      <ActionBar
        note="Departments and membership. A person's primary department at capture is the one that routes their request."
        actions={[
          {
            label: "Add or amend a department",
            permission: "administration.configure",
            fn: "erp_upsert_department",
            fields: [
              { kind: "text", name: "p_code", label: "Code", required: true },
              { kind: "text", name: "p_name", label: "Name", required: true },
              pickPrincipal("p_manager_user_id", "Manager"),
              pickDepartment("p_parent_department_id", "Parent department", false),
              { kind: "text", name: "p_default_cost_centre", label: "Default cost centre" },
              { kind: "date", name: "p_valid_from", label: "Valid from" },
            ],
            invalidates,
          },
          {
            label: "Assign someone to a department",
            permission: "administration.configure",
            fn: "erp_assign_department",
            fields: [
              pickPrincipal("p_app_user_id", "Person"),
              pickDepartment(),
              {
                kind: "choice",
                name: "p_is_primary",
                label: "Primary",
                boolean: true,
                choices: [
                  { value: "true", label: "Primary department" },
                  { value: "false", label: "Secondary" },
                ],
              },
              { kind: "date", name: "p_valid_from", label: "Valid from" },
              { kind: "date", name: "p_valid_to", label: "Valid to" },
            ],
            invalidates,
          },
          {
            label: "End a membership",
            permission: "administration.configure",
            fn: "erp_end_department_membership",
            fields: [
              pickFrom(
                "erp_department_members",
                "membership_id",
                ["display_name", "department_code"],
                "p_membership_id",
                "Membership",
              ),
              { kind: "date", name: "p_valid_to", label: "Ends on" },
            ],
            invalidates,
          },
        ]}
      />

      <ActionBar
        note="Value bands and named assignments. Resolution runs named assignment first, then the department's bands."
        actions={[
          {
            label: "Add or amend a band",
            permission: "administration.configure",
            fn: "erp_upsert_approval_band",
            fields: [
              pickDepartment(),
              {
                kind: "choice",
                name: "p_object_type",
                label: "Object type",
                required: true,
                choices: OBJECT_TYPES,
              },
              { kind: "number", name: "p_seq", label: "Band number", required: true },
              { kind: "money", name: "p_lower_bound_minor", label: "From", currency: "GBP" },
              {
                kind: "money",
                name: "p_upper_bound_minor",
                label: "Up to",
                currency: "GBP",
                hint: "Leave empty for the top band.",
              },
              pickPrincipal("p_approver_user_id", "Named approver", false),
              {
                kind: "text",
                name: "p_approver_role_code",
                label: "Approver role code",
                hint: "Tried in the department first, then at company level.",
              },
              {
                kind: "choice",
                name: "p_use_line_manager",
                label: "Fall back to the line manager",
                boolean: true,
                choices: [
                  { value: "false", label: "No" },
                  { value: "true", label: "Yes" },
                ],
              },
              {
                kind: "choice",
                name: "p_is_parallel",
                label: "Approvers act",
                boolean: true,
                choices: [
                  { value: "false", label: "In sequence" },
                  { value: "true", label: "In parallel" },
                ],
              },
              {
                kind: "choice",
                name: "p_rerun_lower_bands",
                label: "Lower bands re-run",
                boolean: true,
                choices: [
                  { value: "true", label: "Yes — lower approvers still act" },
                  { value: "false", label: "No — the higher band replaces them" },
                ],
              },
              {
                kind: "number",
                name: "p_escalate_after_hours",
                label: "Escalate after (hours)",
              },
              {
                kind: "choice",
                name: "p_vacancy",
                label: "When nobody resolves",
                choices: [
                  { value: "hold_and_raise", label: "Hold the request and raise an exception" },
                  { value: "escalate_to_manager", label: "Escalate to the department manager" },
                ],
              },
              { kind: "number", name: "p_tolerance_pct", label: "Re-approval tolerance (%)" },
            ],
            invalidates,
          },
          {
            label: "Retire a band",
            permission: "administration.configure",
            fn: "erp_retire_approval_band",
            fields: [
              pickFrom(
                "erp_approval_bands",
                "band_id",
                ["department_code", "object_type", "seq"],
                "p_band_id",
                "Band",
              ),
            ],
            invalidates,
          },
          {
            label: "Assign a named approver",
            permission: "administration.configure",
            fn: "erp_assign_named_approver",
            fields: [
              {
                kind: "choice",
                name: "p_subject_kind",
                label: "Applies to",
                required: true,
                choices: [
                  { value: "principal", label: "A person" },
                  { value: "department", label: "A department" },
                  { value: "role", label: "A role" },
                ],
              },
              { kind: "text", name: "p_subject_id", label: "Subject identifier", required: true },
              {
                kind: "choice",
                name: "p_object_type",
                label: "Object type",
                required: true,
                choices: OBJECT_TYPES,
              },
              pickPrincipal("p_approver_user_id", "Approver"),
              {
                kind: "choice",
                name: "p_mode",
                label: "Mode",
                choices: [
                  { value: "prepends", label: "Sits in front of the department bands" },
                  { value: "replaces", label: "Replaces the department bands" },
                ],
              },
              { kind: "money", name: "p_lower_bound_minor", label: "From", currency: "GBP" },
              { kind: "money", name: "p_upper_bound_minor", label: "Up to", currency: "GBP" },
              reason(),
              { kind: "date", name: "p_valid_from", label: "Valid from" },
              { kind: "date", name: "p_valid_to", label: "Valid to" },
            ],
            invalidates,
          },
          {
            label: "End a named assignment",
            permission: "administration.configure",
            fn: "erp_end_approver_assignment",
            fields: [
              pickFrom(
                "erp_approver_assignments",
                "assignment_id",
                ["subject_label", "object_type"],
                "p_assignment_id",
                "Assignment",
              ),
            ],
            invalidates,
          },
        ]}
      />

      <ActionBar
        note="Cover while somebody is away. A delegation keeps the approver of record and records who acted; a substitution replaces them outright."
        actions={[
          {
            label: "Delegate approvals",
            permission: "administration.configure",
            fn: "erp_delegate_approval",
            fields: [
              pickPrincipal("p_delegator_user_id", "Approver away"),
              pickPrincipal("p_delegate_user_id", "Covering for them"),
              {
                kind: "choice",
                name: "p_kind",
                label: "Kind of cover",
                choices: [
                  { value: "delegation", label: "Delegation — the original stays the approver of record" },
                  { value: "substitution", label: "Substitution — the delegate takes the decision as their own" },
                ],
              },
              { kind: "date", name: "p_valid_from", label: "From" },
              { kind: "date", name: "p_valid_to", label: "Until" },
              {
                kind: "choice",
                name: "p_object_type",
                label: "Only for",
                choices: OBJECT_TYPES,
                hint: "Leave empty to cover everything they approve.",
              },
              { kind: "money", name: "p_lower_bound_minor", label: "From value", currency: "GBP" },
              { kind: "money", name: "p_upper_bound_minor", label: "Up to value", currency: "GBP" },
              reason(),
            ],
            invalidates,
          },
          {
            label: "End cover",
            permission: "administration.configure",
            fn: "erp_end_approval_delegation",
            fields: [
              pickFrom(
                "erp_approval_delegations",
                "delegation_id",
                ["delegator", "delegate"],
                "p_delegation_id",
                "Cover",
              ),
              reason(),
            ],
            invalidates,
          },
        ]}
      />

      <DataPanel<Department>
        title={ui("Departments")}
        description={ui(
          "Each department is also a reporting dimension value, so a department means the same thing in a stock report and in a profit and loss.",
        )}
        fn="erp_departments"
        empty={ui("No departments are configured yet.")}
      >
        {(rows) => (
          <Table
            columns={[
              ui("Code"),
              ui("Name"),
              ui("Manager"),
              ui("Parent"),
              ui("Cost centre"),
              ui("People"),
              ui("Bands"),
              ui("Status"),
            ]}
          >
            {rows.map((d) => (
              <tr key={d.department_id} className="border-b border-border/60 last:border-0">
                <td className="py-2 pr-4 font-mono text-xs">{d.code}</td>
                <td className="py-2 pr-4">{d.name}</td>
                <td className="py-2 pr-4">{d.manager ?? "—"}</td>
                <td className="py-2 pr-4 font-mono text-xs">{d.parent_code ?? "—"}</td>
                <td className="py-2 pr-4">{d.default_cost_centre ?? "—"}</td>
                <td className="py-2 pr-4 tabular-nums">{d.member_count}</td>
                <td className="py-2 pr-4 tabular-nums">{d.band_count}</td>
                <td className="py-2 pr-4">
                  <Pill tone={d.status === "active" ? "ok" : "muted"}>{d.status}</Pill>
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<Member>
        title={ui("Membership")}
        description={ui(
          "The primary department in force when a request is raised is the one that routes it.",
        )}
        fn="erp_department_members"
        empty={ui("Nobody has been assigned to a department yet.")}
      >
        {(rows) => (
          <Table
            columns={[
              ui("Person"),
              ui("Department"),
              ui("Primary"),
              ui("From"),
              ui("To"),
              ui("Status"),
            ]}
          >
            {rows.map((m) => (
              <tr key={m.membership_id} className="border-b border-border/60 last:border-0">
                <td className="py-2 pr-4">{m.display_name ?? "—"}</td>
                <td className="py-2 pr-4 font-mono text-xs">{m.department_code}</td>
                <td className="py-2 pr-4">
                  {m.is_primary ? <Pill tone="ok">{ui("Primary")}</Pill> : ui("Secondary")}
                </td>
                <td className="py-2 pr-4 tabular-nums">{m.valid_from}</td>
                <td className="py-2 pr-4 tabular-nums">{m.valid_to ?? "—"}</td>
                <td className="py-2 pr-4">
                  <Pill tone={m.status === "active" ? "ok" : "muted"}>{m.status}</Pill>
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<Band>
        title={ui("Value bands")}
        description={ui(
          "Band one takes the request up to its ceiling; higher bands add authority above it.",
        )}
        fn="erp_approval_bands"
        empty={ui("No bands are configured. Until one exists, nothing routes by value.")}
      >
        {(rows) => (
          <Table
            columns={[
              ui("Department"),
              ui("Object type"),
              ui("Band"),
              ui("From"),
              ui("Up to"),
              ui("Order"),
              ui("Lower bands"),
              ui("Vacancy"),
              ui("Version"),
            ]}
          >
            {rows.map((b) => (
              <tr key={b.band_id} className="border-b border-border/60 last:border-0">
                <td className="py-2 pr-4 font-mono text-xs">{b.department_code}</td>
                <td className="py-2 pr-4">{b.object_type}</td>
                <td className="py-2 pr-4 tabular-nums">{b.seq}</td>
                <td className="py-2 pr-4 tabular-nums">{money(b.lower_bound_minor, b.currency)}</td>
                <td className="py-2 pr-4 tabular-nums">
                  {b.upper_bound_minor === null
                    ? ui("No ceiling")
                    : money(b.upper_bound_minor, b.currency)}
                </td>
                <td className="py-2 pr-4">{b.is_parallel ? ui("Parallel") : ui("Sequential")}</td>
                <td className="py-2 pr-4">{b.rerun_lower_bands ? ui("Re-run") : ui("Replaced")}</td>
                <td className="py-2 pr-4">
                  <Pill tone={b.vacancy === "hold_and_raise" ? "warn" : "muted"}>{b.vacancy}</Pill>
                </td>
                <td className="py-2 pr-4 tabular-nums">{b.version}</td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<Assignment>
        title={ui("Named approver assignments")}
        description={ui(
          "A contractor routed to their engaging manager, a new starter under supervision, a project team routed to the project owner.",
        )}
        fn="erp_approver_assignments"
        empty={ui("No named assignments. Everything routes by department band.")}
      >
        {(rows) => (
          <Table
            columns={[
              ui("Applies to"),
              ui("Subject"),
              ui("Object type"),
              ui("Approver"),
              ui("Mode"),
              ui("From"),
              ui("Up to"),
              ui("Status"),
            ]}
          >
            {rows.map((a) => (
              <tr key={a.assignment_id} className="border-b border-border/60 last:border-0">
                <td className="py-2 pr-4">{a.subject_kind}</td>
                <td className="py-2 pr-4">{a.subject_label ?? "—"}</td>
                <td className="py-2 pr-4">{a.object_type}</td>
                <td className="py-2 pr-4">{a.approver ?? "—"}</td>
                <td className="py-2 pr-4">
                  <Pill tone={a.mode === "replaces" ? "warn" : "muted"}>{a.mode}</Pill>
                </td>
                <td className="py-2 pr-4 tabular-nums">{money(a.lower_bound_minor, "GBP")}</td>
                <td className="py-2 pr-4 tabular-nums">{money(a.upper_bound_minor, "GBP")}</td>
                <td className="py-2 pr-4">
                  <Pill tone={a.status === "active" ? "ok" : "muted"}>{a.status}</Pill>
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<Stamp>
        title={ui("Routing decisions taken")}
        description={ui(
          "The chain as it was resolved, with the rule and version that chose each approver.",
        )}
        fn="erp_approval_routing_stamps"
        args={{ p_limit: 50 }}
        empty={ui("Nothing has been routed yet.")}
      >
        {(rows) => (
          <Table
            columns={[
              ui("When"),
              ui("Object type"),
              ui("Department"),
              ui("Value"),
              ui("Approvers"),
              ui("Resolved by"),
            ]}
          >
            {rows.map((s) => (
              <tr key={s.stamp_id} className="border-b border-border/60 last:border-0">
                <td className="py-2 pr-4 tabular-nums">
                  {s.resolved_at.slice(0, 16).replace("T", " ")}
                </td>
                <td className="py-2 pr-4">{s.object_type}</td>
                <td className="py-2 pr-4 font-mono text-xs">{s.department_code ?? "—"}</td>
                <td className="py-2 pr-4 tabular-nums">{money(s.value_minor, s.currency)}</td>
                <td className="py-2 pr-4 tabular-nums">{s.resolved_chain?.steps?.length ?? 0}</td>
                <td className="py-2 pr-4">{s.resolved_by ?? "—"}</td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<Delegation>
        title={ui("Cover in force")}
        description={ui(
          "Cover is followed at resolution time, up to three hops, and never back to the person who raised the request.",
        )}
        fn="erp_approval_delegations"
        empty={ui("Nobody is covering for anybody.")}
      >
        {(rows) => (
          <Table
            columns={[
              ui("Approver away"),
              ui("Covered by"),
              ui("Kind"),
              ui("Only for"),
              ui("From"),
              ui("Until"),
              ui("In force"),
            ]}
          >
            {rows.map((d) => (
              <tr key={d.delegation_id} className="border-b border-border/60 last:border-0">
                <td className="py-2 pr-4">{d.delegator ?? "—"}</td>
                <td className="py-2 pr-4">{d.delegate ?? "—"}</td>
                <td className="py-2 pr-4">
                  <Pill tone={d.kind === "substitution" ? "warn" : "muted"}>{d.kind}</Pill>
                </td>
                <td className="py-2 pr-4">{d.object_type ?? ui("Everything")}</td>
                <td className="py-2 pr-4 tabular-nums">{d.valid_from?.slice(0, 10)}</td>
                <td className="py-2 pr-4 tabular-nums">{d.valid_to?.slice(0, 10) ?? "—"}</td>
                <td className="py-2 pr-4">
                  <Pill tone={d.in_force ? "ok" : "muted"}>
                    {d.in_force ? ui("Yes") : ui("No")}
                  </Pill>
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<AuditRow>
        title={ui("Approval audit")}
        description={ui(
          "Every resolved step, the rule version that chose it, who acted and who remained the approver of record.",
        )}
        fn="erp_approval_audit"
        args={{ p_limit: 200 }}
        empty={ui("No approvals have been resolved yet.")}
      >
        {(rows) => (
          <Table
            columns={[
              ui("When"),
              ui("Object type"),
              ui("Requester"),
              ui("Step"),
              ui("Chosen by"),
              ui("Rule version"),
              ui("Acted"),
              ui("Of record"),
              ui("Cover"),
            ]}
          >
            {rows.map((r) => (
              <tr
                key={`${r.stamp_id}-${r.seq}`}
                className="border-b border-border/60 last:border-0"
              >
                <td className="py-2 pr-4 tabular-nums">
                  {r.resolved_at.slice(0, 16).replace("T", " ")}
                </td>
                <td className="py-2 pr-4">{r.object_type}</td>
                <td className="py-2 pr-4">{r.requester ?? "—"}</td>
                <td className="py-2 pr-4 tabular-nums">{r.seq}</td>
                <td className="py-2 pr-4">{r.source}</td>
                <td className="py-2 pr-4 tabular-nums">{r.rule_version ?? "—"}</td>
                <td className="py-2 pr-4">{r.approver ?? "—"}</td>
                <td className="py-2 pr-4">{r.approver_of_record ?? "—"}</td>
                <td className="py-2 pr-4">
                  {r.covered ? (
                    <Pill tone="warn">{r.cover_kind ?? ui("Cover")}</Pill>
                  ) : (
                    <span className="text-xs text-muted-foreground">—</span>
                  )}
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <InquiryBoard
        inquiries={[
          {
            fn: "erp_preview_approval_chain",
            label: "Who would approve this?",
            description:
              "The chain a request of this value would take, and which rule chose each approver.",
            fields: [
              {
                kind: "choice",
                name: "p_object_type",
                label: "Object type",
                required: true,
                choices: OBJECT_TYPES,
              },
              {
                kind: "money",
                name: "p_value_minor",
                label: "Value",
                currency: "GBP",
                required: true,
              },
              pickDepartment("p_department_id", "Department", false),
            ],
          },
        ]}
      />
    </div>
  );
}
