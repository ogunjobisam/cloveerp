import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { ArrowLeft, FileText, Minus, Plus } from "lucide-react";
import { useState, type ReactNode } from "react";

import { Pill, Table } from "../erp/panel";
import { TOUCH } from "../erp/page";
import { callErp } from "../../lib/erp";
import { atLeast, type PlatformRole } from "../../lib/platform";
import {
  STAGES,
  contractDefaults,
  discountCeiling,
  extraItemFor,
  lineFor,
  money,
  oneOffItems,
  orderFormTotal,
  partyCodeFor,
  planItems,
  quotePlan,
  rateFor,
  stageOf,
  supportItems,
  termLabel,
  termUnit,
  userItemFor,
  type PriceItem,
  type QuoteLine,
} from "../../lib/quote-builder";
import { QuoteEmail } from "./commercial-email";
import { Card, ConsoleLink, Fail, INPUT, LINK_BUTTON } from "./kit";
import type { CommercialState } from "./selling";

/**
 * Quotes, built in the console.
 *
 * On 14 September the platform owner opened the console to build a quote and
 * found no way to. Quotes had lived on a desk screen inside Clove ERP's own
 * organisation, asking for price item codes by hand. This builds one from
 * choices — a plan, users beyond it, extras, onboarding, support — and walks it
 * through approval, the order form, the customer's answer and the contract.
 *
 * Every write is the platform organisation's own door, run as the person at
 * the keyboard inside that organisation, so the discount approval, the order
 * form and the audit trail are exactly the desk's. That needs them to be
 * working in that organisation; the screen says so and switches with one click.
 */

const BUTTON = `${TOUCH} inline-flex items-center justify-center gap-1.5 rounded-md bg-primary px-3 text-sm font-semibold text-primary-foreground disabled:opacity-60`;
const SECONDARY = `${TOUCH} inline-flex items-center justify-center gap-1.5 rounded-md border border-input px-3 text-sm font-medium disabled:opacity-60`;
const STEP =
  "inline-flex size-9 items-center justify-center rounded-md border border-input disabled:opacity-40";

type MyTenant = { tenant_id: string; code: string; name: string; is_active: boolean };

type QuoteRow = {
  document_id: string;
  document_number: string;
  version: number;
  party_name: string | null;
  customer_tenant_code: string | null;
  term_kind: string;
  term_months: number;
  currency: string;
  valid_until: string;
  programme: string | null;
  state: string;
  superseded_by: string | null;
  total_minor: number | null;
  margin_pct: number | null;
  created_at: string;
};

type QuotesReport = {
  is_platform_organisation: boolean;
  installed: boolean;
  threshold_pct: number | null;
  quotes: QuoteRow[];
};

type QuoteDetail = {
  document_id: string;
  document_number: string;
  version: number;
  party_name: string | null;
  customer_tenant_code: string | null;
  price_book_code: string;
  term_kind: string;
  term_months: number;
  currency: string;
  valid_until: string;
  notes: string | null;
  programme: string | null;
  state: string;
  superseded_by: string | null;
  margin: {
    threshold_pct: number | null;
    lines: QuoteLine[];
    totals: {
      quoted_minor: number;
      recurring_minor: number;
      one_off_minor: number;
      margin_pct: number | null;
      max_discount_pct: number;
      below_cost_lines: number;
    };
  };
  approval: { status: string; outstanding: number } | null;
  order_form: { checksum: string; rendered_at: string; content: unknown } | null;
};

type PriceBook = { items: PriceItem[] };

type Approval = { task_id: string; object_id: string; status: string };

type Enquiry = {
  id: string;
  submitted_at: string;
  full_name: string | null;
  email: string | null;
  organisation: string | null;
  message: string | null;
  status: string;
};

function day(value: string | null | undefined) {
  return value ? new Date(value).toLocaleDateString("en-GB") : "—";
}

function randomSuffix() {
  return Math.random().toString(36).slice(2, 6);
}

/** The writes every part of the builder shares: call a door, refresh what it changed. */
function useDoor<A extends Record<string, unknown>, R = unknown>(
  fn: string,
  onDone?: (r: R) => void,
) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (args: A) => callErp<R>(fn, args),
    onSuccess: (r) => {
      onDone?.(r);
    },
    onSettled: () => {
      void queryClient.invalidateQueries({ queryKey: ["erp_commercial_quotes"] });
      void queryClient.invalidateQueries({ queryKey: ["erp_commercial_quote"] });
      void queryClient.invalidateQueries({ queryKey: ["erp_my_approvals"] });
      void queryClient.invalidateQueries({ queryKey: ["erp_platform_contracts"] });
      void queryClient.invalidateQueries({ queryKey: ["erp_platform_commercial_emails"] });
    },
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Where quotes can be built from
// ─────────────────────────────────────────────────────────────────────────────

