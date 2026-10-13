import { createFileRoute } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useState } from "react";

import {
  ActionButton,
  ActionDialog,
  ErrorNote,
  GoTo,
  useErpAction,
} from "../../components/erp/action";
import { pickParty } from "../../components/erp/actions-bar";
import { BankStatementImport } from "../../components/erp/bank-statement-import";
import { Gate } from "../../components/erp/gate";
import { useErpSession } from "../../components/erp/session-context";
import { PageHeader } from "../../components/erp/page";
import { Pill, Table } from "../../components/erp/panel";
import { callErp, hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { formatMinor } from "../../lib/money";

export const Route = createFileRoute("/finance/bank")({
  head: () => ({
    meta: [
      { title: "Bank — Clove ERP" },
      {
        name: "description",
        content:
          "The company's bank accounts: the ledger account each posts to, its details, and which one receipts and payments use.",
      },
      { property: "og:title", content: "Bank — Clove ERP" },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <Bank />
    </Gate>
  ),
});

/** Shaped by public.erp_bank_accounts() (20261013010000). */
type BankAccount = {
  bank_account_id: string;
  entity_id: string;
  entity: string;
  account_code: string;
  name: string;
  sort_code: string | null;
  account_last4: string | null;
  currency: string;
  is_default: boolean;
  status: "open" | "closed";
  closed_reason: string | null;
};

/** Shaped by public.erp_bank_statements() (20261013020000). */
type Statement = {
  statement_id: string;
  bank_account_id: string;
  bank_account: string;
  source: string;
  starts_on: string;
  ends_on: string;
  opening_minor: number;
  closing_minor: number;
  currency: string;
  line_count: number;
  unmatched: number;
  status: "imported" | "reconciled";
};

/** Shaped by public.erp_bank_statement_lines() (20261013030000, 20261013040000). */
type StatementLineRow = {
  line_id: string;
  line_no: number;
  booked_on: string;
  amount_minor: number;
  description: string;
  reference: string | null;
  status: string;
  match: {
    match_id: string;
    method: keyof typeof METHOD;
    note: string | null;
    lines: number;
    entries: string[];
  } | null;
  /** The journal that posts the line, or waits to. */
  entry: {
    journal_id: string;
    journal_number: string | null;
    origin: "rule" | "hand";
    state: "draft" | "submitted" | "returned" | "posted" | "reversed";
    narrative: string;
    rule: string | null;
  } | null;
  /** The rule that would post the line, while nothing else has. */
  rule: string | null;
};

/** Shaped by public.erp_bank_rules() (20261013040000). */
type BankRule = {
  rule_id: string;
  name: string;
  words: string;
  direction: "in" | "out" | "either";
  account: string;
  bank_account: string | null;
  priority: number;
  status: "active" | "inactive";
  retired_reason: string | null;
};

/** How a match was made, as the line says it. */
const METHOD = {
  reference: "By reference",
  payment_run: "Payment run",
  amount_date: "By amount and date",
  manual: "By hand",
  entry: "Entry",
  receipt: "Receive cash",
  settlement: "Card settlement",
} as const;

/** A waiting entry's journal, as the line says it. */
const ENTRY_STATE = {
  draft: "Waiting for approval",
  submitted: "Waiting for approval",
  returned: "Sent back",
  posted: "Posted",
  reversed: "Posted",
} as const;

/** Money in, out or either, as a rule says it. */
const DIRECTION = { in: "In", out: "Out", either: "Either" } as const;

/** What a match or an unmatch changes, read again. */
const MATCH_READS = [
  "erp_bank_statements",
  "erp_bank_statement_lines",
  "erp_bank_match_candidates",
  "erp_journals",
];

/** What every bank account form reads again once it has changed one. */
const READS = ["erp_bank_accounts"];

/**
 * A company's bank accounts.
 *
 * The first screen of bank reconciliation (13 October 2026): a statement is
 * imported into a bank account and reconciled against it, so the accounts come
 * first. Which one is the default matters beyond this screen: receipts and
 * payments land in it (erp.company_bank_account). The full account number is
 * never kept, only its last four digits.
 */
function Bank() {
  const { t, ui } = useT();
  const accounts = useQuery({
    queryKey: ["erp_bank_accounts"],
    queryFn: () => callErp<BankAccount[]>("erp_bank_accounts", {}),
  });
  const rows = accounts.data ?? [];

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader
        title={t("nav.finance_bank", "Bank")}
        actions={
          <ActionDialog
            trigger={<ActionButton>{ui("Open a bank account")}</ActionButton>}
            title="Open a bank account"
            description="A bank account posts to a ledger account of its own. Give a new ledger code to open one, or the code of an existing bank ledger account."
            permission="finance.configure"
            fn="erp_define_bank_account"
            fields={[
              {
                kind: "select",
                name: "p_entity_id",
                label: "Company",
                required: true,
                options: { fn: "erp_entities", value: "entity_id", label: ["code", "name"] },
              },
              {
                kind: "text",
                name: "p_account_code",
                label: "Ledger code",
                required: true,
                placeholder: "1010",
                hint: "A new code opens a bank ledger account beside the company's existing bank.",
              },
              {
                kind: "text",
                name: "p_name",
                label: "Name",
                required: true,
                placeholder: "Reserve account",
              },
              { kind: "text", name: "p_sort_code", label: "Sort code", placeholder: "20-00-00" },
              {
                kind: "text",
                name: "p_account_last4",
                label: "Last four digits of the account number",
                placeholder: "1234",
                hint: "Only the last four digits are kept, never the full number.",
              },
              {
                kind: "choice",
                name: "p_make_default",
                label: "Make it the default",
                boolean: true,
                choices: [
                  { value: "false", label: "No" },
                  { value: "true", label: "Yes" },
                ],
                hint: "Receipts and payments land in the default.",
              },
            ]}
            invalidates={READS}
            submitLabel="Open the account"
          />
        }
        howItWorks="Receipts and payments land in the default bank account. Statements are imported into a bank account and reconciled against it. The default cannot be closed until another account takes its place."
      >
        The company&apos;s bank accounts, and which one receipts and payments use.
      </PageHeader>

      <ErrorNote error={accounts.error} />

      <section className="min-w-0 rounded-xl border border-border bg-card px-4 py-4 sm:px-5">
        <h2 className="mb-3 text-sm font-semibold">{ui("Bank accounts")}</h2>
        {accounts.isPending ? (
          <p role="status" className="text-sm text-muted-foreground">
            {ui("Reading the bank accounts…")}
          </p>
        ) : rows.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            {ui("No bank account yet. Installing finance opens the company's first.")}
          </p>
        ) : (
          <Table
            columns={[
              ui("Company"),
              ui("Ledger code"),
              ui("Name"),
              ui("Sort code"),
              ui("Account ending"),
              ui("Currency"),
              "",
            ]}
          >
            {rows.map((r) => (
              <tr key={r.bank_account_id} className="border-b border-border/60 align-top">
                <td className="py-2 pr-4 font-mono">{r.entity}</td>
                <td className="py-2 pr-4 font-mono">{r.account_code}</td>
                <td className="py-2 pr-4">
                  <span className="mr-2">{r.name}</span>
                  {r.is_default ? <Pill tone="ok">{ui("Default")}</Pill> : null}
                  {r.status === "closed" ? <Pill tone="muted">{ui("Closed")}</Pill> : null}
                </td>
                <td className="py-2 pr-4 font-mono">{r.sort_code ?? "—"}</td>
                <td className="py-2 pr-4 font-mono">{r.account_last4 ?? "—"}</td>
                <td className="py-2 pr-4">{r.currency}</td>
                <td className="py-2">
                  {r.status === "open" ? (
                    <div className="flex flex-wrap gap-2">
                      <ActionDialog
                        trigger={
                          <ActionButton variant="secondary">
                            {ui("Change this bank account")}
                          </ActionButton>
                        }
                        title="Change this bank account"
                        description="Change its name, sort code or last four digits, or make it the default. A box left empty keeps what is there."
                        permission="finance.configure"
                        fn="erp_update_bank_account"
                        fields={[
                          { kind: "text", name: "p_name", label: "Name", placeholder: r.name },
                          {
                            kind: "text",
                            name: "p_sort_code",
                            label: "Sort code",
                            placeholder: r.sort_code ?? "20-00-00",
                          },
                          {
                            kind: "text",
                            name: "p_account_last4",
                            label: "Last four digits of the account number",
                            placeholder: r.account_last4 ?? "1234",
                          },
                          {
                            kind: "choice",
                            name: "p_make_default",
                            label: "Make it the default",
                            boolean: true,
                            choices: [
                              { value: "false", label: "No" },
                              { value: "true", label: "Yes" },
                            ],
                          },
                        ]}
                        prefill={{ p_bank_account_id: r.bank_account_id }}
                        context={`${r.entity} · ${r.account_code} · ${r.name}`}
                        invalidates={READS}
                        submitLabel="Save"
                      />
                      {r.is_default ? null : (
                        <ActionDialog
                          trigger={
                            <ActionButton variant="secondary">
                              {ui("Close this bank account")}
                            </ActionButton>
                          }
                          title="Close this bank account"
                          description="A closed bank account takes no cash and no statement. Defining it again reopens it."
                          permission="finance.configure"
                          fn="erp_close_bank_account"
                          fields={[
                            {
                              kind: "text",
                              name: "p_reason",
                              label: "Why it is closed",
                              required: true,
                              placeholder: "The company no longer banks here",
                              hint: "Kept with the account for the auditor.",
                            },
                          ]}
                          prefill={{ p_bank_account_id: r.bank_account_id }}
                          context={`${r.entity} · ${r.account_code} · ${r.name}`}
                          invalidates={READS}
                          submitLabel="Close the account"
                        />
                      )}
                    </div>
                  ) : (
                    <span className="text-xs text-muted-foreground">{r.closed_reason}</span>
                  )}
                </td>
              </tr>
            ))}
          </Table>
        )}
      </section>

      <BankStatementImport accounts={rows.filter((r) => r.status === "open")} />

      <Statements />

      <Rules />
    </div>
  );
}

/**
 * The statements imported, newest first, each with how many of its lines are
 * still unmatched. A statement opens to its lines; the latest of an account,
 * imported in error and nothing done with it, can be withdrawn.
 */
function Statements() {
  const { ui } = useT();
  const { session } = useErpSession();
  const [open, setOpen] = useState<string | null>(null);
  const statements = useQuery({
    queryKey: ["erp_bank_statements"],
    queryFn: () => callErp<Statement[]>("erp_bank_statements", {}),
  });
  const lines = useQuery({
    queryKey: ["erp_bank_statement_lines", { p_statement_id: open }],
    queryFn: () =>
      callErp<StatementLineRow[]>("erp_bank_statement_lines", { p_statement_id: open }),
    enabled: open !== null,
  });
  const rows = statements.data ?? [];
  const autoMatch = useErpAction({
    fn: "erp_auto_match_bank_statement",
    invalidates: MATCH_READS,
    outcome: (result) => {
      const r = result as { reference?: number; payment_run?: number; amount_date?: number } | null;
      const matched = (r?.reference ?? 0) + (r?.payment_run ?? 0) + (r?.amount_date ?? 0);
      return matched > 0
        ? `${ui("Lines matched automatically")}: ${matched}`
        : ui("No line could be matched with certainty.");
    },
  });
  const applyRules = useErpAction({
    fn: "erp_apply_bank_rules",
    invalidates: MATCH_READS,
    outcome: (result) => {
      const posted = (result as { posted?: number } | null)?.posted ?? 0;
      return posted > 0 ? `${ui("Lines posted by rule")}: ${posted}` : ui("No line fits a rule.");
    },
  });
  const currency = rows.find((r) => r.statement_id === open)?.currency ?? "GBP";

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card px-4 py-4 sm:px-5">
      <h2 className="mb-3 text-sm font-semibold">{ui("Statements")}</h2>
      <ErrorNote error={statements.error} />
      <ErrorNote error={autoMatch.error} />
      <ErrorNote error={applyRules.error} />
      {statements.isPending ? (
        <p role="status" className="text-sm text-muted-foreground">
          {ui("Reading the statements…")}
        </p>
      ) : rows.length === 0 ? (
        <p className="text-sm text-muted-foreground">{ui("No statement imported yet.")}</p>
      ) : (
        <Table
          columns={[
            ui("Bank account"),
            ui("Period"),
            ui("Opening balance"),
            ui("Closing balance"),
            ui("Lines"),
            ui("Unmatched"),
            "",
          ]}
        >
          {rows.map((r) => (
            <tr key={r.statement_id} className="border-b border-border/60 align-top">
              <td className="py-2 pr-4">{r.bank_account}</td>
              <td className="py-2 pr-4 tabular-nums">
                {r.starts_on} – {r.ends_on}
              </td>
              <td className="py-2 pr-4 tabular-nums">{formatMinor(r.opening_minor, r.currency)}</td>
              <td className="py-2 pr-4 tabular-nums">{formatMinor(r.closing_minor, r.currency)}</td>
              <td className="py-2 pr-4 tabular-nums">{r.line_count}</td>
              <td className="py-2 pr-4 tabular-nums">{r.unmatched}</td>
              <td className="py-2">
                <div className="flex flex-wrap gap-2">
                  <ActionButton
                    variant="secondary"
                    onClick={() => setOpen(open === r.statement_id ? null : r.statement_id)}
                  >
                    {open === r.statement_id ? ui("Hide the lines") : ui("Show the lines")}
                  </ActionButton>
                  {r.status === "imported" && r.unmatched > 0 ? (
                    <ActionButton
                      variant="secondary"
                      busy={
                        autoMatch.isPending &&
                        autoMatch.variables?.["p_statement_id"] === r.statement_id
                      }
                      disabled={!hasPermission(session, "finance.post")}
                      onClick={() => {
                        setOpen(r.statement_id);
                        autoMatch.mutate({ p_statement_id: r.statement_id });
                      }}
                    >
                      {ui("Match automatically")}
                    </ActionButton>
                  ) : null}
                  {r.status === "imported" && r.unmatched > 0 ? (
                    <ActionButton
                      variant="secondary"
                      busy={
                        applyRules.isPending &&
                        applyRules.variables?.["p_statement_id"] === r.statement_id
                      }
                      disabled={!hasPermission(session, "finance.post")}
                      onClick={() => {
                        setOpen(r.statement_id);
                        applyRules.mutate({ p_statement_id: r.statement_id });
                      }}
                    >
                      {ui("Apply the rules")}
                    </ActionButton>
                  ) : null}
                  {r.status === "imported" ? (
                    <ActionDialog
                      trigger={
                        <ActionButton variant="secondary">
                          {ui("Withdraw this statement")}
                        </ActionButton>
                      }
                      title="Withdraw this statement"
                      description="Takes out the latest statement of an account, imported in error and nothing done with it yet. Its lines can then be imported again."
                      permission="finance.post"
                      fn="erp_withdraw_bank_statement"
                      fields={[
                        {
                          kind: "text",
                          name: "p_reason",
                          label: "Why it is withdrawn",
                          required: true,
                          placeholder: "Imported into the wrong account",
                          hint: "Kept with the withdrawal for the auditor.",
                        },
                      ]}
                      prefill={{ p_statement_id: r.statement_id }}
                      context={`${r.bank_account} · ${r.starts_on} – ${r.ends_on}`}
                      invalidates={["erp_bank_statements"]}
                      submitLabel="Withdraw it"
                    />
                  ) : null}
                </div>
              </td>
            </tr>
          ))}
        </Table>
      )}
      {open !== null ? (
        <div className="mt-4">
          <ErrorNote error={lines.error} />
          <Table
            columns={[
              ui("Date"),
              ui("Description"),
              ui("Reference"),
              ui("Amount"),
              ui("State"),
              ui("Matched to"),
              "",
            ]}
          >
            {(lines.data ?? []).map((l) => (
              <tr key={l.line_id} className="border-b border-border/60 align-top">
                <td className="py-1.5 pr-4 tabular-nums">{l.booked_on}</td>
                <td className="py-1.5 pr-4">{l.description}</td>
                <td className="py-1.5 pr-4">{l.reference ?? ""}</td>
                <td className="py-1.5 pr-4 text-right tabular-nums">
                  {formatMinor(l.amount_minor, currency)}
                </td>
                <td className="py-1.5 pr-4">
                  {ui(l.status === "unmatched" ? "Unmatched" : "Matched")}
                </td>
                <td className="py-1.5 pr-4">
                  {l.entry ? (
                    <div className="flex min-w-0 flex-col gap-0.5">
                      <span>{l.entry.narrative}</span>
                      <span className="text-xs text-muted-foreground">
                        {ui(ENTRY_STATE[l.entry.state])}
                        {l.entry.journal_number ? ` · ${l.entry.journal_number}` : ""}
                      </span>
                    </div>
                  ) : l.match ? (
                    <div className="flex min-w-0 flex-col gap-0.5">
                      <span>{l.match.entries.join(", ")}</span>
                      <span className="text-xs text-muted-foreground">
                        {ui(METHOD[l.match.method])}
                        {l.match.note ? ` · ${l.match.note}` : ""}
                      </span>
                    </div>
                  ) : null}
                </td>
                <td className="py-1.5">{lineAction(l, open, currency, ui)}</td>
              </tr>
            ))}
          </Table>
        </div>
      ) : null}
    </section>
  );
}

