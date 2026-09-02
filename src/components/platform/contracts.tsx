import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { FileSignature } from "lucide-react";
import { Fragment, useState, type ReactNode } from "react";

import { Pill, Table } from "../erp/panel";
import { TOUCH } from "../erp/page";
import { callErp } from "../../lib/erp";
import type { PlatformRole } from "../../lib/platform";
import { Card, Fail, INPUT } from "./kit";

/**
 * Contracts. Specification v1.5 §17.5, §17.8 and §17.9.
 *
 * The platform's own organisation is designated here (§17.5). A contract is
 * created from an accepted quote and nothing else; signing it provisions the
 * subscription directly (§17.9, D35); every change after that is an
 * amendment with its own signature. Key dates are structured fields with a
 * derivation beside them, and each raises a notification on its lead time.
 */

const BUTTON = `${TOUCH} inline-flex items-center rounded-md bg-primary px-3 text-sm font-semibold text-primary-foreground disabled:opacity-60`;
const SECONDARY = `${TOUCH} inline-flex items-center rounded-md border border-input px-3 text-xs font-medium`;

type CommercialState = {
  platform_organisation: {
    tenant_code: string;
    designated_at: string;
    designated_by: string;
    reason: string | null;
    status: string | null;
  } | null;
  candidates: { code: string; name: string }[];
  price_items: number;
  findings: { finding: string; reference: string; detail: string }[];
};

type ContractRow = {
  id: string;
  tenant_code: string;
  customer_legal_name: string;
  status: string;
  plan_code: string;
  currency: string;
  annual_value_minor: number;
  term_kind: string;
  commencement: string;
  current_term_end: string;
  renewal_kind: string;
  notice_days: number;
  notice_deadline: string | null;
  quote_number: string;
  quote_version: number;
  signed_at: string | null;
  amendments: number;
  unsigned_amendments: number;
};

type ContractsReport = {
  contracts: ContractRow[];
  accepted_quotes: {
    document_id: string;
    document_number: string;
    version: number;
    customer_tenant_code: string | null;
    party_name: string | null;
    currency: string;
    term_kind: string;
  }[];
  organisations: { code: string; name: string }[];
  findings: { finding: string; reference: string; detail: string }[];
};

type Position = {
  id: string;
  tenant_code: string;
  status: string;
  customer_legal_name: string;
  platform_legal_name: string;
  quote_number: string;
  quote_version: number;
  plan_code: string;
  plan_name: string | null;
  support_severity_code: string | null;
  term_kind: string;
  currency: string;
  annual_value_minor: number;
  billing_frequency: string;
  commencement: string;
  initial_term_months: number;
  current_term_start: string;
  current_term_end: string;
  renewal_kind: string;
  notice_days: number;
  governing_law: string;
  uplift_rule: Record<string, unknown>;
  termination_terms: Record<string, unknown>;
  review_date: string | null;
  lead_days: number;
  signed_at: string | null;
  key_dates: { kind: string; due_on: string; days_left: number }[];
  entitlements: {
    entitlement_code: string;
    title: string | null;
    unit: string | null;
    limit_value: number | null;
    effective_from: string;
    effective_to: string | null;
    in_force: boolean;
  }[];
  capabilities: {
    capability_code: string;
    effective_from: string;
    effective_to: string | null;
    in_force: boolean;
  }[];
  documents: {
    id: string;
    kind: string;
    version: number;
    title: string;
    checksum: string;
    signed_at: string | null;
    signed_by_customer: string | null;
    signed_by_platform: string | null;
    signature_meaning: string | null;
    superseded_by: string | null;
    byte_size: number;
  }[];
  amendments: {
    id: string;
    seq: number;
    title: string;
    effective_from: string;
    changes: Record<string, unknown>;
    rationale: string | null;
    signed_at: string | null;
    provisioned_at: string | null;
  }[];
  subscription: {
    plan_code: string;
    term_start: string;
    term_end: string | null;
    renews: boolean;
    status: string;
  } | null;
  notices: { kind: string; due_on: string; raised_at: string }[];
};

function money(minor: number | null | undefined, currency?: string) {
  if (minor == null) return "—";
  return `${(minor / 100).toLocaleString(undefined, { maximumFractionDigits: 0 })}${currency ? ` ${currency}` : ""}`;
}

function day(value: string | null | undefined) {
  return value ? new Date(value).toLocaleDateString() : "—";
}

function Form({
  label,
  fn,
  invalidates,
  children,
  build,
  onDone,
}: {
  label: string;
  fn: string;
  invalidates: string[];
  children: ReactNode;
  build: () => Record<string, unknown> | null;
  onDone?: (result: unknown) => void;
}) {
  const queryClient = useQueryClient();
  const m = useMutation({
    mutationFn: (args: Record<string, unknown>) => callErp(fn, args),
    onSuccess: (result) => {
      for (const k of invalidates) void queryClient.invalidateQueries({ queryKey: [k] });
      onDone?.(result);
    },
  });
  return (
    <form
      className="flex flex-col gap-2 rounded-lg border border-border/60 p-3"
      onSubmit={(e) => {
        e.preventDefault();
        const args = build();
        if (args) m.mutate(args);
      }}
    >
      {children}
      {m.error ? <Fail error={m.error} /> : null}
      {m.isSuccess ? <p className="text-xs text-muted-foreground">Done.</p> : null}
      <button type="submit" className={`${BUTTON} self-start`} disabled={m.isPending}>
        {m.isPending ? "Working…" : label}
      </button>
    </form>
  );
}

