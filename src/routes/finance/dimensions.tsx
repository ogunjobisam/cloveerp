import { createFileRoute } from "@tanstack/react-router";

import { type Field } from "../../components/erp/action";
import {
  ActionBar,
  HeaderActions,
  pickDocumentType,
  pickFrom,
} from "../../components/erp/actions-bar";
import { AutoPanel, StatusPill } from "../../components/erp/auto";
import { Gate } from "../../components/erp/gate";
import { InquiryBoard } from "../../components/erp/inquiry";
import { PageHeader } from "../../components/erp/page";
import { useT } from "../../lib/i18n";

export const Route = createFileRoute("/finance/dimensions")({
  head: () => ({
    meta: [
      { title: "Extra reporting tags — Clove ERP" },
      {
        name: "description",
        content:
          "Cost centres, projects and the like: the reporting tags a posting is analysed by, their values, how a posting takes them from the document, and which combinations an account allows.",
      },
      { property: "og:title", content: "Extra reporting tags — Clove ERP" },
      {
        property: "og:description",
        content:
          "Cost centres, other reporting tags and their values, the rules that work them out from the posting's facts, permitted-combination rules, and a preview of what a document would be stamped with.",
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
 * Extra reporting tags (analysis dimensions, specification v1.6 §5.7), with
 * cost centres first.
 *
 * Four doors existed for this and no screen called them, so a dimension could
 * be declared from a SQL client and nowhere else, and the two halves this
 * phase built — derivation from the document and the permitted-combination
 * rules — had nowhere to be written down. Everything here is declaration:
 * the posting bridge and the journal-line trigger are what read it.
 *
 * Cost centres are the COST_CENTRE tag, and were a screen of their own
 * (/finance/cost-centres, which now sends whoever opens it here). They are
 * kept here, first, because they are the tag everything posts against
 * (20261007170000). A cost centre nobody fills in is a cost centre nobody
 * reports on, so the value is derived: the document's own cost centre if it
 * names one, then its department, then the site it happened at. Retiring one
 * is a status rather than a deletion so the history that carries it still
 * reads.
 */
function Dimensions() {
  const { t, ui } = useT();

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader
        title={t("nav.finance_dimensions", "Extra reporting tags")}
        actions={
          <HeaderActions>
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
                      // A new cost centre is in use; the form arrived on
                      // "Choose…" and refused itself until somebody said so
                      // (J-104).
                      default: "active",
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
                    p_status: v["p_status"] || "active",
                  }),
                  invalidates: ["erp_cost_centres", "erp_dimension_values"],
                },
              ]}
            />

            <ActionBar
              title="Dimensions and values"
              note="A reporting tag can be worked out from the posting's facts — document, account, line, company — by a derivation that gives one of the tag's value codes. It is checked against those facts when it is saved, not discovered at month end."
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
                    // The door resolves the parent within the dimension chosen
                    // above; the picker cannot narrow to it, so every value is
                    // offered with its dimension named.
                    {
                      kind: "select",
                      name: "p_parent_code",
                      label: "Parent value",
                      required: false,
                      hint: "Optional. Groups values into a tree. Choose a value of the same dimension.",
                      options: {
                        fn: "erp_dimension_values",
                        value: "code",
                        label: ["dimension", "code", "name"],
                      },
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
                      kind: "multi",
                      name: "p_dimension_codes",
                      label: "Dimensions",
                      hint: "Tick every dimension a line to this account must carry. None ticked removes every requirement.",
                      join: ", ",
                      options: { fn: "erp_dimensions", value: "code", label: ["code", "name"] },
                    },
                  ],
                  // The door takes the several as one comma-separated line and has
                  // no default, so the key is always sent — an empty string is the
                  // instruction to remove every requirement. Field.join is honoured
                  // by buildArgs only, so the joining is done here.
                  mapArgs: (v, picked) => ({
                    p_account_id: v["p_account_id"],
                    p_dimension_codes: (picked?.lists["p_dimension_codes"] ?? []).join(", "),
                  }),
                  invalidates: ["erp_accounts"],
                },
              ]}
            />

            <ActionBar
              title="Combination rules"
              note="A rule has a scope (when it applies; empty is always) and a condition, both written over the account, the reporting tags and the company. Forbid refuses the line when the condition holds; permit refuses it when the condition does not. Evaluated for every journal, however it was raised."
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
          </HeaderActions>
        }
      >
        {ui(
          "Cost centres come first: every journal line is stamped with one, taken from the document's own cost centre, then its department, then its site, so the profit and loss and the balance sheet can be read for one of them alone. Any other reporting tag, a project or a region, is stamped from the accounting rule, from the document, or worked out from the document's facts by a rule you write here; a combination rule says which values an account may carry together.",
        )}
      </PageHeader>

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
            // The kind of document first, then that kind's documents by number,
            // party and state: a hundred documents of every type at once,
            // labelled by type code, was not a list anybody could choose from
            // (J-97). The type narrows the picker and is not sent.
            fields: [
              pickDocumentType(),
              {
                kind: "select",
                name: "p_document_id",
                label: "Document",
                required: true,
                options: {
                  fn: "erp_documents",
                  args: { p_limit: 100, p_exclude_cancelled: true },
                  argsFrom: { p_type_code: "p_type_code" },
                  value: "document_id",
                  label: ["document_number", "party", "state_name"],
                },
              },
            ],
            mapArgs: (v) => ({ p_document_id: v["p_document_id"] }),
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