/**
 * What can be done with one line of a statement not yet reconciled: an
 * unmatched line is matched by hand to what the books hold, the same amount
 * first; a matched line's match is undone, with a reason.
 */
function lineAction(
  l: StatementLineRow,
  statementId: string,
  currency: string,
  ui: (text: string) => string,
) {
  if (l.status === "unmatched" && l.entry) {
    return <GoTo to="/finance/journals">{ui("Journals")}</GoTo>;
  }
  if (l.status === "unmatched") {
    const context = `${l.booked_on} · ${l.description} · ${formatMinor(l.amount_minor, currency)}`;
    return (
      <div className="flex flex-wrap gap-2">
        <ActionDialog
          trigger={<ActionButton variant="secondary">{ui("Match")}</ActionButton>}
          title="Match this line"
          description="Choose what the books hold for this line. What you choose must come to the line's amount."
          permission="finance.post"
          fn="erp_match_bank_lines"
          fields={[
            {
              kind: "multi",
              name: "p_entry_keys",
              label: "Matched to",
              required: true,
              options: {
                fn: "erp_bank_match_candidates",
                args: { p_line_id: l.line_id },
                value: "entry_key",
                label: ["label"],
                describe: (row, t) =>
                  [
                    String(row["label"] ?? ""),
                    String(row["posted_on"] ?? ""),
                    formatMinor(Number(row["amount_minor"] ?? 0), currency),
                    row["same_amount"] === true ? t("Same amount") : "",
                    row["quoted"] === true ? t("Quoted on the line") : "",
                  ]
                    .filter((part) => part !== "")
                    .join(" · "),
                empty: "Nothing in the books is waiting to be matched to a line of this sign.",
              },
            },
            {
              kind: "multi",
              name: "p_other_line_ids",
              label: "Other lines in this match",
              hint: "When the bank shows in several lines what the books hold as one, or the other way round.",
              options: {
                fn: "erp_bank_statement_lines",
                args: { p_statement_id: statementId },
                value: "line_id",
                label: ["description"],
                keep: (row) => row["status"] === "unmatched" && row["line_id"] !== l.line_id,
                describe: (row) =>
                  [
                    String(row["booked_on"] ?? ""),
                    String(row["description"] ?? ""),
                    formatMinor(Number(row["amount_minor"] ?? 0), currency),
                  ].join(" · "),
              },
            },
            {
              kind: "text",
              name: "p_note",
              label: "Why do these go together?",
              required: true,
              placeholder: "Paid two invoices in one transfer",
              hint: "Kept with the match for the reviewer.",
            },
          ]}
          prefill={{ p_line_id: l.line_id }}
          context={`${l.booked_on} · ${l.description} · ${formatMinor(l.amount_minor, currency)}`}
          invalidates={MATCH_READS}
          submitLabel="Match"
        />
        {l.rule ? (
          <ActionDialog
            trigger={<ActionButton variant="secondary">{ui("Post by rule")}</ActionButton>}
            title="Post by rule"
            description="A line that quotes a rule's words posts to its account when you press Apply the rules, or Post by rule on the line. The lowest priority applies first."
            permission="finance.post"
            fn="erp_post_bank_line_by_rule"
            fields={[]}
            prefill={{ p_line_id: l.line_id }}
            context={`${context} · ${ui("Rule")}: ${l.rule}`}
            invalidates={MATCH_READS}
            submitLabel="Post by rule"
          />
        ) : null}
        {l.amount_minor > 0 ? (
          <ActionDialog
            trigger={<ActionButton variant="secondary">{ui("Receive cash")}</ActionButton>}
            title="Receive cash from this line"
            description="The line is applied as cash from the customer against the invoices you tick, dated the day the bank booked it. What they do not take stays on the customer's account."
            permission="finance.post"
            fn="erp_receive_bank_line"
            fields={[
              pickParty("customer", "p_party_id", "Customer"),
              {
                kind: "multi",
                name: "p_invoice_ids",
                label: "Invoices",
                required: true,
                hint: "Tick the invoices this money pays.",
                options: {
                  fn: "erp_open_invoices",
                  args: { p_currency: currency },
                  argsFrom: { p_party_id: "p_party_id" },
                  value: "document_id",
                  label: ["document_number"],
                  describe: (row) =>
                    [
                      String(row["document_number"] ?? ""),
                      formatMinor(Number(row["owing_minor"] ?? 0), currency),
                      String(row["due_date"] ?? ""),
                    ].join(" · "),
                  empty: "This customer owes nothing in this currency.",
                },
              },
            ]}
            prefill={{ p_line_id: l.line_id }}
            context={context}
            invalidates={[...MATCH_READS, "erp_open_invoices", "erp_receivables_ageing"]}
            submitLabel="Receive cash"
          />
        ) : null}
        <ActionDialog
          trigger={<ActionButton variant="secondary">{ui("Post by hand")}</ActionButton>}
          title="Post this line by hand"
          description="The line is posted against the account you choose once somebody else who may approve journals approves it on the Journals screen. A bank entry carries no VAT: a line with VAT on it is a supplier's bill and its payment."
          permission="finance.post"
          fn="erp_propose_bank_entry"
          fields={[
            {
              kind: "select",
              name: "p_account_id",
              label: "Post to",
              required: true,
              options: {
                fn: "erp_accounts",
                value: "account_id",
                label: ["code", "name"],
                keep: (row) =>
                  row["control_kind"] === null &&
                  row["is_postable"] === true &&
                  row["account_type"] !== "statistical",
              },
            },
            {
              kind: "text",
              name: "p_narrative",
              label: "What was the money?",
              required: true,
              placeholder: "Interest paid by the bank for September",
              hint: "Whoever approves it reads this.",
            },
          ]}
          prefill={{ p_line_id: l.line_id }}
          context={context}
          invalidates={MATCH_READS}
          submitLabel="Submit for approval"
        />
      </div>
    );
  }
  if (l.status === "matched") {
    return (
      <ActionDialog
        trigger={<ActionButton variant="secondary">{ui("Unmatch")}</ActionButton>}
        title="Undo this match"
        description="The line, and any other line in the same match, is unmatched again, and what it was matched to waits in the books once more."
        permission="finance.post"
        fn="erp_unmatch_bank_line"
        fields={[
          {
            kind: "text",
            name: "p_reason",
            label: "Why was the match wrong?",
            required: true,
            placeholder: "The transfer paid a different invoice",
            hint: "Kept with the change for the reviewer.",
          },
        ]}
        prefill={{ p_line_id: l.line_id }}
        context={`${l.booked_on} · ${l.description} · ${formatMinor(l.amount_minor, currency)}`}
        invalidates={MATCH_READS}
        submitLabel="Unmatch"
      />
    );
  }
  return null;
}