function Signature({
  onChange,
}: {
  onChange: (v: { customer: string; platform: string; meaning: string }) => void;
}) {
  const [customer, setCustomer] = useState("");
  const [platform, setPlatform] = useState("");
  const [meaning, setMeaning] = useState("");
  const emit = (next: { customer: string; platform: string; meaning: string }) => onChange(next);
  return (
    <div className="grid gap-2 sm:grid-cols-3">
      <label className="block text-xs font-medium">
        Customer signer
        <input
          className={INPUT}
          value={customer}
          onChange={(e) => {
            setCustomer(e.target.value);
            emit({ customer: e.target.value, platform, meaning });
          }}
        />
      </label>
      <label className="block text-xs font-medium">
        Platform signer
        <input
          className={INPUT}
          value={platform}
          onChange={(e) => {
            setPlatform(e.target.value);
            emit({ customer, platform: e.target.value, meaning });
          }}
        />
      </label>
      <label className="block text-xs font-medium">
        Meaning of the signature
        <input
          className={INPUT}
          value={meaning}
          placeholder="Agreement to the order form and the terms it names"
          onChange={(e) => {
            setMeaning(e.target.value);
            emit({ customer, platform, meaning: e.target.value });
          }}
        />
      </label>
    </div>
  );
}

export function Contracts({ role }: { role: PlatformRole }) {
  const mayWrite = role === "owner" || role === "operator";
  const [selected, setSelected] = useState<string | null>(null);

  const state = useQuery({
    queryKey: ["erp_platform_commercial_state"],
    queryFn: () => callErp<CommercialState>("erp_platform_commercial_state"),
  });
  const list = useQuery({
    queryKey: ["erp_platform_contracts"],
    queryFn: () => callErp<ContractsReport>("erp_platform_contracts"),
    refetchInterval: 60_000,
  });

  const [designate, setDesignate] = useState("");
  const [designateReason, setDesignateReason] = useState("");
  const [quote, setQuote] = useState("");
  const [customer, setCustomer] = useState("");
  const [customerName, setCustomerName] = useState("");
  const [platformName, setPlatformName] = useState("");
  const [commencement, setCommencement] = useState("");
  const [months, setMonths] = useState("12");
  const [renewal, setRenewal] = useState("automatic");
  const [notice, setNotice] = useState("90");
  const [law, setLaw] = useState("England and Wales");
  const [frequency, setFrequency] = useState("annual");
  const [upliftKind, setUpliftKind] = useState("fixed_pct");
  const [upliftPct, setUpliftPct] = useState("5");
  const [upliftIndex, setUpliftIndex] = useState("");
  const [upliftCap, setUpliftCap] = useState("");
  const [rights, setRights] = useState("");
  const [exitDays, setExitDays] = useState("90");
  const [dataReturn, setDataReturn] = useState("full export in open formats before deletion");
  const [review, setReview] = useState("");
  const [lead, setLead] = useState("30");

  const uplift = () =>
    upliftKind === "none"
      ? { kind: "none" }
      : upliftKind === "fixed_pct"
        ? { kind: "fixed_pct", pct: Number(upliftPct) }
        : upliftKind === "index"
          ? { kind: "index", index_code: upliftIndex }
          : { kind: "capped", index_code: upliftIndex, cap_pct: Number(upliftCap) };

  return (
    <div className="flex flex-col gap-6">
      <Card
        title="The platform's organisation"
        icon={<FileSignature className="size-4 text-primary" />}
        description="The one organisation on this deployment that is the platform itself. Its products are price items, its quotations are commercial quotes, its approval chains route discounts and its output templates render order forms."
      >
        {state.isPending ? (
          <p className="text-sm text-muted-foreground">Loading…</p>
        ) : state.error ? (
          <Fail error={state.error} />
        ) : !state.data ? null : (
          <div className="flex flex-col gap-3">
            {state.data.platform_organisation ? (
              <p className="text-sm">
                <span className="font-mono text-xs">
                  {state.data.platform_organisation.tenant_code}
                </span>{" "}
                <Pill tone={state.data.platform_organisation.status === "active" ? "ok" : "bad"}>
                  {state.data.platform_organisation.status ?? "missing"}
                </Pill>
                <span className="ml-2 text-xs text-muted-foreground">
                  designated {day(state.data.platform_organisation.designated_at)} by{" "}
                  {state.data.platform_organisation.designated_by} · {state.data.price_items} price
                  item(s)
                </span>
              </p>
            ) : (
              <p className="text-sm text-muted-foreground">
                No organisation is designated yet, so nobody has a price book.
              </p>
            )}
            {state.data.findings.length > 0 ? (
              <ul className="flex flex-col gap-1" role="alert">
                {state.data.findings.map((f, i) => (
                  <li key={`${f.finding}-${i}`} className="text-xs text-destructive">
                    <span className="font-medium">{f.finding}</span> · {f.reference}: {f.detail}
                  </li>
                ))}
              </ul>
            ) : null}
            {role === "owner" ? (
              <Form
                label="Designate"
                fn="erp_platform_designate_organisation"
                invalidates={["erp_platform_commercial_state", "erp_platform_contracts"]}
                build={() =>
                  designate ? { p_tenant_code: designate, p_reason: designateReason || null } : null
                }
              >
                <div className="grid gap-2 sm:grid-cols-2">
                  <label className="block text-xs font-medium">
                    Organisation
                    <select
                      className={INPUT}
                      value={designate}
                      onChange={(e) => setDesignate(e.target.value)}
                    >
                      <option value="">Choose…</option>
                      {state.data.candidates.map((c) => (
                        <option key={c.code} value={c.code}>
                          {c.code} — {c.name}
                        </option>
                      ))}
                    </select>
                  </label>
                  <label className="block text-xs font-medium">
                    Reason, if moving it
                    <input
                      className={INPUT}
                      value={designateReason}
                      onChange={(e) => setDesignateReason(e.target.value)}
                    />
                  </label>
                </div>
              </Form>
            ) : null}
          </div>
        )}
      </Card>

      {selected ? (
        <ContractDetail id={selected} mayWrite={mayWrite} onBack={() => setSelected(null)} />
      ) : (
        <Card
          title="Contracts"
          icon={<FileSignature className="size-4 text-primary" />}
          description="Created from an accepted quote and nothing else. Signing provisions the subscription directly; every change after that is an amendment with its own signature."
        >
          {list.isPending ? (
            <p className="text-sm text-muted-foreground">Loading…</p>
          ) : list.error ? (
            <Fail error={list.error} />
          ) : !list.data ? null : (
            <div className="flex flex-col gap-5">
              {list.data.findings.length > 0 ? (
                <ul className="flex flex-col gap-1" role="alert">
                  {list.data.findings.map((f, i) => (
                    <li key={`${f.finding}-${i}`} className="text-xs text-destructive">
                      <span className="font-medium">{f.finding}</span> · {f.reference}: {f.detail}
                    </li>
                  ))}
                </ul>
              ) : null}

              {list.data.contracts.length === 0 ? (
                <p className="text-sm text-muted-foreground">No contract has been created.</p>
              ) : (
                <Table
                  columns={[
                    "Organisation",
                    "Plan",
                    "Annual value",
                    "Term",
                    "Notice deadline",
                    "Amendments",
                    "State",
                  ]}
                >
                  {list.data.contracts.map((c) => (
                    <tr key={c.id} className="border-b border-border/50 align-top last:border-0">
                      <td className="py-2 pr-4">
                        <button
                          type="button"
                          className="text-left text-sm underline underline-offset-2"
                          onClick={() => setSelected(c.id)}
                        >
                          {c.customer_legal_name}
                        </button>
                        <div className="font-mono text-xs text-muted-foreground">
                          {c.tenant_code} · {c.quote_number} v{c.quote_version}
                        </div>
                      </td>
                      <td className="py-2 pr-4 font-mono text-xs">{c.plan_code}</td>
                      <td className="py-2 pr-4 text-sm tabular-nums">
                        {money(c.annual_value_minor, c.currency)}
                      </td>
                      <td className="py-2 pr-4 text-xs text-muted-foreground">
                        {day(c.commencement)} → {day(c.current_term_end)} · {c.renewal_kind}
                      </td>
                      <td className="py-2 pr-4 text-xs text-muted-foreground">
                        {day(c.notice_deadline)}
                      </td>
                      <td className="py-2 pr-4 text-sm tabular-nums">
                        {c.amendments}
                        {c.unsigned_amendments > 0 ? (
                          <span className="ml-1 text-xs text-muted-foreground">
                            ({c.unsigned_amendments} unsigned)
                          </span>
                        ) : null}
                      </td>
                      <td className="py-2">
                        <Pill
                          tone={
                            c.status === "active" ? "ok" : c.status === "draft" ? "warn" : "muted"
                          }
                        >
                          {c.status}
                        </Pill>
                      </td>
                    </tr>
                  ))}
                </Table>
              )}

              {mayWrite ? (
                <Form
                  label="Create the contract"
                  fn="erp_platform_create_contract"
                  invalidates={["erp_platform_contracts"]}
                  onDone={(result) => {
                    if (typeof result === "string") setSelected(result);
                  }}
                  build={() =>
                    quote && customer && customerName && platformName && commencement
                      ? {
                          p_quote_document_id: quote,
                          p_customer_tenant_code: customer,
                          p_customer_legal_name: customerName,
                          p_platform_legal_name: platformName,
                          p_commencement: commencement,
                          p_initial_term_months: Number(months) || 12,
                          p_renewal_kind: renewal,
                          p_notice_days: Number(notice) || 0,
                          p_governing_law: law,
                          p_billing_frequency: frequency,
                          p_uplift_rule: uplift(),
                          p_termination_terms: {
                            rights: rights || null,
                            exit_assistance_days: Number(exitDays) || 0,
                            data_return: dataReturn || null,
                          },
                          p_review_date: review || null,
                          p_lead_days: Number(lead) || 30,
                        }
                      : null
                  }
                >
                  <p className="text-xs text-muted-foreground">
                    From an accepted quote of the platform organisation. The plan, bands, features
                    and support tier the quote sold become the contract's position; the order form
                    as issued is held against it with its checksum.
                  </p>
                  <div className="grid gap-2 sm:grid-cols-2">
                    <label className="block text-xs font-medium">
                      Accepted quote
                      <select
                        className={INPUT}
                        value={quote}
                        onChange={(e) => setQuote(e.target.value)}
                      >
                        <option value="">Choose…</option>
                        {list.data.accepted_quotes.map((qq) => (
                          <option key={qq.document_id} value={qq.document_id}>
                            {qq.document_number} v{qq.version} — {qq.party_name ?? ""}{" "}
                            {qq.customer_tenant_code ? `(${qq.customer_tenant_code})` : ""}
                          </option>
                        ))}
                      </select>
                    </label>
                    <label className="block text-xs font-medium">
                      Customer organisation
                      <select
                        className={INPUT}
                        value={customer}
                        onChange={(e) => setCustomer(e.target.value)}
                      >
                        <option value="">Choose…</option>
                        {list.data.organisations.map((o) => (
                          <option key={o.code} value={o.code}>
                            {o.code} — {o.name}
                          </option>
                        ))}
                      </select>
                    </label>
                    <label className="block text-xs font-medium">
                      Customer legal name
                      <input
                        className={INPUT}
                        value={customerName}
                        onChange={(e) => setCustomerName(e.target.value)}
                      />
                    </label>
                    <label className="block text-xs font-medium">
                      Platform legal name
                      <input
                        className={INPUT}
                        value={platformName}
                        onChange={(e) => setPlatformName(e.target.value)}
                      />
                    </label>
                    <label className="block text-xs font-medium">
                      Commencement
                      <input
                        type="date"
                        className={INPUT}
                        value={commencement}
                        onChange={(e) => setCommencement(e.target.value)}
                      />
                    </label>
                    <label className="block text-xs font-medium">
                      Initial term, months
                      <input
                        type="number"
                        className={INPUT}
                        value={months}
                        onChange={(e) => setMonths(e.target.value)}
                      />
                    </label>
                    <label className="block text-xs font-medium">
                      Renewal
                      <select
                        className={INPUT}
                        value={renewal}
                        onChange={(e) => setRenewal(e.target.value)}
                      >
                        <option value="automatic">Automatic</option>
                        <option value="by_agreement">By agreement</option>
                        <option value="none">None</option>
                      </select>
                    </label>
                    <label className="block text-xs font-medium">
                      Notice window, days
                      <input
                        type="number"
                        className={INPUT}
                        value={notice}
                        onChange={(e) => setNotice(e.target.value)}
                      />
                    </label>
                    <label className="block text-xs font-medium">
                      Governing law
                      <input
                        className={INPUT}
                        value={law}
                        onChange={(e) => setLaw(e.target.value)}
                      />
                    </label>
                    <label className="block text-xs font-medium">
                      Billing frequency
                      <select
                        className={INPUT}
                        value={frequency}
                        onChange={(e) => setFrequency(e.target.value)}
                      >
                        <option value="annual">Annual</option>
                        <option value="quarterly">Quarterly</option>
                        <option value="monthly">Monthly</option>
                      </select>
                    </label>
                    <label className="block text-xs font-medium">
                      Uplift rule
                      <select
                        className={INPUT}
                        value={upliftKind}
                        onChange={(e) => setUpliftKind(e.target.value)}
                      >
                        <option value="none">None</option>
                        <option value="fixed_pct">Fixed percentage</option>
                        <option value="index">Index reference</option>
                        <option value="capped">Index, capped</option>
                      </select>
                    </label>
                    {upliftKind === "fixed_pct" ? (
                      <label className="block text-xs font-medium">
                        Uplift, per cent
                        <input
                          type="number"
                          step="0.1"
                          className={INPUT}
                          value={upliftPct}
                          onChange={(e) => setUpliftPct(e.target.value)}
                        />
                      </label>
                    ) : null}
                    {upliftKind === "index" || upliftKind === "capped" ? (
                      <label className="block text-xs font-medium">
                        Index code
                        <input
                          className={INPUT}
                          value={upliftIndex}
                          placeholder="CPI"
                          onChange={(e) => setUpliftIndex(e.target.value)}
                        />
                      </label>
                    ) : null}
                    {upliftKind === "capped" ? (
                      <label className="block text-xs font-medium">
                        Cap, per cent
                        <input
                          type="number"
                          step="0.1"
                          className={INPUT}
                          value={upliftCap}
                          onChange={(e) => setUpliftCap(e.target.value)}
                        />
                      </label>
                    ) : null}
                    <label className="block text-xs font-medium">
                      Termination rights
                      <input
                        className={INPUT}
                        value={rights}
                        onChange={(e) => setRights(e.target.value)}
                      />
                    </label>
                    <label className="block text-xs font-medium">
                      Exit assistance, days
                      <input
                        type="number"
                        className={INPUT}
                        value={exitDays}
                        onChange={(e) => setExitDays(e.target.value)}
                      />
                    </label>
                    <label className="block text-xs font-medium">
                      Data return
                      <input
                        className={INPUT}
                        value={dataReturn}
                        onChange={(e) => setDataReturn(e.target.value)}
                      />
                    </label>
                    <label className="block text-xs font-medium">
                      Review date
                      <input
                        type="date"
                        className={INPUT}
                        value={review}
                        onChange={(e) => setReview(e.target.value)}
                      />
                    </label>
                    <label className="block text-xs font-medium">
                      Notification lead time, days
                      <input
                        type="number"
                        className={INPUT}
                        value={lead}
                        onChange={(e) => setLead(e.target.value)}
                      />
                    </label>
                  </div>
                </Form>
              ) : null}
            </div>
          )}
        </Card>
      )}
    </div>
  );
}

