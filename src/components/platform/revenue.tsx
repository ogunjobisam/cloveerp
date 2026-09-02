import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { TrendingUp } from "lucide-react";
import { useState } from "react";

import { Pill, Table } from "../erp/panel";
import { TOUCH } from "../erp/page";
import { callErp } from "../../lib/erp";
import type { PlatformRole } from "../../lib/platform";
import { Card, Fail, INPUT } from "./kit";

/**
 * Revenue and renewals. Specification v1.5 §17.10.
 *
 * The reporting the platform owner needs, read from the contract register and
 * nothing else: ARR and MRR, contracts in force, value by plan and by feature,
 * gross margin per organisation from the cost model behind each quote, renewal
 * rate, churn, revenue at risk within the next notice windows, and the invoice
 * position. Renewals are proposed by a sweep at the lead time and decided here:
 * a renewal is accepted by signing, or declined with a note, and either way the
 * contract's own record says what happened.
 */

const BUTTON = `${TOUCH} inline-flex items-center rounded-md bg-primary px-3 text-sm font-semibold text-primary-foreground disabled:opacity-60`;
const SECONDARY = `${TOUCH} inline-flex items-center rounded-md border border-input px-3 text-xs font-medium disabled:opacity-60`;

type Renewal = {
  id: string;
  tenant_code: string;
  term_start: string;
  term_end: string;
  uplift_pct: number;
  previous_annual_value_minor: number;
  proposed_annual_value_minor: number;
  currency: string;
  notice_deadline: string | null;
  status: string;
  quote_document_id: string | null;
};

type Revenue = {
  arr_minor: number;
  mrr_minor: number;
  contracts_in_force: number;
  average_contract_value_minor: number;
  by_plan: { plan_code: string; contracts: number; arr_minor: number }[];
  by_capability: { capability_code: string; contracts: number }[];
  gross_margin: {
    tenant_code: string;
    annual_value_minor: number;
    currency: string;
    cost_minor: number | null;
    margin_minor: number | null;
    margin_pct: number | null;
  }[];
  renewals_last_12_months: {
    accepted: number;
    declined: number;
    lapsed: number;
    renewal_rate_pct: number | null;
  };
  churn: { contracts_ended_last_12_months: number; arr_lost_minor: number };
  revenue_at_risk: {
    tenant_code: string;
    annual_value_minor: number;
    notice_deadline: string;
    renewal_status: string | null;
  }[];
  revenue_at_risk_minor: number;
  invoices: {
    scheduled_minor: number;
    issued_minor: number;
    paid_minor: number;
    overage_issued_minor: number;
  };
  renewals: Renewal[];
};

function money(minor: number | null | undefined, currency?: string) {
  if (minor == null) return "—";
  return `${(minor / 100).toLocaleString(undefined, { maximumFractionDigits: 0 })}${currency ? ` ${currency}` : ""}`;
}

function day(value: string | null | undefined) {
  return value ? new Date(value).toLocaleDateString() : "—";
}

function renewalTone(status: string): "ok" | "warn" | "bad" | "muted" {
  if (status === "accepted") return "ok";
  if (status === "proposed" || status === "quoted") return "warn";
  if (status === "declined" || status === "lapsed") return "bad";
  return "muted";
}

function Figure({ label, value, hint }: { label: string; value: string; hint?: string }) {
  return (
    <div className="rounded-lg border border-border/60 p-3">
      <div className="text-xs text-muted-foreground">{label}</div>
      <div className="mt-1 text-lg font-semibold tabular-nums">{value}</div>
      {hint ? <div className="mt-0.5 text-xs text-muted-foreground">{hint}</div> : null}
    </div>
  );
}

function useDoor(fn: string, invalidates: string[]) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (args: Record<string, unknown> = {}) => callErp<unknown>(fn, args),
    onSuccess: () => {
      for (const k of invalidates) void queryClient.invalidateQueries({ queryKey: [k] });
    },
  });
}

const INVALIDATES = ["erp_platform_revenue", "erp_platform_contracts", "erp_platform_contract"];