/**
 * The bank rules: the words a line quotes and the account it posts to. A rule
 * posts when the reconciler presses Apply the rules or Post by rule; one that
 * no longer applies is retired with a reason, and what it posted stands.
 */
function Rules() {
  const { ui } = useT();
  const rules = useQuery({
    queryKey: ["erp_bank_rules"],
    queryFn: () => callErp<BankRule[]>("erp_bank_rules", {}),
  });
  const rows = rules.data ?? [];
  const reads = ["erp_bank_rules", "erp_bank_statement_lines"];

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card px-4 py-4 sm:px-5">
      <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
        <h2 className="text-sm font-semibold">{ui("Bank rules")}</h2>
        <ActionDialog
          trigger={<ActionButton variant="secondary">{ui("Define a rule")}</ActionButton>}
          title="Define a bank rule"
          description="A line that quotes a rule's words posts to its account when you press Apply the rules, or Post by rule on the line. The lowest priority applies first."
          permission="finance.configure"
          fn="erp_define_bank_rule"
          fields={[
            {
              kind: "text",
              name: "p_name",
              label: "Rule name",
              required: true,
              placeholder: "Account fee",
              hint: "Shown on the line and on the journal it posts.",
            },
            {
              kind: "text",
              name: "p_words",
              label: "Words on the line",
              required: true,
              placeholder: "ACCOUNT FEE",
              hint: "The words the bank prints on the line, as a whole word or words. Case and punctuation do not matter.",
            },
            {
              kind: "select",
              name: "p_account_id",
              label: "Posts to",
              required: true,
              options: {
                fn: "erp_accounts",
                value: "account_id",
                label: ["code", "name"],
                keep: (row) =>
                  row["control_kind"] === null &&
                  row["is_postable"] === true &&
                  row["account_type"] !== "statistical",
              },
            },
            {
              kind: "choice",
              name: "p_direction",
              label: "Money",
              required: true,
              choices: [
                { value: "out", label: "Out" },
                { value: "in", label: "In" },
                { value: "either", label: "Either" },
              ],
            },
            {
              kind: "select",
              name: "p_bank_account_id",
              label: "Only on this bank account",
              hint: "Leave empty for every bank account of the company.",
              options: {
                fn: "erp_bank_accounts",
                value: "bank_account_id",
                label: ["name"],
                keep: (row) => row["status"] === "open",
              },
            },
            {
              kind: "number",
              name: "p_priority",
              label: "Priority",
              placeholder: "100",
              hint: "The lowest applies first when two rules fit a line.",
            },
          ]}
          invalidates={reads}
          submitLabel="Define a rule"
        />
      </div>
      <p className="mb-3 max-w-prose text-sm text-muted-foreground">
        {ui(
          "A line that quotes a rule's words posts to its account when you press Apply the rules, or Post by rule on the line. The lowest priority applies first.",
        )}
      </p>
      <ErrorNote error={rules.error} />
      {rows.length === 0 ? (
        <p className="text-sm text-muted-foreground">{ui("No bank rule yet.")}</p>
      ) : (
        <Table
          columns={[
            ui("Rule name"),
            ui("Words on the line"),
            ui("Money"),
            ui("Posts to"),
            ui("Bank account"),
            ui("Priority"),
            "",
          ]}
        >
          {rows.map((r) => (
            <tr key={r.rule_id} className="border-b border-border/60 align-top">
              <td className="py-2 pr-4">{r.name}</td>
              <td className="py-2 pr-4 font-mono text-xs">{r.words}</td>
              <td className="py-2 pr-4">{ui(DIRECTION[r.direction])}</td>
              <td className="py-2 pr-4">{r.account}</td>
              <td className="py-2 pr-4">{r.bank_account ?? ""}</td>
              <td className="py-2 pr-4 tabular-nums">{r.priority}</td>
              <td className="py-2">
                {r.status === "active" ? (
                  <ActionDialog
                    trigger={<ActionButton variant="secondary">{ui("Retire")}</ActionButton>}
                    title="Retire this rule"
                    description="Entries it posted stand. Lines it would have posted wait for a person or another rule."
                    permission="finance.configure"
                    fn="erp_retire_bank_rule"
                    fields={[
                      {
                        kind: "text",
                        name: "p_reason",
                        label: "Why it is retired",
                        required: true,
                        placeholder: "The bank stopped charging this fee",
                        hint: "Kept with the rule.",
                      },
                    ]}
                    prefill={{ p_rule_id: r.rule_id }}
                    context={r.name}
                    invalidates={reads}
                    submitLabel="Retire"
                  />
                ) : (
                  <span className="text-xs text-muted-foreground">{r.retired_reason}</span>
                )}
              </td>
            </tr>
          ))}
        </Table>
      )}
    </section>
  );
}