function ContractDetail({
  id,
  mayWrite,
  onBack,
}: {
  id: string;
  mayWrite: boolean;
  onBack: () => void;
}) {
  const q = useQuery({
    queryKey: ["erp_platform_contract", { p_contract_id: id }],
    queryFn: () => callErp<Position>("erp_platform_contract", { p_contract_id: id }),
  });
  const invalidates = ["erp_platform_contract", "erp_platform_contracts"];
  const [sig, setSig] = useState({ customer: "", platform: "", meaning: "" });
  const [amendTitle, setAmendTitle] = useState("");
  const [amendFrom, setAmendFrom] = useState("");
  const [amendChanges, setAmendChanges] = useState(
    '{"entitlements": [{"code": "users", "limit_value": 250}]}',
  );
  const [amendWhy, setAmendWhy] = useState("");
  const [amendSig, setAmendSig] = useState<
    Record<string, { customer: string; platform: string; meaning: string }>
  >({});
  const [docKind, setDocKind] = useState("master_agreement");
  const [docTitle, setDocTitle] = useState("");
  const [docContent, setDocContent] = useState("");
  const [shown, setShown] = useState<string | null>(null);
  const doc = useQuery({
    queryKey: ["erp_platform_contract_document", { p_document_id: shown }],
    queryFn: () =>
      callErp<{ title: string; content: string; checksum: string }>(
        "erp_platform_contract_document",
        { p_document_id: shown },
      ),
    enabled: Boolean(shown),
  });

  if (q.isPending) return <p className="text-sm text-muted-foreground">Loading…</p>;
  if (q.error || !q.data) {
    return (
      <div>
        {q.error ? <Fail error={q.error} /> : null}
        <button type="button" className={`${SECONDARY} mt-3`} onClick={onBack}>
          Back to contracts
        </button>
      </div>
    );
  }
  const c = q.data;

  return (
    <div className="flex flex-col gap-6">
      <div className="flex flex-wrap items-center gap-2">
        <button type="button" className={SECONDARY} onClick={onBack}>
          Back to contracts
        </button>
        <span className="text-sm font-semibold">{c.customer_legal_name}</span>
        <span className="font-mono text-xs text-muted-foreground">{c.tenant_code}</span>
        <Pill tone={c.status === "active" ? "ok" : c.status === "draft" ? "warn" : "muted"}>
          {c.status}
        </Pill>
      </div>

      <Card
        title="The agreement"
        description={`From quote ${c.quote_number} v${c.quote_version}. ${c.governing_law}.`}
      >
        <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
          <dt className="text-muted-foreground">Parties</dt>
          <dd>
            {c.customer_legal_name} and {c.platform_legal_name}
          </dd>
          <dt className="text-muted-foreground">Plan</dt>
          <dd>
            {c.plan_name ?? c.plan_code}{" "}
            <span className="font-mono text-xs text-muted-foreground">{c.plan_code}</span>
            {c.support_severity_code ? (
              <span className="ml-2 text-xs text-muted-foreground">
                support {c.support_severity_code}
              </span>
            ) : null}
          </dd>
          <dt className="text-muted-foreground">Annual value</dt>
          <dd className="tabular-nums">
            {money(c.annual_value_minor, c.currency)} · billed {c.billing_frequency} · {c.term_kind}
          </dd>
          <dt className="text-muted-foreground">Term</dt>
          <dd>
            {day(c.commencement)} for {c.initial_term_months} months; current term{" "}
            {day(c.current_term_start)} → {day(c.current_term_end)}
          </dd>
          <dt className="text-muted-foreground">Renewal</dt>
          <dd>
            {c.renewal_kind} · {c.notice_days} days' notice · uplift {JSON.stringify(c.uplift_rule)}
          </dd>
          <dt className="text-muted-foreground">Termination</dt>
          <dd className="text-xs text-muted-foreground">{JSON.stringify(c.termination_terms)}</dd>
          <dt className="text-muted-foreground">Subscription</dt>
          <dd>
            {c.subscription ? (
              <>
                <span className="font-mono text-xs">{c.subscription.plan_code}</span>{" "}
                {day(c.subscription.term_start)} → {day(c.subscription.term_end)}{" "}
                <Pill tone="ok">{c.subscription.status}</Pill>
              </>
            ) : (
              <span className="text-muted-foreground">
                not yet provisioned; signing provisions it
              </span>
            )}
          </dd>
        </dl>
      </Card>

      <Card
        title="Key dates"
        description={`Each raises a notification in the customer's organisation ${c.lead_days} days ahead, once.`}
      >
        <Table columns={["Date", "Kind", "Days left", "Notified"]}>
          {c.key_dates.map((k) => (
            <tr key={`${k.kind}-${k.due_on}`} className="border-b border-border/50 last:border-0">
              <td className="py-1.5 pr-4 text-sm">{day(k.due_on)}</td>
              <td className="py-1.5 pr-4 text-xs">{k.kind.replace("_", " ")}</td>
              <td className="py-1.5 pr-4 text-sm tabular-nums">{k.days_left}</td>
              <td className="py-1.5 text-xs text-muted-foreground">
                {c.notices.find((n) => n.kind === k.kind && n.due_on === k.due_on) ? "raised" : "—"}
              </td>
            </tr>
          ))}
        </Table>
      </Card>

      <Card
        title="What it provisions"
        description="The bands and features the contract sold, dated. The subscription is derived from these and from the plan; nothing edits it by hand (D35)."
      >
        <div className="grid gap-4 md:grid-cols-2">
          <div>
            <h3 className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
              Bands
            </h3>
            {c.entitlements.length === 0 ? (
              <p className="mt-1 text-xs text-muted-foreground">None beyond the plan.</p>
            ) : (
              <ul className="mt-1 flex flex-col gap-1 text-sm">
                {c.entitlements.map((e, i) => (
                  <li key={`${e.entitlement_code}-${i}`}>
                    <span className="font-medium">{e.title ?? e.entitlement_code}</span>{" "}
                    {e.limit_value == null ? "unlimited" : `${e.limit_value} ${e.unit ?? ""}`}
                    <span className="ml-2 text-xs text-muted-foreground">
                      {day(e.effective_from)} → {day(e.effective_to)}
                    </span>{" "}
                    {e.in_force ? <Pill tone="ok">in force</Pill> : null}
                  </li>
                ))}
              </ul>
            )}
          </div>
          <div>
            <h3 className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
              Features
            </h3>
            {c.capabilities.length === 0 ? (
              <p className="mt-1 text-xs text-muted-foreground">None beyond the plan.</p>
            ) : (
              <ul className="mt-1 flex flex-col gap-1 text-sm">
                {c.capabilities.map((f, i) => (
                  <li key={`${f.capability_code}-${i}`}>
                    <span className="font-mono text-xs">{f.capability_code}</span>
                    <span className="ml-2 text-xs text-muted-foreground">
                      {day(f.effective_from)} → {day(f.effective_to)}
                    </span>{" "}
                    {f.in_force ? <Pill tone="ok">in force</Pill> : null}
                  </li>
                ))}
              </ul>
            )}
          </div>
        </div>
      </Card>

      <Card
        title="Documents"
        description="Versioned and signed, each with the checksum of what was signed."
      >
        <Table columns={["Kind", "Version", "Title", "Checksum", "Signed", ""]}>
          {c.documents.map((d) => (
            <tr key={d.id} className="border-b border-border/50 align-top last:border-0">
              <td className="py-1.5 pr-4 text-xs">{d.kind.replace(/_/g, " ")}</td>
              <td className="py-1.5 pr-4 text-sm tabular-nums">{d.version}</td>
              <td className="py-1.5 pr-4 text-sm">{d.title}</td>
              <td className="py-1.5 pr-4 font-mono text-xs text-muted-foreground">
                {d.checksum.slice(0, 12)}…
              </td>
              <td className="py-1.5 pr-4 text-xs">
                {d.signed_at ? (
                  <>
                    <Pill tone="ok">signed</Pill>
                    <div className="mt-0.5 text-muted-foreground">
                      {d.signed_by_customer} and {d.signed_by_platform}: {d.signature_meaning}
                    </div>
                  </>
                ) : d.superseded_by ? (
                  <Pill tone="muted">superseded</Pill>
                ) : (
                  <Pill tone="warn">unsigned</Pill>
                )}
              </td>
              <td className="py-1.5">
                <button type="button" className={SECONDARY} onClick={() => setShown(d.id)}>
                  Show
                </button>
              </td>
            </tr>
          ))}
        </Table>
        {shown && doc.data ? (
          <pre className="mt-3 max-h-80 overflow-auto rounded-md bg-muted p-3 text-xs">
            {doc.data.content}
          </pre>
        ) : null}
        {mayWrite ? (
          <div className="mt-4">
            <Form
              label="Attach a document"
              fn="erp_platform_attach_contract_document"
              invalidates={invalidates}
              build={() =>
                docTitle && docContent
                  ? { p_contract_id: id, p_kind: docKind, p_title: docTitle, p_content: docContent }
                  : null
              }
            >
              <div className="grid gap-2 sm:grid-cols-2">
                <label className="block text-xs font-medium">
                  Kind
                  <select
                    className={INPUT}
                    value={docKind}
                    onChange={(e) => setDocKind(e.target.value)}
                  >
                    {[
                      "master_agreement",
                      "data_processing_agreement",
                      "service_level_terms",
                      "security_schedule",
                      "side_letter",
                    ].map((k) => (
                      <option key={k} value={k}>
                        {k.replace(/_/g, " ")}
                      </option>
                    ))}
                  </select>
                </label>
                <label className="block text-xs font-medium">
                  Title
                  <input
                    className={INPUT}
                    value={docTitle}
                    onChange={(e) => setDocTitle(e.target.value)}
                  />
                </label>
              </div>
              <label className="block text-xs font-medium">
                Text
                <textarea
                  className={`${INPUT} min-h-32`}
                  value={docContent}
                  onChange={(e) => setDocContent(e.target.value)}
                />
              </label>
            </Form>
          </div>
        ) : null}
      </Card>

      {mayWrite && c.status === "draft" ? (
        <Card
          title="Sign"
          description="Both signers and the meaning of the signature are recorded on every unsigned document. Signing provisions the subscription from the contract."
        >
          <Form
            label="Sign and provision"
            fn="erp_platform_sign_contract"
            invalidates={invalidates}
            build={() =>
              sig.customer && sig.platform && sig.meaning
                ? {
                    p_contract_id: id,
                    p_customer_signer: sig.customer,
                    p_platform_signer: sig.platform,
                    p_signature_meaning: sig.meaning,
                  }
                : null
            }
          >
            <Signature onChange={setSig} />
          </Form>
        </Card>
      ) : null}

      <Invoices contractId={id} mayWrite={mayWrite} status={c.status} />

      <Card
        title="Amendments"
        description="Every change is an addendum with its own signature; it provisions from its effective date."
      >
        {c.amendments.length === 0 ? (
          <p className="text-sm text-muted-foreground">No amendment.</p>
        ) : (
          <ul className="flex flex-col gap-3">
            {c.amendments.map((a) => (
              <li key={a.id} className="rounded-lg border border-border/60 p-3">
                <div className="flex flex-wrap items-center gap-2 text-sm">
                  <span className="font-medium">
                    {a.seq}. {a.title}
                  </span>
                  <span className="text-xs text-muted-foreground">
                    from {day(a.effective_from)}
                  </span>
                  {a.signed_at ? <Pill tone="ok">signed</Pill> : <Pill tone="warn">unsigned</Pill>}
                  {a.provisioned_at ? <Pill tone="ok">provisioned</Pill> : null}
                </div>
                <pre className="mt-1 overflow-auto rounded bg-muted p-2 text-xs">
                  {JSON.stringify(a.changes, null, 1)}
                </pre>
                {a.rationale ? (
                  <p className="mt-1 text-xs text-muted-foreground">{a.rationale}</p>
                ) : null}
                {mayWrite && !a.signed_at ? (
                  <div className="mt-2">
                    <Form
                      label="Sign the amendment"
                      fn="erp_platform_sign_amendment"
                      invalidates={invalidates}
                      build={() => {
                        const s = amendSig[a.id];
                        return s && s.customer && s.platform && s.meaning
                          ? {
                              p_amendment_id: a.id,
                              p_customer_signer: s.customer,
                              p_platform_signer: s.platform,
                              p_signature_meaning: s.meaning,
                            }
                          : null;
                      }}
                    >
                      <Signature
                        onChange={(v) => setAmendSig((prev) => ({ ...prev, [a.id]: v }))}
                      />
                    </Form>
                  </div>
                ) : null}
              </li>
            ))}
          </ul>
        )}
        {mayWrite && (c.status === "active" || c.status === "terminating") ? (
          <div className="mt-4">
            <Form
              label="Draft an amendment"
              fn="erp_platform_amend_contract"
              invalidates={invalidates}
              build={() => {
                try {
                  const changes = JSON.parse(amendChanges) as Record<string, unknown>;
                  return amendTitle && amendFrom
                    ? {
                        p_contract_id: id,
                        p_title: amendTitle,
                        p_effective_from: amendFrom,
                        p_changes: changes,
                        p_rationale: amendWhy || null,
                      }
                    : null;
                } catch {
                  return null;
                }
              }}
            >
              <div className="grid gap-2 sm:grid-cols-2">
                <label className="block text-xs font-medium">
                  Title
                  <input
                    className={INPUT}
                    value={amendTitle}
                    onChange={(e) => setAmendTitle(e.target.value)}
                  />
                </label>
                <label className="block text-xs font-medium">
                  Effective from
                  <input
                    type="date"
                    className={INPUT}
                    value={amendFrom}
                    onChange={(e) => setAmendFrom(e.target.value)}
                  />
                </label>
              </div>
              <label className="block text-xs font-medium">
                Changes, as JSON: plan_code, entitlements [code, limit_value], capabilities [code,
                action], term_end, annual_value_minor, renewal_kind, notice_days, uplift_rule
                <textarea
                  className={`${INPUT} min-h-24 font-mono`}
                  value={amendChanges}
                  onChange={(e) => setAmendChanges(e.target.value)}
                />
              </label>
              <label className="block text-xs font-medium">
                Rationale
                <input
                  className={INPUT}
                  value={amendWhy}
                  onChange={(e) => setAmendWhy(e.target.value)}
                />
              </label>
            </Form>
          </div>
        ) : null}
      </Card>
    </div>
  );
}