function RenewalRow({ r, mayWrite }: { r: Renewal; mayWrite: boolean }) {
  const [open, setOpen] = useState<"sign" | "decline" | null>(null);
  const [customer, setCustomer] = useState("");
  const [platform, setPlatform] = useState("");
  const [meaning, setMeaning] = useState("Agreement to the renewal quote and the terms it names");
  const [note, setNote] = useState("");
  const renew = useDoor("erp_platform_renew_contract", INVALIDATES);
  const decline = useDoor("erp_platform_decline_renewal", INVALIDATES);
  const decidable = r.status === "proposed" || r.status === "quoted";

  return (
    <>
      <tr className="border-b border-border/50 align-top last:border-0">
        <td className="py-2 pr-4 font-mono text-xs">{r.tenant_code}</td>
        <td className="py-2 pr-4 text-xs">
          {day(r.term_start)} → {day(r.term_end)}
        </td>
        <td className="py-2 pr-4 text-sm tabular-nums">
          {money(r.previous_annual_value_minor, r.currency)}
        </td>
        <td className="py-2 pr-4 text-sm tabular-nums">
          {money(r.proposed_annual_value_minor, r.currency)}
          <span className="ml-1 text-xs text-muted-foreground">+{r.uplift_pct}%</span>
        </td>
        <td className="py-2 pr-4 text-xs text-muted-foreground">{day(r.notice_deadline)}</td>
        <td className="py-2 pr-4">
          <Pill tone={renewalTone(r.status)}>{r.status}</Pill>
          {r.status === "proposed" ? (
            <div className="mt-1 text-xs text-muted-foreground">
              not yet quoted; the platform organisation raises it under Quotes
            </div>
          ) : null}
        </td>
        <td className="py-2">
          {mayWrite && decidable ? (
            <div className="flex flex-wrap gap-1">
              {r.status === "quoted" ? (
                <button type="button" className={SECONDARY} onClick={() => setOpen("sign")}>
                  Renew
                </button>
              ) : null}
              <button type="button" className={SECONDARY} onClick={() => setOpen("decline")}>
                Decline
              </button>
            </div>
          ) : null}
        </td>
      </tr>
      {open ? (
        <tr className="border-b border-border/50 last:border-0">
          <td colSpan={7} className="pb-3">
            {open === "sign" ? (
              <form
                className="flex flex-col gap-2 rounded-lg border border-border/60 p-3"
                onSubmit={(e) => {
                  e.preventDefault();
                  if (customer && platform && meaning) {
                    renew.mutate(
                      {
                        p_renewal_id: r.id,
                        p_customer_signer: customer,
                        p_platform_signer: platform,
                        p_signature_meaning: meaning,
                      },
                      { onSuccess: () => setOpen(null) },
                    );
                  }
                }}
              >
                <p className="text-xs text-muted-foreground">
                  Renewing signs an amendment for the new term at the accepted quote's value,
                  extends the contract, provisions the subscription and schedules the next term's
                  invoices. The renewal quote must be accepted first.
                </p>
                <div className="grid gap-2 sm:grid-cols-3">
                  <label className="block text-xs font-medium">
                    Customer signer
                    <input
                      className={INPUT}
                      value={customer}
                      onChange={(e) => setCustomer(e.target.value)}
                    />
                  </label>
                  <label className="block text-xs font-medium">
                    Platform signer
                    <input
                      className={INPUT}
                      value={platform}
                      onChange={(e) => setPlatform(e.target.value)}
                    />
                  </label>
                  <label className="block text-xs font-medium">
                    Meaning of the signature
                    <input
                      className={INPUT}
                      value={meaning}
                      onChange={(e) => setMeaning(e.target.value)}
                    />
                  </label>
                </div>
                {renew.error ? <Fail error={renew.error} /> : null}
                <div className="flex gap-2">
                  <button type="submit" className={BUTTON} disabled={renew.isPending}>
                    {renew.isPending ? "Signing…" : "Sign the renewal"}
                  </button>
                  <button type="button" className={SECONDARY} onClick={() => setOpen(null)}>
                    Cancel
                  </button>
                </div>
              </form>
            ) : (
              <form
                className="flex flex-col gap-2 rounded-lg border border-border/60 p-3"
                onSubmit={(e) => {
                  e.preventDefault();
                  if (note) {
                    decline.mutate(
                      { p_renewal_id: r.id, p_note: note },
                      { onSuccess: () => setOpen(null) },
                    );
                  }
                }}
              >
                <p className="text-xs text-muted-foreground">
                  Declining records the non-renewal. The contract runs to the end of its term and
                  then into grace, never straight to restriction.
                </p>
                <label className="block text-xs font-medium">
                  Note
                  <input
                    className={INPUT}
                    value={note}
                    onChange={(e) => setNote(e.target.value)}
                    placeholder="Who said so, and why"
                  />
                </label>
                {decline.error ? <Fail error={decline.error} /> : null}
                <div className="flex gap-2">
                  <button type="submit" className={BUTTON} disabled={decline.isPending}>
                    {decline.isPending ? "Recording…" : "Record the non-renewal"}
                  </button>
                  <button type="button" className={SECONDARY} onClick={() => setOpen(null)}>
                    Cancel
                  </button>
                </div>
              </form>
            )}
          </td>
        </tr>
      ) : null}
    </>
  );
}

