import { createFileRoute } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useState } from "react";

import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { Pill, Table } from "../../components/erp/panel";
import { callErp } from "../../lib/erp";
import { useT } from "../../lib/i18n";

export const Route = createFileRoute("/finance/statements")({
  head: () => ({
    meta: [
      { title: "Profit and balance sheet — Clove ERP" },
      {
        name: "description",
        content:
          "A profit and loss for any period and a balance sheet as at any date, built from what purchases, stock movements and invoices actually posted.",
      },
      { property: "og:title", content: "Profit and balance sheet — Clove ERP" },
      {
        property: "og:description",
        content:
          "Income, cost of sales, expenses and the result, with assets, liabilities and equity that balance — filtered by period and cost centre.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <Statements />
    </Gate>
  ),
});

type Line = {
  account: string;
  name: string;
  account_type: string;
  currency: string | null;
  amount_minor: number;
};

type ProfitAndLoss = {
  from: string;
  to: string;
  lines: Line[];
  income_minor: number;
  expense_minor: number;
  result_minor: number;
};

type BalanceSheet = {
  as_at: string;
  lines: Line[];
  assets_minor: number;
  liabilities_minor: number;
  equity_minor: number;
  result_minor: number;
  balances: boolean;
  difference_minor: number;
};

type CostCentre = { code: string; name: string; status: string };

type TrialLine = {
  account: string;
  name: string;
  account_type: string;
  debit_minor: number;
  credit_minor: number;
  balance_minor: number;
};

const money = (minor: number | null | undefined) =>
  minor === null || minor === undefined
    ? "—"
    : new Intl.NumberFormat(undefined, {
        minimumFractionDigits: 2,
        maximumFractionDigits: 2,
      }).format(minor / 100);

const startOfYear = () => `${new Date().getFullYear()}-01-01`;
const today = () => new Date().toISOString().slice(0, 10);

function Section({
  title,
  lines,
  total,
  totalLabel,
}: {
  title: string;
  lines: Line[];
  total: number;
  totalLabel: string;
}) {
  const { ui } = useT();
  if (lines.length === 0) return null;
  return (
    <div className="mb-6">
      <h3 className="mb-2 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
        {title}
      </h3>
      <Table columns={[ui("Account"), ui("Name"), ui("Amount")]}>
        {lines.map((l) => (
          <tr key={l.account} className="border-b border-border/60 last:border-0">
            <td className="whitespace-nowrap py-1.5 pr-4 font-mono text-xs">{l.account}</td>
            <td className="max-w-[22rem] truncate py-1.5 pr-4">{l.name}</td>
            <td className="whitespace-nowrap py-1.5 text-right tabular-nums">
              {money(l.amount_minor)}
            </td>
          </tr>
        ))}
        <tr>
          <td className="py-2 pr-4 text-sm font-semibold" colSpan={2}>
            {totalLabel}
          </td>
          <td className="py-2 text-right text-sm font-semibold tabular-nums">{money(total)}</td>
        </tr>
      </Table>
    </div>
  );
}

/**
 * The statements, from the postings themselves.
 *
 * Every purchase, stock movement and sales invoice already wrote a journal.
 * What was missing was the two readings anyone actually asks for: what the
 * period made, and what the company is worth on a date. Both are computed
 * here from posted lines in base currency, and the balance sheet says out
 * loud whether it balances rather than leaving that to be discovered.
 */
function Statements() {
  const { t, ui } = useT();
  const [from, setFrom] = useState(startOfYear());
  const [to, setTo] = useState(today());
  const [costCentre, setCostCentre] = useState("");
  const [detail, setDetail] = useState(false);

  const cc = costCentre === "" ? null : costCentre;

  const centres = useQuery({
    queryKey: ["erp_cost_centres"],
    queryFn: () => callErp<CostCentre[]>("erp_cost_centres"),
  });

  const pl = useQuery({
    queryKey: ["erp_profit_and_loss", from, to, cc],
    queryFn: () =>
      callErp<ProfitAndLoss>("erp_profit_and_loss", {
        p_from: from,
        p_to: to,
        p_ledger: "GL",
        p_cost_centre: cc,
      }),
  });

  const bs = useQuery({
    queryKey: ["erp_balance_sheet", to, cc],
    queryFn: () =>
      callErp<BalanceSheet>("erp_balance_sheet", {
        p_as_at: to,
        p_ledger: "GL",
        p_cost_centre: cc,
      }),
  });

  const trial = useQuery({
    enabled: detail,
    queryKey: ["erp_trial_balance", from, to, cc],
    queryFn: () =>
      callErp<TrialLine[]>("erp_trial_balance", {
        p_from: from,
        p_to: to,
        p_ledger: "GL",
        p_cost_centre: cc,
      }),
  });

  const of = (type: string) => (pl.data?.lines ?? []).filter((l) => l.account_type === type);
  const bsOf = (type: string) => (bs.data?.lines ?? []).filter((l) => l.account_type === type);

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={t("nav.finance_statements", "Profit and balance sheet")}>
        Both statements are read from the journals that purchases, stock movements, deliveries and
        invoices have already posted. Narrow them to a period or a single cost centre; the balance
        sheet carries the result to date so it balances without a year-end entry.
      </PageHeader>

      <div className="flex flex-wrap items-end gap-3 rounded-lg border border-border bg-card p-4">
        <label className="flex flex-col gap-1 text-xs font-medium text-muted-foreground">
          {ui("From")}
          <input
            type="date"
            value={from}
            onChange={(e) => setFrom(e.target.value)}
            className="rounded-md border border-input bg-background px-2 py-1.5 text-sm text-foreground"
          />
        </label>
        <label className="flex flex-col gap-1 text-xs font-medium text-muted-foreground">
          {ui("To / as at")}
          <input
            type="date"
            value={to}
            onChange={(e) => setTo(e.target.value)}
            className="rounded-md border border-input bg-background px-2 py-1.5 text-sm text-foreground"
          />
        </label>
        <label className="flex flex-col gap-1 text-xs font-medium text-muted-foreground">
          {ui("Cost centre")}
          <select
            value={costCentre}
            onChange={(e) => setCostCentre(e.target.value)}
            className="rounded-md border border-input bg-background px-2 py-1.5 text-sm text-foreground"
          >
            <option value="">{ui("All cost centres")}</option>
            {(centres.data ?? [])
              .filter((c) => c.status === "active")
              .map((c) => (
                <option key={c.code} value={c.code}>
                  {c.code} — {c.name}
                </option>
              ))}
          </select>
        </label>
        <button
          type="button"
          onClick={() => setDetail((d) => !d)}
          className="rounded-md border border-input px-3 py-1.5 text-sm font-medium text-foreground hover:bg-muted"
        >
          {detail ? ui("Hide account detail") : ui("Show account detail")}
        </button>
      </div>

      <section className="rounded-lg border border-border bg-card p-5">
        <header className="mb-4 flex flex-wrap items-baseline justify-between gap-2">
          <h2 className="text-base font-semibold">{ui("Profit and loss")}</h2>
          <p className="text-xs text-muted-foreground">
            {pl.data ? `${pl.data.from} → ${pl.data.to}` : ""}
          </p>
        </header>

        {pl.isLoading ? (
          <p className="text-sm text-muted-foreground">{ui("Reading the journals…")}</p>
        ) : (pl.data?.lines ?? []).length === 0 ? (
          <p className="text-sm text-muted-foreground">
            {ui(
              "Nothing posted to income or expense in this period. Post a sales invoice or a supplier bill and it appears here.",
            )}
          </p>
        ) : (
          <>
            <Section
              title={ui("Income")}
              lines={of("income")}
              total={pl.data?.income_minor ?? 0}
              totalLabel={ui("Total income")}
            />
            <Section
              title={ui("Cost of sales and expenses")}
              lines={of("expense")}
              total={pl.data?.expense_minor ?? 0}
              totalLabel={ui("Total expense")}
            />
            <div className="flex items-baseline justify-between border-t border-border pt-3">
              <span className="text-sm font-semibold">{ui("Result for the period")}</span>
              <span
                className={`text-lg font-semibold tabular-nums ${
                  (pl.data?.result_minor ?? 0) < 0 ? "text-destructive" : "text-emerald-600"
                }`}
              >
                {money(pl.data?.result_minor)}
              </span>
            </div>
          </>
        )}
      </section>

      <section className="rounded-lg border border-border bg-card p-5">
        <header className="mb-4 flex flex-wrap items-baseline justify-between gap-2">
          <h2 className="text-base font-semibold">{ui("Balance sheet")}</h2>
          <div className="flex items-center gap-2">
            <p className="text-xs text-muted-foreground">
              {ui("As at")} {bs.data?.as_at ?? to}
            </p>
            {bs.data ? (
              <Pill tone={bs.data.balances ? "ok" : "bad"}>
                {bs.data.balances
                  ? ui("Balances")
                  : `${ui("Out by")} ${money(bs.data.difference_minor)}`}
              </Pill>
            ) : null}
          </div>
        </header>

        {bs.isLoading ? (
          <p className="text-sm text-muted-foreground">{ui("Reading the journals…")}</p>
        ) : (bs.data?.lines ?? []).length === 0 ? (
          <p className="text-sm text-muted-foreground">
            {ui("Nothing posted to the balance sheet yet.")}
          </p>
        ) : (
          <>
            <Section
              title={ui("Assets")}
              lines={bsOf("asset")}
              total={bs.data?.assets_minor ?? 0}
              totalLabel={ui("Total assets")}
            />
            <Section
              title={ui("Liabilities")}
              lines={bsOf("liability")}
              total={bs.data?.liabilities_minor ?? 0}
              totalLabel={ui("Total liabilities")}
            />
            <Section
              title={ui("Equity")}
              lines={bsOf("equity")}
              total={bs.data?.equity_minor ?? 0}
              totalLabel={ui("Total equity")}
            />
            <div className="flex items-baseline justify-between border-t border-border pt-3">
              <span className="text-sm font-semibold">{ui("Result to date")}</span>
              <span className="text-lg font-semibold tabular-nums">
                {money(bs.data?.result_minor)}
              </span>
            </div>
          </>
        )}
      </section>

      {detail ? (
        <section className="rounded-lg border border-border bg-card p-5">
          <h2 className="mb-3 text-base font-semibold">{ui("Account detail")}</h2>
          {trial.isLoading ? (
            <p className="text-sm text-muted-foreground">{ui("Reading the journals…")}</p>
          ) : (trial.data ?? []).length === 0 ? (
            <p className="text-sm text-muted-foreground">
              {ui("No account moved on these filters.")}
            </p>
          ) : (
            <Table
              columns={[ui("Account"), ui("Name"), ui("Type"), ui("Debit"), ui("Credit"), ui("Balance")]}
            >
              {(trial.data ?? []).map((r) => (
                <tr key={r.account} className="border-b border-border/60 last:border-0">
                  <td className="whitespace-nowrap py-1.5 pr-4 font-mono text-xs">{r.account}</td>
                  <td className="max-w-[20rem] truncate py-1.5 pr-4">{r.name}</td>
                  <td className="whitespace-nowrap py-1.5 pr-4 text-xs text-muted-foreground">
                    {r.account_type}
                  </td>
                  <td className="whitespace-nowrap py-1.5 pr-4 text-right tabular-nums">
                    {money(r.debit_minor)}
                  </td>
                  <td className="whitespace-nowrap py-1.5 pr-4 text-right tabular-nums">
                    {money(r.credit_minor)}
                  </td>
                  <td className="whitespace-nowrap py-1.5 text-right tabular-nums">
                    {money(r.balance_minor)}
                  </td>
                </tr>
              ))}
            </Table>
          )}
        </section>
      ) : null}
    </div>
  );
}