type InvoiceLine =
  | { kind: "subscription"; net_minor: number; description: string }
  | {
      kind: "overage";
      entitlement_code: string;
      unit: string;
      month: string;
      used: number;
      limit_value: number | null;
      over: number;
      unit_minor: number | null;
      band: string | null;
      net_minor: number;
      unpriced: boolean;
    };

type Invoice = {
  id: string;
  reference: string;
  period_start: string;
  period_end: string;
  due_on: string;
  currency: string;
  subscription_minor: number;
  overage_minor: number;
  total_minor: number;
  status: string;
  issued_at: string | null;
  paid_at: string | null;
  payment_reference: string | null;
  lines: InvoiceLine[];
};

/**
 * §17.10: the invoice schedule generated from the term and the billing
 * frequency, each invoice reconciled against the metering when it is issued.
 * A scheduled invoice shows the overage it would carry today from the same
 * meters the customer sees, so nothing on the issued invoice is a surprise.
 */
function Invoices({
  contractId,
  mayWrite,
  status,
}: {
  contractId: string;
  mayWrite: boolean;
  status: string;
}) {
  const queryClient = useQueryClient();
  const q = useQuery({
    queryKey: ["erp_platform_invoices", { p_contract_id: contractId }],
    queryFn: () => callErp<Invoice[]>("erp_platform_invoices", { p_contract_id: contractId }),
  });
  const invalidate = () => {
    for (const k of ["erp_platform_invoices", "erp_platform_revenue"]) {
      void queryClient.invalidateQueries({ queryKey: [k] });
    }
  };
  const generate = useMutation({
    mutationFn: () =>
      callErp<number>("erp_platform_generate_invoices", { p_contract_id: contractId }),
    onSuccess: invalidate,
  });
  const issue = useMutation({
    mutationFn: (id: string) => callErp("erp_platform_issue_invoice", { p_invoice_id: id }),
    onSuccess: invalidate,
  });
  const paid = useMutation({
    mutationFn: (args: { id: string; reference: string }) =>
      callErp("erp_platform_record_invoice_paid", {
        p_invoice_id: args.id,
        p_payment_reference: args.reference,
      }),
    onSuccess: invalidate,
  });
  const [payRef, setPayRef] = useState<Record<string, string>>({});
  const [open, setOpen] = useState<string | null>(null);
  const inForce = status === "active" || status === "terminating";

  return (
    <Card
      title="Invoices"
      description="Generated from the term and the billing frequency. Issuing reconciles the period against the metering and prices any overage from the book; a scheduled invoice shows the overage it would carry today."
      action={
        mayWrite && inForce ? (
          <button
            type="button"
            className={SECONDARY}
            disabled={generate.isPending}
            onClick={() => generate.mutate()}
          >
            {generate.isPending ? "Generating…" : "Generate the schedule"}
          </button>
        ) : null
      }
    >
      {generate.error ? <Fail error={generate.error} /> : null}
      {generate.isSuccess ? (
        <p className="mb-2 text-xs text-muted-foreground">
          {generate.data} invoice(s) added to the schedule.
        </p>
      ) : null}
      {issue.error ? <Fail error={issue.error} /> : null}
      {paid.error ? <Fail error={paid.error} /> : null}
      {q.isPending ? (
        <p className="text-sm text-muted-foreground">Loading…</p>
      ) : q.error ? (
        <Fail error={q.error} />
      ) : !q.data || q.data.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          Nothing is scheduled. A contract in force with no schedule is a finding on the customer
          view check.
        </p>
      ) : (
        <Table
          columns={["Reference", "Period", "Due", "Subscription", "Overage", "Total", "State", ""]}
        >
          {q.data.map((i) => (
            <Fragment key={i.id}>
              <tr className="border-b border-border/50 align-top last:border-0">
                <td className="py-2 pr-4">
                  <button
                    type="button"
                    className="font-mono text-xs underline underline-offset-2"
                    onClick={() => setOpen(open === i.id ? null : i.id)}
                  >
                    {i.reference}
                  </button>
                </td>
                <td className="py-2 pr-4 text-xs">
                  {day(i.period_start)} → {day(i.period_end)}
                </td>
                <td className="py-2 pr-4 text-xs">{day(i.due_on)}</td>
                <td className="py-2 pr-4 text-sm tabular-nums">
                  {money(i.subscription_minor, i.currency)}
                </td>
                <td className="py-2 pr-4 text-sm tabular-nums">
                  {i.status === "scheduled"
                    ? money(
                        i.lines
                          .filter((l) => l.kind === "overage")
                          .reduce((a, l) => a + l.net_minor, 0),
                        i.currency,
                      )
                    : money(i.overage_minor, i.currency)}
                  {i.lines.some((l) => l.kind === "overage" && l.unpriced) ? (
                    <Pill tone="bad">unpriced</Pill>
                  ) : null}
                </td>
                <td className="py-2 pr-4 text-sm tabular-nums">
                  {money(i.total_minor, i.currency)}
                </td>
                <td className="py-2 pr-4">
                  <Pill
                    tone={i.status === "paid" ? "ok" : i.status === "issued" ? "warn" : "muted"}
                  >
                    {i.status}
                  </Pill>
                </td>
                <td className="py-2">
                  {mayWrite && i.status === "scheduled" ? (
                    <button
                      type="button"
                      className={SECONDARY}
                      disabled={issue.isPending}
                      onClick={() => issue.mutate(i.id)}
                    >
                      Issue
                    </button>
                  ) : mayWrite && i.status === "issued" ? (
                    <form
                      className="flex gap-1"
                      onSubmit={(e) => {
                        e.preventDefault();
                        const reference = payRef[i.id] ?? "";
                        if (reference) paid.mutate({ id: i.id, reference });
                      }}
                    >
                      <input
                        className={`${INPUT} w-32`}
                        aria-label="Payment reference"
                        placeholder="Payment reference"
                        value={payRef[i.id] ?? ""}
                        onChange={(e) => setPayRef((prev) => ({ ...prev, [i.id]: e.target.value }))}
                      />
                      <button type="submit" className={SECONDARY} disabled={paid.isPending}>
                        Paid
                      </button>
                    </form>
                  ) : i.payment_reference ? (
                    <span className="text-xs text-muted-foreground">{i.payment_reference}</span>
                  ) : null}
                </td>
              </tr>
              {open === i.id ? (
                <tr className="border-b border-border/50 last:border-0">
                  <td colSpan={8} className="pb-3">
                    <InvoiceLines lines={i.lines} currency={i.currency} />
                  </td>
                </tr>
              ) : null}
            </Fragment>
          ))}
        </Table>
      )}
    </Card>
  );
}

