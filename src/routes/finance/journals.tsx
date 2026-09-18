import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useMemo, useState } from "react";
import { toast } from "sonner";

import { ActionButton, ActionDialog, ErrorNote, useErpAction } from "../../components/erp/action";
import { useCurrencies } from "../../components/erp/currencies";
import { Gate } from "../../components/erp/gate";
import { PageHeader, Prose, TOUCH } from "../../components/erp/page";
import { Pill, Table } from "../../components/erp/panel";
import { useErpSession } from "../../components/erp/session-context";
import { useUnsavedGuard } from "../../components/erp/unsaved";
import { callErp, hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import {
  COST_CENTRE,
  JOURNAL_STATES,
  LINE_PROBLEM_TEXT,
  draftLinesOf,
  emptyLine,
  isBlankLine,
  journalLinesArg,
  journalName,
  journalTotals,
  lineAmounts,
  readJournals,
  stateLabel,
  stateTone,
  type DraftLine,
  type Journal,
  type JournalState,
} from "../../lib/journals";
import { formatMinor, minorUnitsOf, type Currency } from "../../lib/money";

export const Route = createFileRoute("/finance/journals")({
  head: () => ({
    meta: [
      { title: "Journals — Clove ERP" },
      {
        name: "description",
        content:
          "Accruals, prepayments and corrections typed by hand: raised by one person, approved and posted by another, and reversed rather than changed.",
      },
      { property: "og:title", content: "Journals — Clove ERP" },
      {
        property: "og:description",
        content:
          "Manual journals with maker and checker: a lines editor that balances as you type, approval, sending back and reversal.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <Journals />
    </Gate>
  ),
});

/**
 * Journals typed by hand.
 *
 * One person raises a journal and submits it; somebody else who may approve
 * journals posts it (supabase/migrations/20260914071000_finance_can_journal_and_close.sql).
 * The database refuses an unbalanced journal, a closed period, an account out
 * of use or kept by a subledger, and, once the organisation is live, anybody
 * approving their own. Hiding a button here only saves somebody a refusal.
 */

/** The doors this screen drives, each with the permission the database asks for. */
const DOORS = {
  list: { fn: "erp_journals", permission: "finance.read" },
  raise: { fn: "erp_raise_journal", permission: "finance.post" },
  submit: { fn: "erp_submit_journal", permission: "finance.post" },
  discard: { fn: "erp_discard_journal", permission: "finance.post" },
  approve: { fn: "erp_approve_journal", permission: "finance.close_period" },
} as const;

/** What a journal changes when it moves: the list, and every reading of the ledger. */
const INVALIDATES = [
  "erp_journals",
  "erp_trial_balance",
  "erp_profit_and_loss",
  "erp_balance_sheet",
];

const SECONDARY = `${TOUCH} inline-flex shrink-0 items-center justify-center rounded-md border border-input px-4 text-sm font-medium`;

type Entity = { entity_id: string; code: string; name: string; base_currency: string | null };
type Account = {
  account_id: string;
  code: string;
  name: string;
  entity_id: string;
  status: string;
};
type CostCentre = { code: string; name: string; status: string };

const today = () => new Date().toISOString().slice(0, 10);

function Journals() {
  const { t, ui } = useT();
  const { session } = useErpSession();
  const [state, setState] = useState<JournalState | "all">("all");
  const [editing, setEditing] = useState<Journal | "new" | null>(null);

  const args = { p_state: state === "all" ? null : state, p_limit: 200 };
  const list = useQuery({
    queryKey: [DOORS.list.fn, args],
    queryFn: () => callErp<unknown>(DOORS.list.fn, args),
  });
  const journals = readJournals(list.data);

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader
        title={t("nav.finance_journals", "Journals")}
        howItWorks={ui(
          "One person raises and submits a journal; somebody else who may approve journals posts it. A posted journal is never changed, only reversed.",
        )}
      >
        {ui("Accruals, prepayments and corrections typed by hand.")}
      </PageHeader>

      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex flex-wrap gap-2" aria-label={ui("Show journals")}>
          {[{ value: "all" as const, label: "All" }, ...JOURNAL_STATES].map((s) => (
            <button
              key={s.value}
              type="button"
              aria-pressed={state === s.value}
              onClick={() => setState(s.value)}
              className={`${TOUCH} inline-flex items-center rounded-full border px-3 text-sm ${
                state === s.value
                  ? "border-primary bg-primary text-primary-foreground"
                  : "border-input bg-card"
              }`}
            >
              {ui(s.label)}
            </button>
          ))}
        </div>
        {editing === null && hasPermission(session, DOORS.raise.permission) ? (
          <ActionButton onClick={() => setEditing("new")}>{ui("New journal")}</ActionButton>
        ) : null}
      </div>

      {editing !== null ? (
        <JournalEditor
          key={editing === "new" ? "new" : editing.journal_id}
          journal={editing === "new" ? null : editing}
          onClose={() => setEditing(null)}
        />
      ) : null}

      <section className="min-w-0 rounded-xl border border-border bg-card">
        <header className="border-b border-border px-4 py-4 sm:px-5">
          <h2 className="text-sm font-semibold">{ui("Journals typed by hand")}</h2>
          <Prose className="mt-0.5 text-xs text-muted-foreground">
            {ui("Newest first. Open a journal to see its lines and what can be done with it.")}
          </Prose>
        </header>
        <div className="px-4 py-4 sm:px-5">
          {list.isPending ? (
            <p role="status" className="text-sm text-muted-foreground">
              Loading…
            </p>
          ) : list.error ? (
            <ErrorNote error={list.error} />
          ) : journals.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              {ui("No journals here. A journal raised with New journal appears here as a draft.")}
            </p>
          ) : (
            <ul className="flex flex-col divide-y divide-border">
              {journals.map((j) => (
                <JournalRow key={j.journal_id} journal={j} onChange={() => setEditing(j)} />
              ))}
            </ul>
          )}
        </div>
      </section>
    </div>
  );
}

/** One journal: its heading, and when opened its lines and what may be done with it. */
function JournalRow({ journal, onChange }: { journal: Journal; onChange: () => void }) {
  const { ui } = useT();
  const { session } = useErpSession();
  const { currencies } = useCurrencies();
  const [open, setOpen] = useState(false);

  const minorUnits = minorUnitsOf(currencies, journal.currency);
  const money = (minor: number) => formatMinor(minor, journal.currency, minorUnits);
  const name = journalName(journal);
  const context = `${name} · ${journal.company ?? ""} · ${journal.posting_date}`;

  const submit = useErpAction({ fn: DOORS.submit.fn, invalidates: INVALIDATES });
  const discard = useErpAction({ fn: DOORS.discard.fn, invalidates: INVALIDATES });
  const approve = useErpAction({
    fn: DOORS.approve.fn,
    invalidates: INVALIDATES,
    onDone: () => toast(ui("Approved and posted.")),
  });

  const mayRaise = hasPermission(session, DOORS.raise.permission);
  const mayApprove = hasPermission(session, DOORS.approve.permission);
  const isDraft = journal.state === "draft" || journal.state === "returned";
  const busy = submit.isPending || discard.isPending || approve.isPending;

  return (
    <li className="min-w-0 py-3">
      <button
        type="button"
        aria-expanded={open}
        onClick={() => setOpen((v) => !v)}
        className={`${TOUCH} flex w-full min-w-0 flex-wrap items-center gap-x-4 gap-y-1 text-left`}
      >
        <span className="font-mono text-xs">{name}</span>
        <span className="text-xs text-muted-foreground">{journal.posting_date}</span>
        <span className="text-xs text-muted-foreground">{journal.company}</span>
        <span className="min-w-0 flex-1 truncate text-sm">{journal.narrative}</span>
        <span className="text-sm tabular-nums">{money(journal.debit_minor)}</span>
        <Pill tone={stateTone(journal.state)}>{ui(stateLabel(journal.state))}</Pill>
      </button>

      {open ? (
        <div className="mt-3 flex min-w-0 flex-col gap-3">
          <dl className="grid grid-cols-1 gap-x-6 gap-y-1 text-xs sm:grid-cols-2">
            <Fact label={ui("Period")} value={journal.period} />
            <Fact label={ui("Reference")} value={journal.reference} />
            <Fact label={ui("Raised by")} value={journal.raised_by} />
            <Fact label={ui("Submitted by")} value={journal.submitted_by} />
            <Fact label={ui("Posted by")} value={journal.posted_by} />
            <Fact label={ui("Reverses")} value={journal.reverses_number} />
            <Fact
              label={ui("Reversal")}
              value={
                journal.reversal
                  ? `${journal.reversal.journal_number ?? ""} ${ui(stateLabel(journal.reversal.state))}`.trim()
                  : null
              }
            />
          </dl>

          {journal.state === "returned" && journal.return_note ? (
            <p className="rounded-md border border-destructive/30 bg-destructive/5 p-3 text-xs">
              <span className="font-medium">{ui("Sent back by")} </span>
              {journal.returned_by}: {journal.return_note}
            </p>
          ) : null}

          <Table
            columns={[
              ui("Account"),
              ui("Description"),
              ui("Cost centre"),
              ui("Debit"),
              ui("Credit"),
            ]}
          >
            {journal.lines.map((l) => {
              const centre = l.dimensions?.[COST_CENTRE];
              return (
                <tr key={l.line_no} className="border-b border-border/60 last:border-0">
                  <td className="py-1.5 pr-4 font-mono text-xs">
                    {l.account_code}{" "}
                    <span className="font-sans text-muted-foreground">{l.account_name}</span>
                  </td>
                  <td className="py-1.5 pr-4">{l.description ?? "—"}</td>
                  <td className="py-1.5 pr-4 text-xs">
                    {typeof centre === "string" ? centre : "—"}
                  </td>
                  <td className="py-1.5 pr-4 text-right tabular-nums">
                    {l.debit_minor ? money(l.debit_minor) : ""}
                  </td>
                  <td className="py-1.5 pr-4 text-right tabular-nums">
                    {l.credit_minor ? money(l.credit_minor) : ""}
                  </td>
                </tr>
              );
            })}
          </Table>

          <div className="flex flex-wrap items-center gap-2">
            {isDraft && journal.raised_here && mayRaise ? (
              <>
                <ActionButton
                  busy={busy}
                  onClick={() => submit.mutate({ p_journal_id: journal.journal_id })}
                >
                  {ui("Submit for approval")}
                </ActionButton>
                {journal.reverses_journal_id === null ? (
                  <ActionButton variant="secondary" onClick={onChange}>
                    {ui("Change")}
                  </ActionButton>
                ) : null}
                <ActionButton
                  variant="secondary"
                  busy={busy}
                  onClick={() => discard.mutate({ p_journal_id: journal.journal_id })}
                >
                  {ui("Discard")}
                </ActionButton>
              </>
            ) : null}

            {journal.state === "submitted" && mayApprove ? (
              <>
                {journal.you_may_approve ? (
                  <ActionButton
                    busy={busy}
                    onClick={() => approve.mutate({ p_journal_id: journal.journal_id })}
                  >
                    {ui("Approve and post")}
                  </ActionButton>
                ) : (
                  <span className="text-xs text-muted-foreground">
                    {ui("You raised or submitted this journal, so somebody else approves it.")}
                  </span>
                )}
                <ActionDialog
                  trigger={
                    <button type="button" className={SECONDARY}>
                      {ui("Send back")}
                    </button>
                  }
                  title="Send the journal back"
                  description="It becomes a draft again, with your note beside it for whoever raised it."
                  permission="finance.close_period"
                  fn="erp_return_journal"
                  fields={[
                    {
                      kind: "text",
                      name: "p_note",
                      label: "What has to change",
                      required: true,
                      placeholder: "Wrong period: this belongs to August",
                      hint: "Whoever raised the journal reads this beside it.",
                    },
                  ]}
                  prefill={{ p_journal_id: journal.journal_id }}
                  context={context}
                  invalidates={INVALIDATES}
                  submitLabel="Send back"
                />
              </>
            ) : null}

            {journal.state === "posted" &&
            journal.raised_here &&
            journal.reverses_journal_id === null &&
            journal.reversal === null ? (
              <ActionDialog
                trigger={
                  <button type="button" className={SECONDARY}>
                    {ui("Reverse")}
                  </button>
                }
                title="Reverse the journal"
                description="Raises the mirror of every line for somebody else to approve. The journal itself is never changed."
                permission="finance.post"
                fn="erp_reverse_journal"
                fields={[
                  {
                    kind: "date",
                    name: "p_posting_date",
                    label: "Date of the reversal",
                    hint: "Today when left empty. It has to fall in an open period.",
                  },
                  {
                    kind: "text",
                    name: "p_reason",
                    label: "Why it is reversed",
                    required: true,
                    placeholder: "Accrued twice: the supplier's bill has arrived",
                    hint: "Kept with the reversal for whoever reviews the ledger.",
                  },
                ]}
                prefill={{ p_journal_id: journal.journal_id }}
                context={context}
                invalidates={INVALIDATES}
                submitLabel="Reverse"
              />
            ) : null}
          </div>

          <ErrorNote error={submit.error ?? discard.error ?? approve.error} />
        </div>
      ) : null}
    </li>
  );
}

function Fact({ label, value }: { label: string; value: string | null }) {
  if (!value) return null;
  return (
    <div className="flex min-w-0 gap-2">
      <dt className="text-muted-foreground">{label}</dt>
      <dd className="min-w-0 truncate">{value}</dd>
    </div>
  );
}

/**
 * A new journal, or a draft being changed.
 *
 * The currency list and the companies are loaded first, because an amount is
 * converted to minor units by its currency's own decimal places, and guessing
 * two for a currency with none writes a hundred times too much.
 */
function JournalEditor({ journal, onClose }: { journal: Journal | null; onClose: () => void }) {
  const { ui } = useT();
  const { currencies, error: currencyError } = useCurrencies();
  const entities = useQuery({
    queryKey: ["erp_entities", {}],
    queryFn: () => callErp<Entity[]>("erp_entities"),
  });

  if (currencyError || entities.error) {
    return (
      <section className="rounded-xl border border-border bg-card p-4 sm:p-5">
        <ErrorNote error={currencyError ?? entities.error} />
        <p className="mt-2 text-xs text-destructive">
          {ui(
            "The currency list could not be loaded, so an amount cannot be converted safely. Nothing has been submitted.",
          )}
        </p>
      </section>
    );
  }
  if (!currencies || !entities.data) {
    return (
      <p role="status" className="text-sm text-muted-foreground">
        Loading…
      </p>
    );
  }
  return (
    <JournalForm
      journal={journal}
      currencies={currencies}
      entities={entities.data}
      onClose={onClose}
    />
  );
}

function JournalForm({
  journal,
  currencies,
  entities,
  onClose,
}: {
  journal: Journal | null;
  currencies: Currency[];
  entities: Entity[];
  onClose: () => void;
}) {
  const { ui } = useT();
  const queryClient = useQueryClient();

  const [entityId, setEntityId] = useState(
    journal?.entity_id ?? (entities.length === 1 ? (entities[0]?.entity_id ?? "") : ""),
  );
  const [postingDate, setPostingDate] = useState(journal?.posting_date ?? today());
  const [reference, setReference] = useState(journal?.reference ?? "");
  const [narrative, setNarrative] = useState(journal?.narrative ?? "");
  const [tried, setTried] = useState(false);

  const currency =
    journal?.currency ?? entities.find((e) => e.entity_id === entityId)?.base_currency ?? "GBP";
  const minorUnits = minorUnitsOf(currencies, currency);
  const [lines, setLines] = useState<DraftLine[]>(() =>
    journal ? draftLinesOf(journal, minorUnits) : [emptyLine(), emptyLine()],
  );

  const accounts = useQuery({
    queryKey: ["erp_accounts", { p_postable_only: true }],
    queryFn: () => callErp<Account[]>("erp_accounts", { p_postable_only: true }),
  });
  const centres = useQuery({
    queryKey: ["erp_cost_centres", {}],
    queryFn: () => callErp<CostCentre[]>("erp_cost_centres"),
  });
  const companyAccounts = useMemo(
    () => (accounts.data ?? []).filter((a) => a.entity_id === entityId),
    [accounts.data, entityId],
  );
  const activeCentres = (centres.data ?? []).filter((c) => c.status === "active");

  const totals = journalTotals(lines, minorUnits);
  const headerComplete = entityId !== "" && postingDate !== "" && narrative.trim() !== "";
  const touched =
    reference !== (journal?.reference ?? "") ||
    narrative !== (journal?.narrative ?? "") ||
    lines.some((l) => !isBlankLine(l));
  useUnsavedGuard(touched);

  const save = useMutation({
    mutationFn: (submit: boolean) =>
      callErp<unknown>(DOORS.raise.fn, {
        p_entity_id: entityId,
        p_posting_date: postingDate,
        p_narrative: narrative.trim(),
        p_reference: reference.trim() === "" ? null : reference.trim(),
        p_lines: journalLinesArg(lines, minorUnits),
        p_journal_id: journal?.journal_id ?? null,
        p_submit: submit,
      }),
    onSuccess: (_result, submit) => {
      INVALIDATES.forEach((key) => queryClient.invalidateQueries({ queryKey: [key] }));
      toast(submit ? ui("Submitted for approval.") : ui("Saved as a draft."));
      onClose();
    },
  });

  function setLine(index: number, change: Partial<DraftLine>) {
    setLines((prev) => prev.map((l, i) => (i === index ? { ...l, ...change } : l)));
  }

  const money = (minor: number) => formatMinor(minor, currency, minorUnits);
  const field = `${TOUCH} w-full rounded-md border border-input bg-background px-2 text-sm`;
  const caption = "text-xs font-medium uppercase tracking-wide text-muted-foreground";

  return (
    <section
      aria-label={journal ? ui("Change the journal") : ui("New journal")}
      className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5"
    >
      <h2 className="text-sm font-semibold">
        {journal ? ui("Change the journal") : ui("New journal")}
      </h2>
      {journal?.return_note ? (
        <p className="mt-2 text-xs">
          <span className="font-medium">{ui("Sent back by")} </span>
          {journal.returned_by}: {journal.return_note}
        </p>
      ) : null}

      <div className="mt-4 grid grid-cols-1 gap-3 sm:grid-cols-2">
        <label className="flex min-w-0 flex-col gap-1 text-sm">
          <span className={caption}>{ui("Company")}</span>
          <select
            value={entityId}
            required
            onChange={(e) => setEntityId(e.target.value)}
            className={field}
          >
            <option value="">{ui("Choose…")}</option>
            {entities.map((e) => (
              <option key={e.entity_id} value={e.entity_id}>
                {e.code} — {e.name}
              </option>
            ))}
          </select>
        </label>
        <label className="flex min-w-0 flex-col gap-1 text-sm">
          <span className={caption}>{ui("Date")}</span>
          <input
            type="date"
            value={postingDate}
            required
            onChange={(e) => setPostingDate(e.target.value)}
            className={field}
          />
          <span className="text-xs text-muted-foreground">
            {ui("The day it posts on. It has to fall in an open period.")}
          </span>
        </label>
        <label className="flex min-w-0 flex-col gap-1 text-sm sm:col-span-2">
          <span className={caption}>{ui("Narrative")}</span>
          <input
            type="text"
            value={narrative}
            required
            placeholder="Accrue September electricity, bill not yet received"
            onChange={(e) => setNarrative(e.target.value)}
            className={field}
          />
          <span className="text-xs text-muted-foreground">
            {ui("Why the journal is posted. It is what somebody reviewing the ledger reads.")}
          </span>
        </label>
        <label className="flex min-w-0 flex-col gap-1 text-sm">
          <span className={caption}>{ui("Reference")}</span>
          <input
            type="text"
            value={reference}
            placeholder="ACC-ELEC-09"
            onChange={(e) => setReference(e.target.value)}
            className={field}
          />
          <span className="text-xs text-muted-foreground">
            {ui("Optional. Your own reference.")}
          </span>
        </label>
      </div>

      <div className="mt-5 flex flex-col gap-2">
        <span className={caption}>
          {ui("Lines")} ({currency})
        </span>
        {entityId === "" ? (
          <p className="text-xs text-muted-foreground">
            {ui("Choose the company first: each company keeps its own accounts.")}
          </p>
        ) : null}
        {lines.map((line, index) => {
          const problem = isBlankLine(line) ? null : lineAmounts(line, minorUnits).problem;
          return (
            <div
              key={index}
              className="flex flex-wrap items-end gap-2 rounded-md border border-border/60 p-2"
            >
              <label className="flex min-w-[12rem] flex-[2] flex-col gap-1 text-sm">
                <span className="text-[11px] uppercase tracking-wide text-muted-foreground">
                  {ui("Account")}
                </span>
                <select
                  value={line.account_id}
                  disabled={entityId === ""}
                  onChange={(e) => setLine(index, { account_id: e.target.value })}
                  className={`${field} disabled:opacity-60`}
                >
                  <option value="">{ui("Choose…")}</option>
                  {companyAccounts.map((a) => (
                    <option key={a.account_id} value={a.account_id}>
                      {a.code} — {a.name}
                    </option>
                  ))}
                </select>
              </label>
              <label className="flex min-w-[10rem] flex-[2] flex-col gap-1 text-sm">
                <span className="text-[11px] uppercase tracking-wide text-muted-foreground">
                  {ui("Description")}
                </span>
                <input
                  type="text"
                  value={line.description}
                  placeholder={ui("The narrative, unless you say otherwise")}
                  onChange={(e) => setLine(index, { description: e.target.value })}
                  className={field}
                />
              </label>
              {activeCentres.length > 0 ? (
                <label className="flex min-w-[8rem] flex-1 flex-col gap-1 text-sm">
                  <span className="text-[11px] uppercase tracking-wide text-muted-foreground">
                    {ui("Cost centre")}
                  </span>
                  <select
                    value={line.cost_centre}
                    onChange={(e) => setLine(index, { cost_centre: e.target.value })}
                    className={field}
                  >
                    <option value="">{ui("None")}</option>
                    {activeCentres.map((c) => (
                      <option key={c.code} value={c.code}>
                        {c.code} — {c.name}
                      </option>
                    ))}
                  </select>
                </label>
              ) : null}
              <label className="flex min-w-[7rem] flex-1 flex-col gap-1 text-sm">
                <span className="text-[11px] uppercase tracking-wide text-muted-foreground">
                  {ui("Debit")}
                </span>
                <input
                  type="number"
                  inputMode="decimal"
                  step="any"
                  min="0"
                  value={line.debit}
                  onChange={(e) => setLine(index, { debit: e.target.value })}
                  className={`${field} text-right tabular-nums`}
                />
              </label>
              <label className="flex min-w-[7rem] flex-1 flex-col gap-1 text-sm">
                <span className="text-[11px] uppercase tracking-wide text-muted-foreground">
                  {ui("Credit")}
                </span>
                <input
                  type="number"
                  inputMode="decimal"
                  step="any"
                  min="0"
                  value={line.credit}
                  onChange={(e) => setLine(index, { credit: e.target.value })}
                  className={`${field} text-right tabular-nums`}
                />
              </label>
              <ActionButton
                variant="secondary"
                onClick={() => setLines((prev) => prev.filter((_, i) => i !== index))}
              >
                {ui("Remove")}
              </ActionButton>
              {problem !== null && tried ? (
                <p role="alert" className="w-full text-xs text-destructive">
                  {ui(LINE_PROBLEM_TEXT[problem])}
                </p>
              ) : null}
            </div>
          );
        })}
        <div className="flex flex-wrap items-center justify-between gap-3">
          <ActionButton
            variant="secondary"
            onClick={() => setLines((prev) => [...prev, emptyLine()])}
          >
            {ui("Add a line")}
          </ActionButton>
          <div
            className="flex flex-wrap items-center gap-4 text-sm tabular-nums"
            aria-live="polite"
          >
            <span>
              <span className="text-muted-foreground">{ui("Debits")} </span>
              {money(totals.debit_minor)}
            </span>
            <span>
              <span className="text-muted-foreground">{ui("Credits")} </span>
              {money(totals.credit_minor)}
            </span>
            {totals.balanced ? (
              <Pill tone="ok">{ui("Balanced")}</Pill>
            ) : (
              <Pill tone="warn">
                {ui("Out by")} {money(Math.abs(totals.difference_minor))}
              </Pill>
            )}
          </div>
        </div>
        {!totals.balanced ? (
          <p className="text-xs text-muted-foreground">
            {ui(
              "Submit for approval waits until every line has an account and one amount, and the debits equal the credits.",
            )}
          </p>
        ) : null}
      </div>

      <ErrorNote error={save.error} />

      <div className="mt-4 flex flex-wrap justify-end gap-2">
        <ActionButton variant="secondary" onClick={onClose}>
          {ui("Cancel")}
        </ActionButton>
        <ActionButton
          variant="secondary"
          busy={save.isPending}
          disabled={!headerComplete || !totals.complete}
          onClick={() => {
            setTried(true);
            save.mutate(false);
          }}
        >
          {ui("Save as a draft")}
        </ActionButton>
        <ActionButton
          busy={save.isPending}
          disabled={!headerComplete || !totals.balanced}
          onClick={() => {
            setTried(true);
            save.mutate(true);
          }}
        >
          {ui("Submit for approval")}
        </ActionButton>
      </div>
      {!headerComplete || !totals.complete ? (
        <button
          type="button"
          onClick={() => setTried(true)}
          className="mt-2 text-xs text-muted-foreground underline underline-offset-2"
        >
          {ui("What is missing?")}
        </button>
      ) : null}
      {tried && !headerComplete ? (
        <p role="alert" className="mt-1 text-xs text-destructive">
          {ui("A journal needs its company, its date and a narrative.")}
        </p>
      ) : null}
    </section>
  );
}
