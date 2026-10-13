import { createFileRoute } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";

import { ActionButton, ActionDialog, ErrorNote } from "../../components/erp/action";
import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { Pill, Table } from "../../components/erp/panel";
import { callErp } from "../../lib/erp";
import { useT } from "../../lib/i18n";

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
    </div>
  );
}