export function Revenue({ role }: { role: PlatformRole }) {
  const mayWrite = role === "owner" || role === "operator";
  const q = useQuery({
    queryKey: ["erp_platform_revenue"],
    queryFn: () => callErp<Revenue>("erp_platform_revenue"),
    refetchInterval: 60_000,
  });
  const propose = useDoor("erp_platform_propose_renewals", INVALIDATES);
  const setIndex = useDoor("erp_platform_set_index_rate", INVALIDATES);
  const [indexCode, setIndexCode] = useState("CPI");
  const [indexPeriod, setIndexPeriod] = useState("");
  const [indexRate, setIndexRate] = useState("");
  const [indexSource, setIndexSource] = useState("");

  if (q.isPending) return <p className="text-sm text-muted-foreground">Loading…</p>;
  if (q.error || !q.data) return q.error ? <Fail error={q.error} /> : null;
  const d = q.data;
  const currency = d.gross_margin[0]?.currency;

  return (
    <div className="flex flex-col gap-6">
      <Card
        title="Revenue"
        icon={<TrendingUp className="size-4 text-primary" />}
        description="Read from the contract register. Annual recurring revenue is the sum of every contract in force; nothing here is entered by hand."
      >
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <Figure label="Annual recurring revenue" value={money(d.arr_minor, currency)} />
          <Figure label="Monthly recurring revenue" value={money(d.mrr_minor, currency)} />
          <Figure label="Contracts in force" value={String(d.contracts_in_force)} />
          <Figure
            label="Average contract value"
            value={money(d.average_contract_value_minor, currency)}
          />
          <Figure
            label="Renewal rate, last 12 months"
            value={
              d.renewals_last_12_months.renewal_rate_pct == null
                ? "—"
                : `${d.renewals_last_12_months.renewal_rate_pct}%`
            }
            hint={`${d.renewals_last_12_months.accepted} accepted, ${d.renewals_last_12_months.declined} declined, ${d.renewals_last_12_months.lapsed} lapsed`}
          />
          <Figure
            label="Churn, last 12 months"
            value={money(d.churn.arr_lost_minor, currency)}
            hint={`${d.churn.contracts_ended_last_12_months} contract(s) ended`}
          />
          <Figure
            label="Revenue at risk"
            value={money(d.revenue_at_risk_minor, currency)}
            hint="within the next two notice windows, no renewal accepted"
          />
          <Figure
            label="Overage invoiced"
            value={money(d.invoices.overage_issued_minor, currency)}
            hint={`scheduled ${money(d.invoices.scheduled_minor)} · issued ${money(d.invoices.issued_minor)} · paid ${money(d.invoices.paid_minor)}`}
          />
        </div>

        <div className="mt-5 grid gap-5 lg:grid-cols-2">
          <div>
            <h3 className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
              By plan
            </h3>
            {d.by_plan.length === 0 ? (
              <p className="mt-1 text-sm text-muted-foreground">No contract is in force.</p>
            ) : (
              <Table columns={["Plan", "Contracts", "ARR"]}>
                {d.by_plan.map((p) => (
                  <tr key={p.plan_code} className="border-b border-border/50 last:border-0">
                    <td className="py-1.5 pr-4 font-mono text-xs">{p.plan_code}</td>
                    <td className="py-1.5 pr-4 text-sm tabular-nums">{p.contracts}</td>
                    <td className="py-1.5 text-sm tabular-nums">{money(p.arr_minor, currency)}</td>
                  </tr>
                ))}
              </Table>
            )}
          </div>
          <div>
            <h3 className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
              By feature
            </h3>
            {d.by_capability.length === 0 ? (
              <p className="mt-1 text-sm text-muted-foreground">
                No contract names a feature beyond its plan.
              </p>
            ) : (
              <Table columns={["Feature", "Contracts"]}>
                {d.by_capability.map((c) => (
                  <tr key={c.capability_code} className="border-b border-border/50 last:border-0">
                    <td className="py-1.5 pr-4 font-mono text-xs">{c.capability_code}</td>
                    <td className="py-1.5 text-sm tabular-nums">{c.contracts}</td>
                  </tr>
                ))}
              </Table>
            )}
          </div>
        </div>
      </Card>

      <Card
        title="Gross margin by organisation"
        description="Each contract's annual value against the cost model behind the quote it was made from. The same figure the builder showed while quoting (D36)."
      >
        {d.gross_margin.length === 0 ? (
          <p className="text-sm text-muted-foreground">No contract is in force.</p>
        ) : (
          <Table columns={["Organisation", "Annual value", "Cost", "Margin", "Margin %"]}>
            {d.gross_margin.map((g) => (
              <tr key={g.tenant_code} className="border-b border-border/50 last:border-0">
                <td className="py-1.5 pr-4 font-mono text-xs">{g.tenant_code}</td>
                <td className="py-1.5 pr-4 text-sm tabular-nums">
                  {money(g.annual_value_minor, g.currency)}
                </td>
                <td className="py-1.5 pr-4 text-sm tabular-nums">{money(g.cost_minor)}</td>
                <td className="py-1.5 pr-4 text-sm tabular-nums">{money(g.margin_minor)}</td>
                <td className="py-1.5">
                  <Pill
                    tone={
                      g.margin_pct == null
                        ? "muted"
                        : g.margin_pct < 0
                          ? "bad"
                          : g.margin_pct < 20
                            ? "warn"
                            : "ok"
                    }
                  >
                    {g.margin_pct == null ? "—" : `${g.margin_pct}%`}
                  </Pill>
                </td>
              </tr>
            ))}
          </Table>
        )}
      </Card>

      <Card
        title="Renewals"
        description="Proposed by the sweep at each contract's lead time with its uplift rule applied. The platform organisation raises the quote under Quotes; the decision is recorded here."
        action={
          mayWrite ? (
            <button
              type="button"
              className={SECONDARY}
              disabled={propose.isPending}
              onClick={() => propose.mutate({})}
            >
              {propose.isPending ? "Sweeping…" : "Run the renewal sweep now"}
            </button>
          ) : null
        }
      >
        {propose.error ? <Fail error={propose.error} /> : null}
        {propose.isSuccess ? (
          <p className="mb-2 text-xs text-muted-foreground">
            {String(propose.data)} renewal(s) proposed.
          </p>
        ) : null}
        {d.renewals.length === 0 ? (
          <p className="text-sm text-muted-foreground">No renewal has been proposed.</p>
        ) : (
          <Table
            columns={["Organisation", "New term", "Previous", "Proposed", "Notice by", "State", ""]}
          >
            {d.renewals.map((r) => (
              <RenewalRow key={r.id} r={r} mayWrite={mayWrite} />
            ))}
          </Table>
        )}
        {d.revenue_at_risk.length > 0 ? (
          <div className="mt-4">
            <h3 className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
              At risk
            </h3>
            <Table columns={["Organisation", "Annual value", "Notice deadline", "Renewal"]}>
              {d.revenue_at_risk.map((x) => (
                <tr
                  key={`${x.tenant_code}-${x.notice_deadline}`}
                  className="border-b border-border/50 last:border-0"
                >
                  <td className="py-1.5 pr-4 font-mono text-xs">{x.tenant_code}</td>
                  <td className="py-1.5 pr-4 text-sm tabular-nums">
                    {money(x.annual_value_minor, currency)}
                  </td>
                  <td className="py-1.5 pr-4 text-xs">{day(x.notice_deadline)}</td>
                  <td className="py-1.5">
                    <Pill tone={x.renewal_status ? renewalTone(x.renewal_status) : "bad"}>
                      {x.renewal_status ?? "not proposed"}
                    </Pill>
                  </td>
                </tr>
              ))}
            </Table>
          </div>
        ) : null}
      </Card>

      {mayWrite ? (
        <Card
          title="Index rates"
          description="An index-linked uplift rule reads its rate from here. A renewal whose index has no published rate for its period is a finding, not a guess."
        >
          <form
            className="flex flex-col gap-2"
            onSubmit={(e) => {
              e.preventDefault();
              if (indexCode && indexPeriod && indexRate) {
                setIndex.mutate({
                  p_index_code: indexCode.toUpperCase(),
                  p_period: indexPeriod,
                  p_rate_pct: Number(indexRate),
                  p_source: indexSource || null,
                });
              }
            }}
          >
            <div className="grid gap-2 sm:grid-cols-4">
              <label className="block text-xs font-medium">
                Index
                <input
                  className={INPUT}
                  value={indexCode}
                  onChange={(e) => setIndexCode(e.target.value)}
                />
              </label>
              <label className="block text-xs font-medium">
                Period
                <input
                  type="date"
                  className={INPUT}
                  value={indexPeriod}
                  onChange={(e) => setIndexPeriod(e.target.value)}
                />
              </label>
              <label className="block text-xs font-medium">
                Rate %
                <input
                  type="number"
                  step="0.1"
                  className={INPUT}
                  value={indexRate}
                  onChange={(e) => setIndexRate(e.target.value)}
                />
              </label>
              <label className="block text-xs font-medium">
                Source
                <input
                  className={INPUT}
                  value={indexSource}
                  onChange={(e) => setIndexSource(e.target.value)}
                  placeholder="ONS, series D7G7"
                />
              </label>
            </div>
            {setIndex.error ? <Fail error={setIndex.error} /> : null}
            {setIndex.isSuccess ? <p className="text-xs text-muted-foreground">Recorded.</p> : null}
            <button type="submit" className={`${BUTTON} self-start`} disabled={setIndex.isPending}>
              {setIndex.isPending ? "Recording…" : "Publish the rate"}
            </button>
          </form>
        </Card>
      ) : null}
    </div>
  );
}
