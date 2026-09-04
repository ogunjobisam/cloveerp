import { createFileRoute } from "@tanstack/react-router";

import { GoTo, type Field } from "../../components/erp/action";
import { ActionBar, pickFrom, pickItem, reason } from "../../components/erp/actions-bar";
import { Gate } from "../../components/erp/gate";
import { InquiryBoard } from "../../components/erp/inquiry";
import { PageHeader } from "../../components/erp/page";
import { DataPanel, Pill, Table } from "../../components/erp/panel";
import { useT } from "../../lib/i18n";

export const Route = createFileRoute("/finance/account-determination")({
  head: () => ({
    meta: [
      { title: "Account determination — Clove ERP" },
      {
        name: "description",
        content:
          "Posting classes and the determination matrix that decides which account and analysis a posting lands on, with a coverage report and no suspense fallback.",
      },
      { property: "og:title", content: "Account determination — Clove ERP" },
      {
        property: "og:description",
        content:
          "Accounting codes for products and business partners, the determination matrix, reasoned overrides, and a gap report before go-live.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <AccountDetermination />
    </Gate>
  ),
});

/** The postings a rule can be written against. */
const TRANSACTION_TYPES = [
  { value: "goods_receipt", label: "Goods receipt" },
  { value: "goods_issue", label: "Goods issue" },
  { value: "stock_adjustment", label: "Stock adjustment" },
  { value: "stock_revaluation", label: "Stock revaluation" },
  { value: "supplier_invoice", label: "Supplier invoice" },
  { value: "customer_invoice", label: "Customer invoice" },
  { value: "cost_of_sales", label: "Cost of sales" },
  { value: "production_variance", label: "Production variance" },
  { value: "landed_cost", label: "Landed cost" },
  { value: "cash_application", label: "Cash application" },
];

const pickAccount = (name = "p_account_id", label = "Account", required = true): Field => ({
  kind: "select",
  name,
  label,
  required,
  options: { fn: "erp_accounts", value: "account_id", label: ["code", "name"] },
});

const pickClass = (kind: "item" | "party", name: string, label: string): Field => ({
  kind: "select",
  name,
  label,
  required: false,
  options: {
    fn: "erp_posting_classes",
    args: { p_kind: kind },
    value: "posting_class_id",
    label: ["code", "name"],
  },
});

const pickAnyParty = (name = "p_party_id", label = "Party", required = true): Field => ({
  kind: "select",
  name,
  label,
  required,
  options: { fn: "erp_parties", value: "party_id", label: ["code", "name"] },
});

const pickEntity = (name = "p_entity_id", label = "Company", required = false): Field => ({
  kind: "select",
  name,
  label,
  required,
  options: { fn: "erp_entities", value: "entity_id", label: ["code", "name"] },
});

type PostingClass = {
  posting_class_id: string;
  kind: string;
  code: string;
  name: string;
  description: string | null;
  member_count: number;
  valid_from: string;
  valid_to: string | null;
  status: string;
};

type Rule = {
  rule_id: string;
  transaction_type: string;
  item_class_code: string | null;
  party_class_code: string | null;
  site_code: string | null;
  entity_code: string | null;
  ledger_code: string | null;
  legislation_pack_code: string | null;
  reason_code: string | null;
  account_code: string;
  account_name: string;
  dimensions: Record<string, unknown>;
  specificity: number;
  version: number;
  valid_from: string;
  valid_to: string | null;
  status: string;
};

type ItemClass = {
  item_id: string;
  item_code: string;
  item_name: string;
  posting_class_code: string | null;
  posting_class_name: string | null;
  valid_from: string | null;
  reason: string | null;
};

type PartyClass = {
  party_id: string;
  party_code: string;
  party_name: string;
  posting_class_code: string | null;
  posting_class_name: string | null;
  valid_from: string | null;
  reason: string | null;
};

type Override = {
  override_id: string;
  object_type: string;
  object_id: string;
  line_ref: string | null;
  account_code: string | null;
  account_name: string | null;
  reason: string;
  applied_at: string;
  applied_by: string | null;
};

function dimensionSummary(dimensions: Record<string, unknown> | null | undefined) {
  const entries = Object.entries(dimensions ?? {});
  if (entries.length === 0) return "—";
  return entries.map(([k, v]) => `${k}=${String(v)}`).join(", ");
}

function AccountDetermination() {
  const { ui } = useT();
  const invalidates = [
    "erp_posting_classes",
    "erp_item_posting_classes",
    "erp_party_posting_classes",
    "erp_account_determination_rules",
    "erp_posting_overrides",
    "erp_determination_coverage",
    "erp_determination_coverage_report",
  ];

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={ui("Account determination")}>
        {ui(
          "A posting class is what accounting cares about; the product is what operations cares about. Rules are written against the class, and one rule returns the account and its analysis together. Nothing falls into a suspense account: an unmatched posting is refused and reported.",
        )}
      </PageHeader>

      <ActionBar
        title="Posting classes"
        note="The vocabulary. Keep it short — a class exists because two things post differently, not because they are different things."
        actions={[
          {
            label: "Add or amend a posting class",
            permission: "finance.configure",
            fn: "erp_upsert_posting_class",
            fields: [
              {
                kind: "choice",
                name: "p_kind",
                label: "Applies to",
                required: true,
                choices: [
                  { value: "item", label: "Products" },
                  { value: "party", label: "Business partners" },
                ],
              },
              { kind: "text", name: "p_code", label: "Code", required: true },
              { kind: "text", name: "p_name", label: "Name", required: true },
              { kind: "text", name: "p_description", label: "What posts differently" },
              { kind: "date", name: "p_valid_from", label: "Valid from" },
            ],
            invalidates,
          },
          {
            label: "Retire a posting class",
            permission: "finance.configure",
            fn: "erp_retire_posting_class",
            fields: [
              pickFrom(
                "erp_posting_classes",
                "posting_class_id",
                ["kind", "code", "name"],
                "p_posting_class_id",
                "Posting class",
              ),
            ],
            invalidates,
          },
          {
            label: "Set a product's posting class",
            permission: "finance.configure",
            fn: "erp_set_item_posting_class",
            fields: [
              pickItem(),
              {
                ...pickClass("item", "p_posting_class_id", "Posting class"),
                required: true,
              },
              reason(),
              { kind: "date", name: "p_valid_from", label: "Valid from" },
            ],
            invalidates,
          },
          {
            label: "Set a partner's posting class",
            permission: "finance.configure",
            fn: "erp_set_party_posting_class",
            fields: [
              pickAnyParty(),
              {
                ...pickClass("party", "p_posting_class_id", "Posting class"),
                required: true,
              },
              reason(),
              { kind: "date", name: "p_valid_from", label: "Valid from" },
            ],
            invalidates,
          },
        ]}
      />

      <ActionBar
        title="Determination rules"
        note="The matrix. Leave a key field empty and the rule applies to anything; the narrowest matching rule wins."
        actions={[
          {
            label: "Add or amend a determination rule",
            permission: "finance.configure",
            fn: "erp_upsert_account_determination",
            fields: [
              {
                kind: "choice",
                name: "p_transaction_type",
                label: "Transaction type",
                required: true,
                choices: TRANSACTION_TYPES,
              },
              pickAccount(),
              pickClass("item", "p_item_class_id", "Product posting class"),
              pickClass("party", "p_party_class_id", "Partner posting class"),
              pickEntity(),
              { kind: "text", name: "p_reason_code", label: "Reason code" },
              {
                kind: "text",
                name: "p_legislation_pack_code",
                label: "Legislation pack",
                hint: "Leave empty unless one country posts differently.",
              },
              {
                kind: "text",
                name: "p_dimensions",
                label: "Dimensions (JSON)",
                hint: 'For example {"cost_centre":"OPS"}. The account and its analysis come from one rule.',
              },
              { kind: "text", name: "p_note", label: "Why this rule exists" },
              { kind: "date", name: "p_valid_from", label: "Valid from" },
            ],
            invalidates,
          },
          {
            label: "Retire a determination rule",
            permission: "finance.configure",
            fn: "erp_retire_account_determination",
            fields: [
              pickFrom(
                "erp_account_determination_rules",
                "rule_id",
                ["transaction_type", "account_code"],
                "p_rule_id",
                "Rule",
              ),
            ],
            invalidates,
          },
          {
            label: "Record a deliberate override",
            permission: "finance.post",
            fn: "erp_override_posting_account",
            fields: [
              { kind: "text", name: "p_object_type", label: "Object type", required: true },
              { kind: "text", name: "p_object_id", label: "Object identifier", required: true },
              pickAccount(),
              { kind: "text", name: "p_line_ref", label: "Line reference" },
              { ...reason(), required: true },
            ],
            invalidates,
          },
        ]}
      />

      <DataPanel<PostingClass>
        title={ui("Posting classes")}
        description={ui(
          "The accounting vocabulary, and how many products or business partners currently carry each class.",
        )}
        fn="erp_posting_classes"
        empty={ui("No posting classes yet. Until one exists, nothing can be determined.")}
      >
        {(rows) => (
          <Table
            columns={[
              ui("Applies to"),
              ui("Code"),
              ui("Name"),
              ui("What posts differently"),
              ui("Members"),
              ui("Status"),
            ]}
          >
            {rows.map((c) => (
              <tr key={c.posting_class_id} className="border-b border-border/60 last:border-0">
                <td className="py-2 pr-4">{c.kind}</td>
                <td className="py-2 pr-4 font-mono text-xs">{c.code}</td>
                <td className="py-2 pr-4">{c.name}</td>
                <td className="py-2 pr-4">{c.description ?? "—"}</td>
                <td className="py-2 pr-4 tabular-nums">{c.member_count}</td>
                <td className="py-2 pr-4">
                  <Pill tone={c.status === "active" ? "ok" : "muted"}>{c.status}</Pill>
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<Rule>
        title={ui("Determination matrix")}
        description={ui(
          "Transaction type, posting classes and place on the left; the account and its analysis on the right.",
        )}
        fn="erp_account_determination_rules"
        empty={ui("No rules yet. Every posting would be refused until at least one exists.")}
      >
        {(rows) => (
          <Table
            columns={[
              ui("Transaction type"),
              ui("Product class"),
              ui("Partner class"),
              ui("Company"),
              ui("Reason"),
              ui("Account"),
              ui("Dimensions"),
              ui("Specificity"),
              ui("Status"),
            ]}
          >
            {rows.map((r) => (
              <tr key={r.rule_id} className="border-b border-border/60 last:border-0">
                <td className="py-2 pr-4">{r.transaction_type}</td>
                <td className="py-2 pr-4 font-mono text-xs">{r.item_class_code ?? ui("Any")}</td>
                <td className="py-2 pr-4 font-mono text-xs">{r.party_class_code ?? ui("Any")}</td>
                <td className="py-2 pr-4 font-mono text-xs">{r.entity_code ?? ui("Any")}</td>
                <td className="py-2 pr-4">{r.reason_code ?? "—"}</td>
                <td className="py-2 pr-4">
                  <span className="font-mono text-xs">{r.account_code}</span> {r.account_name}
                </td>
                <td className="py-2 pr-4">{dimensionSummary(r.dimensions)}</td>
                <td className="py-2 pr-4 tabular-nums">{r.specificity}</td>
                <td className="py-2 pr-4">
                  <Pill tone={r.status === "active" ? "ok" : "muted"}>{r.status}</Pill>
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<ItemClass>
        title={ui("Products and their posting class")}
        description={ui("Products without a class are listed first — they cannot be posted.")}
        fn="erp_item_posting_classes"
        args={{ p_limit: 200 }}
        empty={ui("No product exists yet, so nothing can be classed for posting.")}
        emptyAction={<GoTo to="/master-data">{ui("Open Common data")}</GoTo>}
      >
        {(rows) => (
          <Table
            columns={[ui("Product"), ui("Name"), ui("Posting class"), ui("From"), ui("Reason")]}
          >
            {rows.map((i) => (
              <tr key={i.item_id} className="border-b border-border/60 last:border-0">
                <td className="py-2 pr-4 font-mono text-xs">{i.item_code}</td>
                <td className="py-2 pr-4">{i.item_name}</td>
                <td className="py-2 pr-4">
                  {i.posting_class_code ? (
                    <Pill tone="ok">{i.posting_class_code}</Pill>
                  ) : (
                    <Pill tone="warn">{ui("Not set")}</Pill>
                  )}
                </td>
                <td className="py-2 pr-4 tabular-nums">{i.valid_from ?? "—"}</td>
                <td className="py-2 pr-4">{i.reason ?? "—"}</td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<PartyClass>
        title={ui("Business partners and their posting class")}
        description={ui(
          "A business partner class separates, for example, export from domestic settlement.",
        )}
        fn="erp_party_posting_classes"
        args={{ p_limit: 200 }}
        empty={ui("No business partner exists yet, so nothing can be classed for settlement.")}
        emptyAction={<GoTo to="/master-data">{ui("Open Common data")}</GoTo>}
      >
        {(rows) => (
          <Table columns={[ui("Business partner"), ui("Name"), ui("Posting class"), ui("From")]}>
            {rows.map((p) => (
              <tr key={p.party_id} className="border-b border-border/60 last:border-0">
                <td className="py-2 pr-4 font-mono text-xs">{p.party_code}</td>
                <td className="py-2 pr-4">{p.party_name}</td>
                <td className="py-2 pr-4">
                  {p.posting_class_code ? (
                    <Pill tone="ok">{p.posting_class_code}</Pill>
                  ) : (
                    <Pill tone="muted">{ui("Not set")}</Pill>
                  )}
                </td>
                <td className="py-2 pr-4 tabular-nums">{p.valid_from ?? "—"}</td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<Override>
        title={ui("Deliberate overrides")}
        description={ui(
          "Every departure from the matrix, with the reason given and the person who gave it.",
        )}
        fn="erp_posting_overrides"
        args={{ p_limit: 100 }}
        empty={ui(
          "No overrides have been recorded. Every posting so far has followed the matrix above.",
        )}
      >
        {(rows) => (
          <Table
            columns={[ui("When"), ui("Object"), ui("Line"), ui("Account"), ui("Reason"), ui("By")]}
          >
            {rows.map((o) => (
              <tr key={o.override_id} className="border-b border-border/60 last:border-0">
                <td className="py-2 pr-4 tabular-nums">
                  {o.applied_at.slice(0, 16).replace("T", " ")}
                </td>
                <td className="py-2 pr-4">{o.object_type}</td>
                <td className="py-2 pr-4">{o.line_ref ?? "—"}</td>
                <td className="py-2 pr-4 font-mono text-xs">{o.account_code ?? "—"}</td>
                <td className="py-2 pr-4">{o.reason}</td>
                <td className="py-2 pr-4">{o.applied_by ?? "—"}</td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <InquiryBoard
        inquiries={[
          {
            fn: "erp_determine_account",
            label: "Where would this post?",
            description:
              "The account and analysis a posting would take, and the rule that chose it.",
            fields: [
              {
                kind: "choice",
                name: "p_transaction_type",
                label: "Transaction type",
                required: true,
                choices: TRANSACTION_TYPES,
              },
              { ...pickItem(), required: false },
              pickAnyParty("p_party_id", "Party", false),
              pickEntity(),
              { kind: "text", name: "p_reason_code", label: "Reason code" },
            ],
          },
          {
            fn: "erp_determination_coverage",
            label: "What is not covered yet?",
            description:
              "Every posting class, transaction type and company combination with no rule behind it.",
            fields: [],
          },
          {
            // The rules on this screen are one of two account-selection
            // mechanisms, and journals are raised by the other one — a
            // document type's posting rule, resolved against the chart of
            // accounts of the company the document is on. This report covers
            // both, so an account retired out from under a live rule shows up
            // here rather than at the first posting after month end.
            fn: "erp_determination_coverage_report",
            label: "What could stop a posting?",
            description:
              "Both mechanisms: the determination rules on this screen, and the posting rules that actually raise journals. Nothing falls into suspense, so each finding is a refusal waiting to happen.",
            fields: [],
          },
        ]}
      />
    </div>
  );
}