export function InvoiceLines({ lines, currency }: { lines: InvoiceLine[]; currency: string }) {
  if (lines.length === 0) {
    return <p className="text-xs text-muted-foreground">No line.</p>;
  }
  return (
    <Table columns={["Line", "Used", "Limit", "Over", "Unit", "Band", "Net"]}>
      {lines.map((l, n) => (
        <tr key={n} className="border-b border-border/50 last:border-0">
          {l.kind === "subscription" ? (
            <>
              <td className="py-1.5 pr-4 text-xs" colSpan={6}>
                {l.description}
              </td>
              <td className="py-1.5 text-sm tabular-nums">{money(l.net_minor, currency)}</td>
            </>
          ) : (
            <>
              <td className="py-1.5 pr-4 text-xs">
                {l.entitlement_code.replace(/_/g, " ")} · {day(l.month)}
              </td>
              <td className="py-1.5 pr-4 text-xs tabular-nums">{l.used.toLocaleString()}</td>
              <td className="py-1.5 pr-4 text-xs tabular-nums">
                {l.limit_value == null ? "—" : l.limit_value.toLocaleString()}
              </td>
              <td className="py-1.5 pr-4 text-xs tabular-nums">{l.over.toLocaleString()}</td>
              <td className="py-1.5 pr-4 text-xs tabular-nums">
                {l.unit_minor == null ? <Pill tone="bad">unpriced</Pill> : `${l.unit_minor}p`}
              </td>
              <td className="py-1.5 pr-4 font-mono text-xs">{l.band ?? "—"}</td>
              <td className="py-1.5 text-sm tabular-nums">{money(l.net_minor, currency)}</td>
            </>
          )}
        </tr>
      ))}
    </Table>
  );
}
