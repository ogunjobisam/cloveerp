import { createFileRoute } from "@tanstack/react-router";

import { type Field } from "../../components/erp/action";
import { ActionBar, pickFrom } from "../../components/erp/actions-bar";
import { AutoPanel, StatusPill } from "../../components/erp/auto";
import { Gate } from "../../components/erp/gate";
import { InquiryBoard } from "../../components/erp/inquiry";
import { PageHeader } from "../../components/erp/page";
import { useT } from "../../lib/i18n";

export const Route = createFileRoute("/finance/dimensions")({
  head: () => ({
    meta: [
      { title: "Analysis dimensions — Clove ERP" },
      {
        name: "description",
        content:
          "Cost centres, projects and the like: their values, how a posting derives them from the document, and which combinations an account allows.",
      },
      { property: "og:title", content: "Analysis dimensions — Clove ERP" },
      {
        property: "og:description",
        content:
          "Dimensions and values, derivation rules over the posting's facts, permitted-combination rules, and a preview of what a document would be stamped with.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <Dimensions />
    </Gate>
  ),
});

const pickAccount = (name = "p_account_id", label = "Nominal account", required = true): Field => ({
  kind: "select",
  name,
  label,
  required,
  options: { fn: "erp_accounts", value: "account_id", label: ["code", "name"] },
});

const pickDimension = (name = "p_dimension_code", label = "Dimension"): Field => ({
  kind: "select",
  name,
  label,
  required: true,
  options: { fn: "erp_dimensions", value: "code", label: ["code", "name"] },
});

const yesNo = (name: string, label: string, hint?: string): Field => ({
  kind: "choice",
  name,
  label,
  required: true,
  boolean: true,
  choices: [
    { value: "false", label: "No" },
    { value: "true", label: "Yes" },
  ],
  ...(hint ? { hint } : {}),
});

const parseJson = (raw: string | undefined) => (raw && raw.trim() !== "" ? JSON.parse(raw) : null);

/**
 * Analysis dimensions, specification v1.6 §5.7.
 *
 * Four doors existed for this and no screen called them, so a dimension could
 * be declared from a SQL client and nowhere else, and the two halves this
 * phase built — derivation from the document and the permitted-combination
 * rules — had nowhere to be written down. Everything here is declaration:
 * the posting bridge and the journal-line trigger are what read it.
 */
function Dimensions() {
  const { t } = useT();

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={t("nav.finance_dimensions", "Analysis dimensions")}>
        A dimension is a way of analysing a posting: cost centre, project, region. A value is
        stamped on every journal line from the posting rule, from the document, or derived from the
        document&rsquo;s facts by a rule you write here; a combination rule says which values an
        account may carry together.
      </PageHeader>

      <ActionBar
        title="Dimensions and values"
        note="A derivation is a JsonLogic expression over the posting's facts — document, account, line, entity — that returns one of the dimension's value codes. It is checked against those facts when it is saved, not discovered at month end."
        actions={[
          {
            label: "Add or amend a dimension",
            permission: "finance.configure",
            fn: "erp_upsert_dimension",
            fields: [
              {
                kind: "text",
                name: "p_code",
                label: "Code",
                required: true,
                hint: "CC, DEPT, PROJECT.",
              },
              {
                kind: "text",
                name: "p_name",
                label: "Name",
                required: true,
                placeholder: "Cost centre",
              },
              {
                kind: "text",
                name: "p_derivation",
                label: "Derivation",
                hint: 'JSON, for example {"if": [{"==": [{"var": "document.base_type"}, "purchase_order"]}, "PURCH", "GEN"]} or {"var": "document.site_code"}. Empty means no derivation.',
              },
              yesNo(
                "p_is_mandatory_default",
                "Mandatory on every line",
                "Every posting must carry it, whatever the account says.",
              ),
              {
                kind: "choice",
                name: "p_status",
                label: "Status",
                required: true,
                choices: [
                  { value: "active", label: "Active" },
                  { value: "inactive", label: "Inactive" },
                ],
              },
            ],
            mapArgs: (v) => ({
              p_code: v["p_code"],
              p_name: v["p_name"],
              p_derivation: parseJson(v["p_derivation"]),
              p_is_mandatory_default: v["p_is_mandatory_default"] === "true",
              p_status: v["p_status"] ?? "active",
            }),
            invalidates: ["erp_dimensions"],
          },
          {
            label: "Add or amend a value",
            permission: "finance.configure",
            fn: "erp_upsert_dimension_value",
            fields: [
              pickDimension(),
              {
                kind: "text",
                name: "p_code",
                label: "Value code",
                required: true,
                placeholder: "CC-1000",
              },
              {
                kind: "text",
                name: "p_name",
                label: "Name",
                required: true,
                placeholder: "Leeds warehouse",
              },
              {
                kind: "text",
                name: "p_parent_code",
                label: "Parent value code",
                placeholder: "CC-1",
                hint: "Optional. Use it to group values into a tree.",
              },
              { kind: "date", name: "p_valid_from", label: "Valid from" },
              { kind: "date", name: "p_valid_to", label: "Valid to" },
              {
                kind: "choice",
                name: "p_status",
                label: "Status",
                required: true,
                choices: [
                  { value: "active", label: "Active" },
                  { value: "inactive", label: "Inactive" },
                ],
              },
            ],
            invalidates: ["erp_dimension_values", "erp_dimensions"],
          },
          {
            label: "Require dimensions on an account",
            description: "The dimensions a line to this account must carry.",
            permission: "finance.configure",
            fn: "erp_set_account_dimension_requirements",
            fields: [
              pickAccount(),
              {
                kind: "text",
                name: "p_dimension_codes",
                label: "Dimension codes",
                hint: "Comma separated. Empty removes every requirement.",
              },
            ],
            mapArgs: (v) => ({
              p_account_id: v["p_account_id"],
              p_dimension_codes: v["p_dimension_codes"] ?? "",
            }),
            invalidates: ["erp_accounts"],
          },
        ]}
      />

      <ActionBar
        title="Combination rules"
        note="A rule has a scope (when it applies; empty is always) and a condition, both JsonLogic over account, dimensions and entity. Forbid refuses the line when the condition holds; permit refuses it when the condition does not. Evaluated for every journal, however it was raised."
        actions={[
          {
            label: "Add or amend a rule",
            permission: "finance.configure",
            fn: "erp_upsert_dimension_rule",
            fields: [
              {
                kind: "text",
                name: "p_code",
                label: "Code",
                required: true,
                placeholder: "CC-MANDATORY-SPEND",
                hint: "A short code for this rule.",
              },
              {
                kind: "text",
                name: "p_name",
                label: "Name",
                required: true,
                placeholder: "Cost centre required on spend",
              },
              {
                kind: "text",
                name: "p_scope",
                label: "Scope",
                hint: 'JSON, for example {"==": [{"var": "account.code"}, "8100"]}. Empty applies always.',
              },
              {
                kind: "text",
                name: "p_condition",
                label: "Condition",
                required: true,
                hint: 'JSON, for example {"in": [{"var": "dimensions.CC"}, ["PURCH", "OPS"]]}.',
              },
              {
                kind: "choice",
                name: "p_effect",
                label: "Effect",
                required: true,
                choices: [
                  { value: "forbid", label: "Forbid when the condition holds" },
                  { value: "permit", label: "Permit only when the condition holds" },
                ],
              },
              {
                kind: "text",
                name: "p_message",
                label: "Message",
                hint: "What the person posting is told.",
              },
              pickFrom(
                "erp_entities",
                "entity_id",
                ["code", "name"],
                "p_entity_id",
                "Company",
                undefined,
                false,
              ),
              {
                kind: "choice",
                name: "p_status",
                label: "Status",
                required: true,
                choices: [
                  { value: "active", label: "Active" },
                  { value: "inactive", label: "Inactive" },
                ],
              },
            ],
            mapArgs: (v) => ({
              p_code: v["p_code"],
              p_name: v["p_name"],
              p_condition: parseJson(v["p_condition"]),
              p_effect: v["p_effect"] ?? "forbid",
              p_message: v["p_message"] || null,
              p_entity_id: v["p_entity_id"] || null,
              p_scope: parseJson(v["p_scope"]),
              p_status: v["p_status"] ?? "active",
            }),
            invalidates: ["erp_dimension_rules"],
          },
        ]}
      />

      <InquiryBoard
        inquiries={[
          {
            label: "Values of a dimension",
            description: "Every value, its parent and the window it is valid in.",
            permission: "finance.read",
            fn: "erp_dimension_values",
            fields: [pickDimension()],
          },
          {
            label: "Preview a document's dimensions",
            description:
              "What each journal line would be stamped with when this document posts, and whether the rules let it through.",
            permission: "finance.read",
            fn: "erp_preview_dimensions",
            fields: [
              pickFrom(
                "erp_documents",
                "document_id",
                ["document_number", "document_type", "state"],
                "p_document_id",
                "Document",
              ),
            ],
          },
        ]}
      />

      <AutoPanel
        title="Dimensions"
        description="What this organisation analyses postings by, and how each is derived."
        fn="erp_dimensions"
        empty="No dimension declared. Add one above; a department creates its own DEPARTMENT dimension."
        rowKey={(r, i) => String(r["dimension_id"] ?? i)}
        columns={[
          { header: "Code", cell: "code" },
          { header: "Name", cell: "name" },
          { header: "Values", cell: "value_count", numeric: true },
          { header: "Mandatory", cell: "is_mandatory_default" },
          { header: "Derived", cell: (r) => (r["derivation"] ? "Yes" : "No") },
          { header: "Status", cell: (r) => <StatusPill value={r["status"]} /> },
        ]}
      />

      <AutoPanel
        title="Combination rules"
        description="Which values an account may carry together, and what the person posting is told."
        fn="erp_dimension_rules"
        empty="No combination rule. Every combination of values is allowed until one is written."
        rowKey={(r, i) => String(r["rule_id"] ?? i)}
        columns={[
          { header: "Code", cell: "code" },
          { header: "Name", cell: "name" },
          { header: "Effect", cell: "effect" },
          { header: "Message", cell: "message" },
          { header: "Status", cell: (r) => <StatusPill value={r["status"]} /> },
        ]}
      />
    </div>
  );
}