export function Quotes({ role }: { role: PlatformRole }) {
  const queryClient = useQueryClient();
  const [open, setOpen] = useState<string | null>(null);

  const state = useQuery({
    queryKey: ["erp_platform_commercial_state"],
    queryFn: () => callErp<CommercialState>("erp_platform_commercial_state"),
  });
  const tenants = useQuery({
    queryKey: ["erp_my_tenants"],
    queryFn: () => callErp<MyTenant[]>("erp_my_tenants"),
  });
  const switchTo = useMutation({
    mutationFn: (tenantId: string) => callErp("erp_set_active_tenant", { p_tenant_id: tenantId }),
    onSuccess: () => queryClient.invalidateQueries(),
  });

  if (state.isPending || tenants.isPending) {
    return <p className="text-sm text-muted-foreground">Loading…</p>;
  }
  if (state.error) return <Fail error={state.error} />;
  if (tenants.error) return <Fail error={tenants.error} />;

  const platform = state.data.platform_organisation;
  const selling = state.data.selling;
  const name = platform?.name ?? platform?.tenant_code ?? "";

  if (!platform || !selling?.installed || !selling.price_book) {
    return (
      <Card title="Quotes" icon={<FileText className="size-4 text-primary" />}>
        <p className="text-sm text-muted-foreground">
          Quotes are built from Clove ERP&apos;s price list. Set selling up first: choose Clove
          ERP&apos;s own organisation and load the price list.
        </p>
        <ConsoleLink section="catalogue" view="selling" className={`${LINK_BUTTON} mt-3`}>
          Set up selling
        </ConsoleLink>
      </Card>
    );
  }

  const membership = tenants.data.find((t) => t.tenant_id === platform.tenant_id);
  if (!membership) {
    return (
      <Card title="Quotes" icon={<FileText className="size-4 text-primary" />}>
        <p className="text-sm">
          Quotes are built inside {name}, and you are not a member of it. Invite yourself as its
          administrator from its page, accept the invitation, then come back.
        </p>
        <ConsoleLink
          section="customers"
          view="organisations"
          org={platform.tenant_code}
          className={`${LINK_BUTTON} mt-3`}
        >
          Open {name}
        </ConsoleLink>
      </Card>
    );
  }
  if (!membership.is_active) {
    const current = tenants.data.find((t) => t.is_active);
    return (
      <Card title="Quotes" icon={<FileText className="size-4 text-primary" />}>
        <div className="flex flex-col gap-3">
          <p className="text-sm">
            Quotes are built inside {name}, so its discount approvals, order forms and records are
            the ones used. {current ? `You are working in ${current.name} at the moment.` : null}
          </p>
          <p className="text-xs text-muted-foreground">
            Switching changes the organisation your desk opens in too. Switch back from the account
            menu whenever you like.
          </p>
          {switchTo.error ? <Fail error={switchTo.error} /> : null}
          <button
            type="button"
            className={`${BUTTON} self-start`}
            disabled={switchTo.isPending}
            onClick={() => switchTo.mutate(platform.tenant_id)}
          >
            {switchTo.isPending ? "Switching…" : `Work in ${name}`}
          </button>
        </div>
      </Card>
    );
  }

  const book = selling.price_book.code;
  const mayWrite = atLeast(role, "operator");
  const customers = state.data.candidates.filter(
    (c) => !c.is_demonstration && c.code !== platform.tenant_code,
  );

  return open ? (
    <QuoteBuilder
      documentId={open}
      book={book}
      mayWrite={mayWrite}
      customers={customers}
      onBack={() => setOpen(null)}
      onOpen={setOpen}
    />
  ) : (
    <Pipeline book={book} mayWrite={mayWrite} customers={customers} onOpen={setOpen} />
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// The pipeline
// ─────────────────────────────────────────────────────────────────────────────

function Pipeline({
  book,
  mayWrite,
  customers,
  onOpen,
}: {
  book: string;
  mayWrite: boolean;
  customers: { code: string; name: string }[];
  onOpen: (id: string) => void;
}) {
  const [showClosed, setShowClosed] = useState(false);
  const [starting, setStarting] = useState(false);
  const list = useQuery({
    queryKey: ["erp_commercial_quotes"],
    queryFn: () => callErp<QuotesReport>("erp_commercial_quotes"),
  });

  const rows = list.data?.quotes ?? [];

  return (
    <div className="flex flex-col gap-6">
      <Renewals mayWrite={mayWrite} onOpen={onOpen} />
      <Card
        title="Quotes"
        icon={<FileText className="size-4 text-primary" />}
        description="Every quote from first draft to signed contract. Discounts above 10% wait for approval, and a quote can carry up to 25% off, or 35% for a founding customer."
        action={
          mayWrite && !starting ? (
            <button type="button" className={BUTTON} onClick={() => setStarting(true)}>
              <Plus className="size-4" /> New quote
            </button>
          ) : null
        }
      >
        {starting ? (
          <NewQuote
            book={book}
            customers={customers}
            onCancel={() => setStarting(false)}
            onOpened={(id) => {
              setStarting(false);
              onOpen(id);
            }}
          />
        ) : list.isPending ? (
          <p className="text-sm text-muted-foreground">Loading…</p>
        ) : list.error ? (
          <Fail error={list.error} />
        ) : rows.length === 0 ? (
          <p className="text-sm text-muted-foreground">No quotes yet. Start one from New quote.</p>
        ) : (
          <div className="flex flex-col gap-5">
            {STAGES.filter((s) => showClosed || s.key !== "closed").map((s) => {
              const inStage = rows.filter((r) => stageOf(r.state, r.superseded_by) === s.key);
              if (inStage.length === 0) return null;
              return (
                <section key={s.key} className="flex flex-col gap-2">
                  <div className="flex flex-wrap items-baseline gap-2">
                    <h3 className="text-sm font-semibold">{s.label}</h3>
                    <span className="text-xs text-muted-foreground">
                      {inStage.length} · {s.hint}
                    </span>
                  </div>
                  <Table columns={["Quote", "Customer", "Term", "Total", "Margin", "Valid until"]}>
                    {inStage.map((r) => (
                      <tr key={r.document_id} className="border-b border-border/60 last:border-0">
                        <td className="py-2 pr-4">
                          <button
                            type="button"
                            className="text-left font-medium underline-offset-2 hover:underline"
                            onClick={() => onOpen(r.document_id)}
                          >
                            {r.document_number}
                            {r.version > 1 ? ` v${r.version}` : ""}
                          </button>
                          {r.programme === "founding" ? (
                            <span className="ml-2">
                              <Pill tone="ok">Founding customer</Pill>
                            </span>
                          ) : null}
                        </td>
                        <td className="py-2 pr-4 text-sm">{r.party_name ?? "—"}</td>
                        <td className="py-2 pr-4 text-sm">
                          {termLabel(r.term_kind, r.term_months)}
                        </td>
                        <td className="py-2 pr-4 text-sm tabular-nums">
                          {money(r.total_minor, r.currency)}
                        </td>
                        <td className="py-2 pr-4 text-sm tabular-nums">
                          {r.margin_pct == null ? "—" : `${r.margin_pct}%`}
                        </td>
                        <td className="py-2 text-sm">{day(r.valid_until)}</td>
                      </tr>
                    ))}
                  </Table>
                </section>
              );
            })}
            <button
              type="button"
              className="self-start text-xs text-muted-foreground underline underline-offset-2"
              onClick={() => setShowClosed((v) => !v)}
            >
              {showClosed ? "Hide closed quotes" : "Show closed quotes"}
            </button>
          </div>
        )}
      </Card>
    </div>
  );
}

type RenewalRow = {
  id: string;
  tenant_code: string;
  customer_legal_name: string;
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

/**
 * Renewals waiting for a quote.
 *
 * The renewal sweep proposes each renewal at its contract's lead time with the
 * uplift already applied, and its quote was raised only on the desk. Here it is
 * one button: the quote carries the contract's recurring lines at the uplifted
 * price, leaves one-off charges behind, and opens in the builder like any other.
 * Signing it is recorded under Billing, which is where the button points.
 */
function Renewals({ mayWrite, onOpen }: { mayWrite: boolean; onOpen: (id: string) => void }) {
  const renewals = useQuery({
    queryKey: ["erp_commercial_renewals"],
    queryFn: () => callErp<RenewalRow[]>("erp_commercial_renewals"),
  });
  const raise = useDoor<{ p_renewal_id: string }, string>("erp_open_renewal_quote", (id) => {
    if (typeof id === "string") onOpen(id);
  });
  const queryClient = useQueryClient();

  const rows = renewals.data ?? [];
  if (renewals.isPending || (rows.length === 0 && !renewals.error)) return null;

  return (
    <Card
      title="Renewals to quote"
      icon={<FileText className="size-4 text-primary" />}
      description="Proposed by the renewal sweep ahead of each contract's end, with its uplift applied. The quote carries the contract's recurring lines at the new price and goes through approval and the order form like any other."
    >
      {renewals.error ? (
        <Fail error={renewals.error} />
      ) : (
        <div className="flex flex-col gap-3">
          <Table columns={["Customer", "New term", "This year", "Proposed", "Notice by", ""]}>
            {rows.map((r) => (
              <tr key={r.id} className="border-b border-border/60 align-middle last:border-0">
                <td className="py-2 pr-4 text-sm">
                  {r.customer_legal_name}
                  <span className="block font-mono text-xs text-muted-foreground">
                    {r.tenant_code}
                  </span>
                </td>
                <td className="py-2 pr-4 text-sm">
                  {day(r.term_start)} to {day(r.term_end)}
                </td>
                <td className="py-2 pr-4 text-sm tabular-nums">
                  {money(r.previous_annual_value_minor, r.currency)}
                </td>
                <td className="py-2 pr-4 text-sm tabular-nums">
                  {money(r.proposed_annual_value_minor, r.currency)}
                  <span className="block text-xs text-muted-foreground">
                    {r.uplift_pct > 0 ? `up ${r.uplift_pct}%` : "no increase"}
                  </span>
                </td>
                <td className="py-2 pr-4 text-sm">{day(r.notice_deadline)}</td>
                <td className="py-2 text-right">
                  {r.status === "quoted" && r.quote_document_id ? (
                    <button
                      type="button"
                      className={SECONDARY}
                      onClick={() => onOpen(r.quote_document_id ?? "")}
                    >
                      Open the renewal quote
                    </button>
                  ) : mayWrite ? (
                    <button
                      type="button"
                      className={BUTTON}
                      disabled={raise.isPending}
                      onClick={() =>
                        raise.mutate(
                          { p_renewal_id: r.id },
                          {
                            onSettled: () =>
                              void queryClient.invalidateQueries({
                                queryKey: ["erp_commercial_renewals"],
                              }),
                          },
                        )
                      }
                    >
                      {raise.isPending && raise.variables?.p_renewal_id === r.id
                        ? "Raising…"
                        : "Raise the renewal quote"}
                    </button>
                  ) : null}
                </td>
              </tr>
            ))}
          </Table>
          <p className="text-xs text-muted-foreground">
            A founding customer&apos;s discount is carried onto the renewal quote. Within their 24
            months, mark the renewal quote as a founding customer quote; after them, lower the
            discount. Once the customer accepts, sign the renewal under Billing.
          </p>
          <ConsoleLink section="billing" view="revenue" className={`${LINK_BUTTON} self-start`}>
            Open renewals under Billing
          </ConsoleLink>
          {raise.error ? <Fail error={raise.error} /> : null}
        </div>
      )}
    </Card>
  );
}

function NewQuote({
  book,
  customers,
  onCancel,
  onOpened,
}: {
  book: string;
  customers: { code: string; name: string }[];
  onCancel: () => void;
  onOpened: (id: string) => void;
}) {
  const [who, setWho] = useState<"prospect" | "organisation">("prospect");
  const [enquiry, setEnquiry] = useState("");
  const [prospect, setProspect] = useState("");
  const [organisation, setOrganisation] = useState("");
  const [term, setTerm] = useState("annual");
  const [years, setYears] = useState("2");
  const [founding, setFounding] = useState(false);
  const [notes, setNotes] = useState("");
  const [contactEmail, setContactEmail] = useState("");
  const [contactName, setContactName] = useState("");
  const [error, setError] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  const queryClient = useQueryClient();

  const enquiries = useQuery({
    queryKey: ["erp_platform_enquiries"],
    queryFn: () => callErp<Enquiry[]>("erp_platform_enquiries", { p_limit: 50 }),
  });

  const chosenOrg = customers.find((c) => c.code === organisation);
  const partyName = who === "organisation" ? (chosenOrg?.name ?? "") : prospect.trim();

  async function start() {
    setError(null);
    setBusy(true);
    try {
      const months = term === "multi_year" ? Number(years) * 12 : 12;
      const id = await callErp<string>("erp_open_commercial_quote", {
        p_party_code: partyCodeFor(partyName, randomSuffix()),
        p_party_name: partyName,
        p_price_book_code: book,
        p_term_kind: term,
        p_term_months: months,
        p_currency: "GBP",
        p_valid_days: 30,
        p_customer_tenant_code: who === "organisation" ? organisation : null,
        p_notes: notes.trim() || null,
      });
      if (founding) {
        await callErp("erp_set_quote_programme", { p_document_id: id, p_programme: "founding" });
      }
      if (contactEmail.trim()) {
        // The order form is emailed here the moment the quote is issued.
        await callErp("erp_set_quote_contact", {
          p_document_id: id,
          p_name: contactName.trim() || null,
          p_email: contactEmail.trim(),
        });
      }
      void queryClient.invalidateQueries({ queryKey: ["erp_commercial_quotes"] });
      onOpened(id);
    } catch (e) {
      setError(e);
    } finally {
      setBusy(false);
    }
  }

  return (
    <form
      className="flex flex-col gap-3"
      onSubmit={(e) => {
        e.preventDefault();
        if (partyName) void start();
      }}
    >
      <div className="flex flex-wrap gap-2" role="radiogroup" aria-label="Who is it for">
        {(
          [
            ["prospect", "A new prospect"],
            ["organisation", "An organisation already on Clove ERP"],
          ] as const
        ).map(([k, label]) => (
          <button
            key={k}
            type="button"
            role="radio"
            aria-checked={who === k}
            className={who === k ? BUTTON : SECONDARY}
            onClick={() => setWho(k)}
          >
            {label}
          </button>
        ))}
      </div>

      {who === "prospect" ? (
        <div className="grid gap-3 sm:grid-cols-2">
          <label className="block text-xs font-medium">
            From an enquiry
            <select
              className={INPUT}
              value={enquiry}
              onChange={(e) => {
                setEnquiry(e.target.value);
                const q = (enquiries.data ?? []).find((x) => x.id === e.target.value);
                if (q) {
                  setProspect(q.organisation || q.full_name || "");
                  setContactEmail(q.email ?? "");
                  setContactName(q.full_name ?? "");
                  setNotes(
                    `Enquiry from ${q.full_name ?? "someone"}${q.email ? ` <${q.email}>` : ""} on ${day(q.submitted_at)}.${
                      q.message ? ` ${q.message.slice(0, 300)}` : ""
                    }`,
                  );
                }
              }}
            >
              <option value="">None</option>
              {(enquiries.data ?? [])
                .filter((q) => q.status !== "erased")
                .map((q) => (
                  <option key={q.id} value={q.id}>
                    {q.organisation || q.full_name || q.email} · {day(q.submitted_at)}
                  </option>
                ))}
            </select>
          </label>
          <label className="block text-xs font-medium">
            Company name
            <input
              className={INPUT}
              value={prospect}
              required
              placeholder="Okafor Foods Ltd"
              onChange={(e) => setProspect(e.target.value)}
            />
          </label>
        </div>
      ) : (
        <label className="block text-xs font-medium">
          Organisation
          <select
            className={INPUT}
            value={organisation}
            required
            onChange={(e) => setOrganisation(e.target.value)}
          >
            <option value="">Choose…</option>
            {customers.map((c) => (
              <option key={c.code} value={c.code}>
                {c.name} ({c.code})
              </option>
            ))}
          </select>
        </label>
      )}

      <div className="grid gap-3 sm:grid-cols-2">
        <label className="block text-xs font-medium">
          Customer email
          <input
            className={INPUT}
            type="email"
            value={contactEmail}
            placeholder="dana@okaforfoods.co.uk"
            onChange={(e) => setContactEmail(e.target.value)}
          />
          <span className="mt-1 block font-normal text-muted-foreground">
            {who === "organisation"
              ? "Leave it empty to email the order form to the organisation's administrators."
              : "The order form is emailed here the moment the quote is issued."}
          </span>
        </label>
        <label className="block text-xs font-medium">
          Contact name
          <input
            className={INPUT}
            value={contactName}
            placeholder="Dana Okafor"
            onChange={(e) => setContactName(e.target.value)}
          />
        </label>
      </div>

      <div className="grid gap-3 sm:grid-cols-2">
        <label className="block text-xs font-medium">
          Billing
          <select className={INPUT} value={term} onChange={(e) => setTerm(e.target.value)}>
            <option value="annual">Annual, billed yearly</option>
            <option value="multi_year">Several years, 10% less a year</option>
            <option value="monthly">Month to month, 15% more</option>
          </select>
        </label>
        {term === "multi_year" ? (
          <label className="block text-xs font-medium">
            Years
            <select className={INPUT} value={years} onChange={(e) => setYears(e.target.value)}>
              <option value="2">Two years</option>
              <option value="3">Three years</option>
            </select>
          </label>
        ) : null}
      </div>

      <label className="flex items-start gap-2 text-sm">
        <input
          type="checkbox"
          className="mt-1"
          checked={founding}
          onChange={(e) => setFounding(e.target.checked)}
        />
        <span>
          Founding customer
          <span className="block text-xs text-muted-foreground">
            Up to 35% off for 24 months, in return for a case study, a monthly feedback call and
            being a reference.
          </span>
        </span>
      </label>

      <label className="block text-xs font-medium">
        Notes
        <textarea
          className={`${INPUT} min-h-20`}
          value={notes}
          onChange={(e) => setNotes(e.target.value)}
        />
      </label>

      {error ? <Fail error={error} /> : null}
      <div className="flex flex-wrap gap-2">
        <button type="submit" className={BUTTON} disabled={!partyName || busy}>
          {busy ? "Starting…" : "Start the quote"}
        </button>
        <button type="button" className={SECONDARY} onClick={onCancel}>
          Cancel
        </button>
      </div>
    </form>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// One quote
// ─────────────────────────────────────────────────────────────────────────────

function Section({
  title,
  hint,
  children,
}: {
  title: string;
  hint?: string | undefined;
  children: ReactNode;
}) {
  return (
    <section className="flex flex-col gap-2 border-t border-border/60 pt-4 first:border-0 first:pt-0">
      <div>
        <h3 className="text-sm font-semibold">{title}</h3>
        {hint ? <p className="text-xs text-muted-foreground">{hint}</p> : null}
      </div>
      {children}
    </section>
  );
}

/** Console text is not tenant terminology, so a caption, not a screen-string label. */
function Stepper({
  caption,
  hint,
  value,
  min = 0,
  disabled,
  onChange,
}: {
  caption: string;
  hint: string;
  value: number;
  min?: number;
  disabled: boolean;
  onChange: (n: number) => void;
}) {
  const [draft, setDraft] = useState<string | null>(null);
  const commit = (text: string) => {
    setDraft(null);
    const n = Math.max(min, Math.floor(Number(text)));
    if (Number.isFinite(n) && n !== value) onChange(n);
  };
  return (
    <div className="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-border/60 p-3">
      <div className="min-w-0">
        <p className="text-sm font-medium">{caption}</p>
        <p className="text-xs text-muted-foreground">{hint}</p>
      </div>
      <div className="flex items-center gap-1.5">
        <button
          type="button"
          className={STEP}
          aria-label={`Fewer: ${caption}`}
          disabled={disabled || value <= min}
          onClick={() => onChange(value - 1)}
        >
          <Minus className="size-4" />
        </button>
        <input
          className="h-9 w-16 rounded-md border border-input bg-background text-center text-sm tabular-nums"
          inputMode="numeric"
          aria-label={caption}
          disabled={disabled}
          value={draft ?? String(value)}
          onChange={(e) => setDraft(e.target.value)}
          onBlur={(e) => commit(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") commit((e.target as HTMLInputElement).value);
          }}
        />
        <button
          type="button"
          className={STEP}
          aria-label={`More: ${caption}`}
          disabled={disabled}
          onClick={() => onChange(value + 1)}
        >
          <Plus className="size-4" />
        </button>
      </div>
    </div>
  );
}

function QuoteBuilder({
  documentId,
  book,
  mayWrite,
  customers,
  onBack,
  onOpen,
}: {
  documentId: string;
  book: string;
  mayWrite: boolean;
  customers: { code: string; name: string }[];
  onBack: () => void;
  onOpen: (id: string) => void;
}) {
  const detail = useQuery({
    queryKey: ["erp_commercial_quote", documentId],
    queryFn: () => callErp<QuoteDetail>("erp_commercial_quote", { p_document_id: documentId }),
  });
  const priceBook = useQuery({
    queryKey: ["erp_price_book"],
    queryFn: () => callErp<PriceBook>("erp_price_book"),
  });
  const approvals = useQuery({
    queryKey: ["erp_my_approvals"],
    queryFn: () => callErp<Approval[]>("erp_my_approvals"),
  });

  const add = useDoor<{
    p_document_id: string;
    p_item_code: string;
    p_quantity: number;
    p_discount_pct: number;
  }>("erp_add_quote_line");
  const remove = useDoor<{ p_line_id: string }>("erp_remove_quote_line");
  const discount = useDoor<{ p_line_id: string; p_discount_pct: number }>(
    "erp_set_quote_line_discount",
  );
  const programme = useDoor<{ p_document_id: string; p_programme: string | null }>(
    "erp_set_quote_programme",
  );
  const submit = useDoor<{ p_document_id: string }>("erp_submit_quote");
  const approve = useMutation({
    mutationFn: async (taskId: string) => {
      await callErp("erp_decide_approval", { p_task_id: taskId, p_approve: true });
      return callErp("erp_approve_quote", { p_document_id: documentId });
    },
  });
  const issue = useDoor<{ p_document_id: string }>("erp_issue_quote");
  const answer = useDoor<{
    p_document_id: string;
    p_transition_code: string;
    p_reason: string | null;
  }>("erp_quote_transition");
  const revise = useDoor<{ p_document_id: string; p_reason: string | null }, string>(
    "erp_revise_quote",
    (id) => onOpen(id),
  );
  const queryClient = useQueryClient();

  const [busy, setBusy] = useState(false);
  const [actionError, setActionError] = useState<unknown>(null);

  if (detail.isPending || priceBook.isPending) {
    return <p className="text-sm text-muted-foreground">Loading…</p>;
  }
  if (detail.error) return <Fail error={detail.error} />;
  if (priceBook.error) return <Fail error={priceBook.error} />;

  const d = detail.data;
  const items = priceBook.data.items;
  const lines = d.margin.lines;
  const draft = d.state === "draft" && !d.superseded_by;
  const editable = draft && mayWrite;
  const plan = quotePlan(lines);
  const planLine = lines.find((l) => l.kind === "plan_tier") ?? null;
  const planItem = items.find((i) => i.code === planLine?.item_code) ?? null;
  const unit = termUnit(d.term_kind);
  const ceiling = discountCeiling(d.programme);
  const threshold = d.margin.threshold_pct ?? 10;
  const task = (approvals.data ?? []).find(
    (a) => a.object_id === documentId && a.status === "pending",
  );

  /** Set a line to a quantity: added, replaced, or taken off at nought. */
  async function setQuantity(item: PriceItem | null, quantity: number) {
    if (!item) return;
    setActionError(null);
    setBusy(true);
    try {
      const existing = lineFor(lines, item.code);
      if (existing) await callErp("erp_remove_quote_line", { p_line_id: existing.line_id });
      if (quantity > 0) {
        await callErp("erp_add_quote_line", {
          p_document_id: documentId,
          p_item_code: item.code,
          p_quantity: quantity,
          p_discount_pct: existing?.discount_pct ?? 0,
        });
      }
    } catch (e) {
      setActionError(e);
    } finally {
      setBusy(false);
      void queryClient.invalidateQueries({ queryKey: ["erp_commercial_quote", documentId] });
      void queryClient.invalidateQueries({ queryKey: ["erp_commercial_quotes"] });
    }
  }

  /** Change plan: the plan's own users go with it, so they are taken off first. */
  async function choosePlan(next: PriceItem) {
    setActionError(null);
    setBusy(true);
    try {
      for (const l of lines) {
        if (l.kind === "plan_tier" || l.kind === "full_user" || l.kind === "light_user") {
          await callErp("erp_remove_quote_line", { p_line_id: l.line_id });
        }
      }
      await callErp("erp_add_quote_line", {
        p_document_id: documentId,
        p_item_code: next.code,
        p_quantity: 1,
        p_discount_pct: 0,
      });
    } catch (e) {
      setActionError(e);
    } finally {
      setBusy(false);
      void queryClient.invalidateQueries({ queryKey: ["erp_commercial_quote", documentId] });
      void queryClient.invalidateQueries({ queryKey: ["erp_commercial_quotes"] });
    }
  }

  const fullUser = userItemFor(items, "full_user", plan);
  const lightUser = userItemFor(items, "light_user", plan);
  const extraCompany = extraItemFor(items, "companies");
  const extraSite = extraItemFor(items, "sites");
  const oneOff = oneOffItems(items);
  const support = supportItems(items);
  const pending =
    busy || add.isPending || remove.isPending || discount.isPending || programme.isPending;

  const errors = [
    actionError,
    add.error,
    remove.error,
    discount.error,
    programme.error,
    submit.error,
    approve.error,
    issue.error,
    answer.error,
    revise.error,
  ].filter(Boolean);

  return (
    <div className="flex flex-col gap-6">
      <button type="button" className={`${SECONDARY} self-start`} onClick={onBack}>
        <ArrowLeft className="size-4" /> All quotes
      </button>

      <Card
        title={`${d.document_number}${d.version > 1 ? ` v${d.version}` : ""} · ${d.party_name ?? "Customer"}`}
        icon={<FileText className="size-4 text-primary" />}
        description={`${termLabel(d.term_kind, d.term_months)} · valid until ${day(d.valid_until)}${
          d.customer_tenant_code ? ` · organisation ${d.customer_tenant_code}` : ""
        }`}
        action={
          <span className="flex flex-wrap gap-2">
            <Pill tone={stageOf(d.state, d.superseded_by) === "closed" ? "muted" : "ok"}>
              {STAGES.find((s) => s.key === stageOf(d.state, d.superseded_by))?.label ?? d.state}
            </Pill>
            {d.programme === "founding" ? <Pill tone="ok">Founding customer</Pill> : null}
          </span>
        }
      >
        <div className="flex flex-col gap-5">
          {editable ? (
            <>
              <Section title="Plan" hint={`Prices ${unit}, before any discount.`}>
                <div className="grid gap-3 md:grid-cols-3">
                  {planItems(items).map((p) => {
                    const chosen = p.code === planLine?.item_code;
                    return (
                      <button
                        key={p.code}
                        type="button"
                        disabled={pending || chosen}
                        onClick={() => void choosePlan(p)}
                        className={`flex flex-col items-start gap-1 rounded-lg border p-3 text-left ${
                          chosen
                            ? "border-primary ring-2 ring-primary/25"
                            : "border-border hover:bg-muted/50"
                        }`}
                      >
                        <span className="text-sm font-semibold">{p.name}</span>
                        <span className="text-lg font-semibold tabular-nums">
                          {money(rateFor(p, book, d.term_kind))}
                          <span className="ml-1 text-xs font-normal text-muted-foreground">
                            {unit}
                          </span>
                        </span>
                        <span className="text-xs text-muted-foreground">
                          {p.included_users ?? 0} full users included
                        </span>
                        {chosen ? <Pill tone="ok">On this quote</Pill> : null}
                      </button>
                    );
                  })}
                </div>
              </Section>

              {plan ? (
                <Section
                  title="People"
                  hint={`${planItem?.included_users ?? 0} full users come with the plan. Light users only approve, read reports or use the scanner.`}
                >
                  <div className="grid gap-3 md:grid-cols-2">
                    <Stepper
                      caption="Extra full users"
                      hint={
                        fullUser
                          ? `${money(rateFor(fullUser, book, d.term_kind))} each ${unit}`
                          : "Not on the price list"
                      }
                      value={lineFor(lines, fullUser?.code)?.quantity ?? 0}
                      disabled={pending || !fullUser}
                      onChange={(n) => void setQuantity(fullUser, n)}
                    />
                    <Stepper
                      caption="Light users"
                      hint={
                        lightUser
                          ? `${money(rateFor(lightUser, book, d.term_kind))} each ${unit}`
                          : "Not on the price list"
                      }
                      value={lineFor(lines, lightUser?.code)?.quantity ?? 0}
                      disabled={pending || !lightUser}
                      onChange={(n) => void setQuantity(lightUser, n)}
                    />
                  </div>
                </Section>
              ) : null}

              {plan ? (
                <Section title="Companies and sites" hint="Beyond what the plan includes.">
                  <div className="grid gap-3 md:grid-cols-2">
                    {[extraCompany, extraSite].map((x, i) =>
                      x ? (
                        <Stepper
                          key={x.code}
                          caption={x.name}
                          hint={`${money(rateFor(x, book, d.term_kind))} each ${unit}`}
                          value={lineFor(lines, x.code)?.quantity ?? 0}
                          disabled={pending}
                          onChange={(n) => void setQuantity(x, n)}
                        />
                      ) : (
                        <p key={i} className="text-xs text-muted-foreground">
                          Not on the price list.
                        </p>
                      ),
                    )}
                  </div>
                </Section>
              ) : null}

              {plan ? (
                <Section title="Getting started and support">
                  <div className="flex flex-col gap-2">
                    {[...oneOff, ...support].map((x) => {
                      const on = Boolean(lineFor(lines, x.code));
                      const rate = rateFor(x, book, d.term_kind);
                      return (
                        <label
                          key={x.code}
                          className="flex items-start justify-between gap-3 rounded-lg border border-border/60 p-3"
                        >
                          <span className="flex items-start gap-2">
                            <input
                              type="checkbox"
                              className="mt-1"
                              checked={on}
                              disabled={pending || (rate == null && !on)}
                              onChange={(e) => void setQuantity(x, e.target.checked ? 1 : 0)}
                            />
                            <span>
                              <span className="block text-sm font-medium">{x.name}</span>
                              <span className="block text-xs text-muted-foreground">
                                {x.description}
                                {rate == null ? " Not sold on this billing term." : ""}
                              </span>
                            </span>
                          </span>
                          <span className="shrink-0 text-sm tabular-nums">
                            {x.percent_of_recurring
                              ? `${x.percent_of_recurring}%, at least ${money(rate)}`
                              : x.charge === "one_off"
                                ? `${money(rate)} once`
                                : `${money(rate)} ${unit}`}
                          </span>
                        </label>
                      );
                    })}
                  </div>
                </Section>
              ) : null}

              <Section
                title="Founding customer"
                hint="Up to 35% off in return for a case study, a monthly feedback call and being a reference. Every other quote may carry up to 25%."
              >
                <label className="flex items-center gap-2 text-sm">
                  <input
                    type="checkbox"
                    checked={d.programme === "founding"}
                    disabled={pending}
                    onChange={(e) =>
                      programme.mutate({
                        p_document_id: documentId,
                        p_programme: e.target.checked ? "founding" : null,
                      })
                    }
                  />
                  This is a founding customer quote
                </label>
              </Section>
            </>
          ) : null}

          <Section
            title="What the customer pays"
            hint={
              editable
                ? `Discounts above ${threshold}% need approving; this quote may carry up to ${ceiling}%.`
                : undefined
            }
          >
            {lines.length === 0 ? (
              <p className="text-sm text-muted-foreground">Choose a plan to begin.</p>
            ) : (
              <Table columns={["", "Quantity", `Each, ${unit}`, "Discount", "Line", "Margin", ""]}>
                {lines.map((l) => (
                  <tr
                    key={l.line_id}
                    className="border-b border-border/60 align-middle last:border-0"
                  >
                    <td className="py-2 pr-3 text-sm">
                      {l.name}
                      {l.charge === "one_off" ? (
                        <span className="ml-2">
                          <Pill tone="muted">Once</Pill>
                        </span>
                      ) : null}
                    </td>
                    <td className="py-2 pr-3 text-sm tabular-nums">{l.quantity}</td>
                    <td className="py-2 pr-3 text-sm tabular-nums">{money(l.list_minor)}</td>
                    <td className="py-2 pr-3 text-sm">
                      {editable && l.kind !== "legislation_pack" ? (
                        <DiscountInput
                          value={l.discount_pct ?? 0}
                          ceiling={ceiling}
                          disabled={pending}
                          onCommit={(n) =>
                            discount.mutate({ p_line_id: l.line_id, p_discount_pct: n })
                          }
                        />
                      ) : (
                        <span className="tabular-nums">
                          {l.discount_pct ? `${l.discount_pct}%` : "—"}
                        </span>
                      )}
                    </td>
                    <td className="py-2 pr-3 text-sm tabular-nums">{money(l.quoted_minor)}</td>
                    <td className="py-2 pr-3 text-sm">
                      {l.margin_pct == null ? (
                        "—"
                      ) : (
                        <Pill tone={l.below_cost ? "bad" : l.margin_pct < 20 ? "warn" : "ok"}>
                          {l.margin_pct}%
                        </Pill>
                      )}
                    </td>
                    <td className="py-2 text-right">
                      {editable ? (
                        <button
                          type="button"
                          className="text-xs text-muted-foreground underline underline-offset-2"
                          disabled={pending}
                          onClick={() => remove.mutate({ p_line_id: l.line_id })}
                        >
                          Remove
                        </button>
                      ) : null}
                    </td>
                  </tr>
                ))}
              </Table>
            )}
            <dl className="grid gap-x-6 gap-y-1 text-sm sm:grid-cols-2">
              <div className="flex justify-between gap-3">
                <dt className="text-muted-foreground">Subscription, {unit}</dt>
                <dd className="font-semibold tabular-nums">
                  {money(d.margin.totals.recurring_minor)}
                </dd>
              </div>
              <div className="flex justify-between gap-3">
                <dt className="text-muted-foreground">Charged once</dt>
                <dd className="tabular-nums">{money(d.margin.totals.one_off_minor)}</dd>
              </div>
              <div className="flex justify-between gap-3">
                <dt className="text-muted-foreground">Margin</dt>
                <dd className="tabular-nums">
                  {d.margin.totals.margin_pct == null ? "—" : `${d.margin.totals.margin_pct}%`}
                  {d.margin.totals.below_cost_lines > 0
                    ? ` · ${d.margin.totals.below_cost_lines} line(s) below cost`
                    : ""}
                </dd>
              </div>
              <div className="flex justify-between gap-3">
                <dt className="text-muted-foreground">Largest discount</dt>
                <dd className="tabular-nums">
                  {d.margin.totals.max_discount_pct}%
                  {d.margin.totals.max_discount_pct > threshold ? " · needs approval" : ""}
                </dd>
              </div>
            </dl>
          </Section>

          {mayWrite ? (
            <Section title="Next step">
              <div className="flex flex-wrap items-center gap-2">
                {draft ? (
                  <button
                    type="button"
                    className={BUTTON}
                    disabled={pending || submit.isPending || !plan}
                    onClick={() => submit.mutate({ p_document_id: documentId })}
                  >
                    {d.margin.totals.max_discount_pct > threshold
                      ? "Send for approval"
                      : "Finish the quote"}
                  </button>
                ) : null}
                {d.state === "pending_approval" ? (
                  task ? (
                    <button
                      type="button"
                      className={BUTTON}
                      disabled={approve.isPending}
                      onClick={() =>
                        approve.mutate(task.task_id, {
                          onSettled: () => {
                            void queryClient.invalidateQueries({
                              queryKey: ["erp_commercial_quote"],
                            });
                            void queryClient.invalidateQueries({
                              queryKey: ["erp_commercial_quotes"],
                            });
                            void queryClient.invalidateQueries({ queryKey: ["erp_my_approvals"] });
                          },
                        })
                      }
                    >
                      Approve the discount
                    </button>
                  ) : (
                    <p className="text-sm text-muted-foreground">
                      Waiting for an administrator to approve the discount. It moves on once they
                      have.
                    </p>
                  )
                ) : null}
                {d.state === "approved" && !d.superseded_by ? (
                  <button
                    type="button"
                    className={BUTTON}
                    disabled={issue.isPending}
                    onClick={() => issue.mutate({ p_document_id: documentId })}
                  >
                    Issue the order form
                  </button>
                ) : null}
                {d.state === "issued" && !d.superseded_by ? (
                  <>
                    <button
                      type="button"
                      className={BUTTON}
                      disabled={answer.isPending}
                      onClick={() =>
                        answer.mutate({
                          p_document_id: documentId,
                          p_transition_code: "accept",
                          p_reason: "order form returned signed",
                        })
                      }
                    >
                      The customer accepted
                    </button>
                    <button
                      type="button"
                      className={SECONDARY}
                      disabled={answer.isPending}
                      onClick={() =>
                        answer.mutate({
                          p_document_id: documentId,
                          p_transition_code: "decline",
                          p_reason: "the customer declined",
                        })
                      }
                    >
                      The customer declined
                    </button>
                  </>
                ) : null}
                {["draft", "pending_approval", "approved", "issued"].includes(d.state) &&
                !d.superseded_by ? (
                  <button
                    type="button"
                    className={SECONDARY}
                    disabled={revise.isPending}
                    onClick={() => revise.mutate({ p_document_id: documentId, p_reason: null })}
                  >
                    Make a new version
                  </button>
                ) : null}
              </div>
              {d.superseded_by ? (
                <button
                  type="button"
                  className="self-start text-sm underline underline-offset-2"
                  onClick={() => onOpen(d.superseded_by ?? documentId)}
                >
                  Open the newer version
                </button>
              ) : null}
            </Section>
          ) : null}

          {errors.map((e, i) => (
            <Fail key={i} error={e} />
          ))}

          {!d.superseded_by || d.order_form ? (
            <Section
              title="Emailing the order form"
              hint="Sent to the customer the moment the quote is issued, with Send again for when it goes astray."
            >
              <QuoteEmail
                documentId={documentId}
                issued={Boolean(d.order_form)}
                mayWrite={mayWrite}
              />
            </Section>
          ) : null}

          {d.order_form ? (
            <Section
              title="Order form"
              hint={`Issued ${day(d.order_form.rendered_at)} · fingerprint ${d.order_form.checksum.slice(0, 12)}`}
            >
              <OrderForm content={d.order_form.content} />
            </Section>
          ) : null}
        </div>
      </Card>

      {d.state === "accepted" && mayWrite ? (
        <ContractFromQuote quote={d} customers={customers} />
      ) : null}
    </div>
  );
}

function DiscountInput({
  value,
  ceiling,
  disabled,
  onCommit,
}: {
  value: number;
  ceiling: number;
  disabled: boolean;
  onCommit: (n: number) => void;
}) {
  const [draft, setDraft] = useState<string | null>(null);
  const commit = (text: string) => {
    setDraft(null);
    const n = Number(text);
    if (Number.isFinite(n) && n !== value) onCommit(Math.max(0, Math.min(100, n)));
  };
  return (
    <span className="inline-flex items-center gap-1">
      <input
        className="h-9 w-16 rounded-md border border-input bg-background text-right text-sm tabular-nums"
        inputMode="decimal"
        aria-label={`Discount, up to ${ceiling}%`}
        disabled={disabled}
        value={draft ?? String(value)}
        onChange={(e) => setDraft(e.target.value)}
        onBlur={(e) => commit(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter") commit((e.target as HTMLInputElement).value);
        }}
      />
      <span className="text-xs text-muted-foreground">%</span>
    </span>
  );
}

/** The order form as the customer read it: its lines and totals, not its JSON. */
function OrderForm({ content }: { content: unknown }) {
  const record =
    typeof content === "object" && content !== null ? (content as Record<string, unknown>) : {};
  const total = orderFormTotal(content);
  const fact = (label: string, value: unknown) =>
    value == null || value === "" ? null : (
      <div key={label} className="flex justify-between gap-3">
        <dt className="text-muted-foreground">{label}</dt>
        <dd className="tabular-nums">{String(value)}</dd>
      </div>
    );
  return (
    <dl className="grid gap-x-6 gap-y-1 text-sm sm:grid-cols-2">
      {fact("Version", record["quote_version"])}
      {fact("Price list", record["price_book"])}
      {fact(
        "Term",
        typeof record["term_kind"] === "string"
          ? termLabel(record["term_kind"], Number(record["term_months"]))
          : null,
      )}
      {fact(
        "Valid until",
        typeof record["valid_until"] === "string" ? day(record["valid_until"]) : null,
      )}
      {fact("Total", total == null ? null : money(total))}
    </dl>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// The contract, from the accepted quote
// ─────────────────────────────────────────────────────────────────────────────

const PLATFORM_NAME_KEY = "clove.platform_legal_name";

function rememberedPlatformName(): string {
  try {
    return window.localStorage.getItem(PLATFORM_NAME_KEY) ?? "Clove ERP Ltd";
  } catch {
    return "Clove ERP Ltd";
  }
}

function ContractFromQuote({
  quote,
  customers,
}: {
  quote: QuoteDetail;
  customers: { code: string; name: string }[];
}) {
  const defaults = contractDefaults(quote);
  const [customer, setCustomer] = useState(defaults.customerTenantCode);
  const [customerName, setCustomerName] = useState(defaults.customerLegalName);
  const [platformName, setPlatformName] = useState(rememberedPlatformName);
  const [commencement, setCommencement] = useState(() => new Date().toISOString().slice(0, 10));
  const [months, setMonths] = useState(defaults.initialTermMonths);
  const [billing, setBilling] = useState(defaults.billingFrequency);
  const [done, setDone] = useState<string | null>(null);

  const create = useDoor<Record<string, unknown>, string>("erp_platform_create_contract", (id) => {
    try {
      window.localStorage.setItem(PLATFORM_NAME_KEY, platformName);
    } catch {
      // A browser that keeps nothing still made the contract.
    }
    setDone(id);
  });

  return (
    <Card
      title="Make the contract"
      icon={<FileText className="size-4 text-primary" />}
      description="From the accepted quote. It is drafted here and signed under Contracts, which sets up the organisation's subscription."
    >
      {done ? (
        <div>
          <p className="text-sm" role="status">
            The contract is drafted. Sign it under Contracts to switch the subscription on.
          </p>
          <ConsoleLink section="sales" view="contracts" className={`${LINK_BUTTON} mt-3`}>
            Open Contracts
          </ConsoleLink>
        </div>
      ) : customers.length === 0 ? (
        <div>
          <p className="text-sm text-muted-foreground">
            {quote.party_name ?? "The customer"} is not an organisation on Clove ERP yet. Onboard
            them under Customers, then come back to make the contract.
          </p>
          <ConsoleLink section="customers" view="organisations" className={`${LINK_BUTTON} mt-3`}>
            Open Customers
          </ConsoleLink>
        </div>
      ) : (
        <form
          className="flex flex-col gap-3"
          onSubmit={(e) => {
            e.preventDefault();
            if (!customer || !customerName.trim() || !platformName.trim()) return;
            create.mutate({
              p_quote_document_id: quote.document_id,
              p_customer_tenant_code: customer,
              p_customer_legal_name: customerName.trim(),
              p_platform_legal_name: platformName.trim(),
              p_commencement: commencement,
              p_initial_term_months: Number(months),
              p_billing_frequency: billing,
              p_uplift_rule: defaults.upliftRule,
              p_termination_terms: {
                rights: "either party on material breach unremedied after 30 days",
                exit_assistance_days: 90,
                data_return: "full export in open formats before deletion",
              },
            });
          }}
        >
          <div className="grid gap-3 sm:grid-cols-2">
            <label className="block text-xs font-medium">
              Customer organisation
              <select
                className={INPUT}
                value={customer}
                required
                onChange={(e) => setCustomer(e.target.value)}
              >
                <option value="">Choose…</option>
                {customers.map((c) => (
                  <option key={c.code} value={c.code}>
                    {c.name} ({c.code})
                  </option>
                ))}
              </select>
            </label>
            <label className="block text-xs font-medium">
              Customer&apos;s legal name
              <input
                className={INPUT}
                value={customerName}
                required
                onChange={(e) => setCustomerName(e.target.value)}
              />
            </label>
            <label className="block text-xs font-medium">
              Our legal name
              <input
                className={INPUT}
                value={platformName}
                required
                onChange={(e) => setPlatformName(e.target.value)}
              />
            </label>
            <label className="block text-xs font-medium">
              Starts on
              <input
                type="date"
                className={INPUT}
                value={commencement}
                required
                onChange={(e) => setCommencement(e.target.value)}
              />
            </label>
            <label className="block text-xs font-medium">
              First term, months
              <input
                className={INPUT}
                inputMode="numeric"
                value={months}
                required
                onChange={(e) => setMonths(e.target.value)}
              />
            </label>
            <label className="block text-xs font-medium">
              Invoiced
              <select
                className={INPUT}
                value={billing}
                onChange={(e) => setBilling(e.target.value)}
              >
                <option value="annual">Yearly</option>
                <option value="quarterly">Quarterly</option>
                <option value="monthly">Monthly</option>
              </select>
            </label>
          </div>
          <p className="text-xs text-muted-foreground">
            Renews automatically with 90 days&apos; notice. Renewal increases follow CPI, capped at
            5%. Governed by the law of England and Wales. Onboarding and other one-off charges go on
            the first invoice.
          </p>
          {create.error ? <Fail error={create.error} /> : null}
          <button type="submit" className={`${BUTTON} self-start`} disabled={create.isPending}>
            {create.isPending ? "Drafting…" : "Draft the contract"}
          </button>
        </form>
      )}
    </Card>
  );
}
