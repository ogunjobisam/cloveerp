import { Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useEffect, useId, useMemo, useRef, useState } from "react";

import { callErp, hasPermission } from "../../lib/erp";
import { actionKey, recordAnswer, stageActionKeys } from "../../lib/flow-actions";
import { prettifyField } from "../../lib/friendly";
import { useT } from "../../lib/i18n";
import { fill } from "../../lib/interview";
import { formatMinor, minorUnitsOf } from "../../lib/money";
import { article } from "../../lib/plain-words";
import {
  DOCUMENT_READ,
  describeLine,
  offerFor,
  rowsAtStage,
  stageEmptyState,
  stepsPerRow,
  settledAtStage,
  stageReadArgs,
  stateOf,
  summariseRecord,
  type DocumentLine,
  type Offer,
} from "../../lib/stage-records";
import { ActionButton, ActionDialog, ErrorNote } from "./action";
import type { ActionSpec } from "./actions-bar";
import { StatusPill } from "./auto";
import { useCurrencies } from "./currencies";
import { offersAnyTransition, useAvailableTransitions } from "./available-transitions";
import { DocumentTransitions } from "./document-transitions";
import { NewDocumentForType } from "./documents";
import { Pill } from "./panel";
import { useErpSession } from "./session-context";
import { LoadingRows, TOUCH } from "./page";

/**
 * The process, drawn — and then worked.
 *
 * Every ERP people are fond of draws the chain across the top of the screen —
 * requisition, order, receipt, bill, payment — and then, once you press a step,
 * gives you the records sitting at that step down the left and the record you
 * chose on the right. That is the shape here.
 *
 * A stage names the step, counts what is sitting there, and carries the verbs
 * that move work out of it. The verbs are the same declared `ActionSpec`s the
 * action bar renders, looked up by function name, so there is one definition of
 * each action; a stage only chooses where it appears and which argument the
 * record on the right already answers.
 */

/** Where a stage's records come from, when they are not documents. */
export type StageList = {
  fn: string;
  args?: Record<string, unknown>;
  /** The key holding the record's identifier. */
  id: string;
  /** Keys joined to make the row's first line. */
  title: string[];
  /** Keys joined to make the row's second line. */
  subtitle?: string[];
  /** A key rendered as the state pill. */
  status?: string;
  /** What one of these is called, in the empty state and the footer. */
  noun: string;
  nounPlural: string;
  /**
   * The order the rows are worked in, and any the step holds back until
   * "Show finished" is ticked. The door lists accounting periods newest
   * first, a year ahead; the Close step opens on the current one.
   */
  arrange?: (rows: Row[], showFinished: boolean) => Row[];
};

export type Stage = {
  label: string;
  hint: string;
  /** Lists documents of this type code, via public.erp_documents. */
  typeCode?: string;
  /**
   * The states a record is in while it waits at this step, by code.
   *
   * A step without them listed every record of its kind: "Requisition" and
   * "Approval" showed the same twenty-six requisitions, most of them already
   * ordered. A document step asks the database for these states; any other
   * step narrows its read by the row's status. The count on the step counts
   * the same rows, and "Show finished" brings back the ones that are done.
   */
  states?: string[];
  /** The words on the history toggle, where "Show finished" is not all it brings back. */
  showFinishedLabel?: string;
  /**
   * The states a verb that is not a transition is offered in, keyed as the
   * verb is named. Converting applies to an approved requisition and billing
   * to a posted receipt; offering either on anything else is offering a
   * refusal.
   */
  actionStates?: Record<string, string[]>;
  /**
   * Which side of the trade this step's documents name, when one may be raised
   * here: `customer`, `provider`, and so on. Raising happens on this step, on
   * one screen — header and lines together — rather than on the list screen.
   */
  partyRole?: string;
  /** Any other read whose rows are what is sitting at this stage. */
  list?: StageList;
  /** Which argument the chosen record fills on this stage's verbs. */
  recordArg?: string;
  /**
   * Verbs that arrive holding the chosen record instead of hiding the question,
   * keyed as the verb is named and valued by the argument it fills.
   *
   * `recordArg` answers a verb and takes its question away. A verb here is
   * answered and still asked: the picker opens on this record, and somebody
   * receiving against a different order can say so. See `recordAnswer`.
   */
  carriedArgs?: Record<string, string>;
  /** The verb that moves the chosen record on, by function name. */
  actionFn?: string;
  /** Further verbs for the chosen record. */
  actionFns?: string[];
  /** A verb that needs no record — raising a new one, mostly. */
  createFn?: string;
  /**
   * Which step puts work here, said when the step is empty.
   *
   * An empty step that only says "none yet" reads as a fault. Naming the step
   * before it — "work appears here once goods are received into goods-in" —
   * keeps the chain readable when a link of it is bare.
   */
  fedBy?: string;

  /** Where the stage lives, when it lives on another screen. */
  to?: string;
  toLabel?: string;
};

export type FlowSpec = {
  /**
   * The cycle's own name, which does not change when its title is reworded.
   *
   * A step budget is declared against this code in erp_meta.flow_budget, and
   * the build counts the verbs below and holds the two to each other. Keying
   * on the title instead would mean a rewording silently detached a cycle from
   * its budget, which is the way a budget stops being enforced without anybody
   * deciding that it should.
   */
  code: string;
  title: string;
  note?: string;
  stages: Stage[];
};

/**
 * The step after this one, and the way to it.
 *
 * A record whose step has nothing left to do for it has not stopped — it has
 * moved on. The panel names where to, and the button puts the reader there,
 * because "Nothing on this step applies" on its own reads as a fault rather
 * than as progress.
 */
type NextStep = { label: string; go: () => void };

/** How many rows a stage read may return. Beyond this the footer says so. */
const CAP = 200;
/** Rows per page in the left list. */
const PER_PAGE = 20;
/** Lines of a document shown beside it before the reader is sent to the document. */
const LINES_SHOWN = 5;

type Row = Record<string, unknown>;

function sourceOf(stage: Stage): StageList | undefined {
  if (stage.list) return stage.list;
  if (stage.typeCode)
    return {
      fn: DOCUMENT_READ,
      args: { p_type_code: stage.typeCode, p_limit: CAP },
      id: "document_id",
      title: ["document_number"],
      subtitle: ["document_date", "party"],
      status: "state_name",
      noun: "document",
      nounPlural: "documents",
    };
  return undefined;
}

/**
 * The rows sitting at a stage.
 *
 * The step's count and its list both come from here, so the number on the
 * step is the number of rows under it. `showFinished` adds the finished ones
 * for the list; the count never includes them.
 */
function useStageRows(stage: Stage, showFinished = false) {
  const source = sourceOf(stage);
  const args = source
    ? stageReadArgs(source.fn, source.args ?? {}, stage.states, showFinished)
    : {};

  const query = useQuery({
    queryKey: [source?.fn ?? "no-stage-list", args],
    queryFn: () => (source ? callErp<Row[]>(source.fn, args) : Promise.resolve([] as Row[])),
    enabled: Boolean(source),
  });

  const read = Array.isArray(query.data) ? query.data : [];
  const held = rowsAtStage(read, { states: stage.states, statusKey: source?.status }, showFinished);
  const rows = source?.arrange ? source.arrange(held, showFinished) : held;

  // Whether a step with nothing waiting on it has nothing at all, or has
  // everything it ever had, finished and out of the way.
  //
  // The Goods receipt step read 0 and said "No documents at goods receipt yet.
  // Receipts appear here once goods are received against a purchase order" —
  // while two posted receipts sat on the same screen, a tickbox away. The step
  // counts outstanding work and the sentence claimed non-existence, and the
  // sentence then told the reader to go and do the thing they had already done.
  //
  // The narrowed read cannot tell the two apart, because the door was asked for
  // the step's states and left the finished ones out. So when — and only when —
  // a step is empty, the type is read whole. It is the same read, under the
  // same key, that ticking the toggle performs, so the answer is already in
  // hand by the time anybody ticks it.
  const wholeArgs = source ? stageReadArgs(source.fn, source.args ?? {}, stage.states, true) : {};
  const wholeQuery = useQuery({
    queryKey: [source?.fn ?? "no-stage-list", wholeArgs],
    queryFn: () => (source ? callErp<Row[]>(source.fn, wholeArgs) : Promise.resolve([] as Row[])),
    enabled:
      Boolean(source) &&
      !showFinished &&
      Boolean(stage.states && stage.states.length > 0) &&
      !query.isPending &&
      !query.error &&
      rows.length === 0,
  });

  const whole = Array.isArray(wholeQuery.data) ? wholeQuery.data : [];
  const finished = rowsAtStage(
    whole,
    { states: stage.states, statusKey: source?.status },
    true,
  ).length;

  return {
    source,
    rows,
    capped: read.length >= CAP,
    isPending: Boolean(source) && query.isPending,
    error: query.error,
    /** How many finished records a step holds, counted only when it is empty. */
    finished: rows.length === 0 ? finished : 0,
    /** Whether that count has been taken yet, so "nothing here" is not said too soon. */
    countingFinished: wholeQuery.isFetching,
  };
}

function join(row: Row, keys: string[] | undefined): string {
  if (!keys) return "";
  return keys
    .map((k) => row[k])
    .filter((x) => x !== null && x !== undefined && x !== "")
    .map((x) => String(x))
    .join(" — ");
}

function haystack(row: Row): string {
  return Object.values(row)
    .filter((v) => typeof v === "string" || typeof v === "number")
    .map((v) => String(v).toLowerCase())
    .join(" ");
}

/**
 * A record that has already been worked.
 *
 * A task marked done, a document posted or cancelled, is finished: offering the
 * verb that finished it again is an invitation to an error the database will
 * refuse anyway. The verb is greyed instead, and says why. Which words mean
 * finished, and the exception for a record in its own step's states, are in
 * `settledAtStage`; these are the verbs that stay open on a finished record —
 * reading, correcting, reversing.
 */
const STILL_ALLOWED =
  /edit|amend|correct|update|change|view|open|print|note|comment|reopen|revers/i;

function actionStaysOpen(action: ActionSpec): boolean {
  return STILL_ALLOWED.test(`${action.code ?? ""} ${action.fn} ${action.label}`);
}

/** One stage's verb, with the chosen record already answered. */
function StageAction({
  action,
  prefill,
  preselect,
  permitted,
  context,
  settled,
}: {
  action: ActionSpec;
  prefill: Record<string, unknown>;
  preselect?: Record<string, string>;
  permitted: boolean;
  context?: string;
  settled?: string | null;
}) {
  const { ui } = useT();

  if (!permitted)
    return (
      <ActionButton variant="secondary" disabled title="You do not hold the permission for this.">
        {ui(action.label)}
      </ActionButton>
    );

  if (settled)
    return (
      <ActionButton
        variant="secondary"
        disabled
        title={`This record is already ${prettifyField(settled).toLowerCase()}, so this cannot be done again.`}
      >
        {ui(action.label)}
      </ActionButton>
    );

  return (
    <ActionDialog
      trigger={<ActionButton variant="secondary">{ui(action.label)}</ActionButton>}
      title={action.title ?? action.label}
      {...(action.description ? { description: action.description } : {})}
      {...(action.permission ? { permission: action.permission } : {})}
      fn={action.fn}
      fields={action.fields ?? []}
      {...(action.mapArgs ? { mapArgs: action.mapArgs } : {})}
      {...(action.emptyNote ? { emptyNote: action.emptyNote } : {})}
      prefill={prefill}
      {...(preselect && Object.keys(preselect).length > 0 ? { preselect } : {})}
      {...(context ? { context } : {})}

      invalidates={action.invalidates ?? []}
      submitLabel={action.submitLabel ?? action.label}
    />
  );
}

function StageList({
  stage,
  rows,
  source,
  capped,
  isPending,
  error,
  finished,
  countingFinished,
  selectedId,
  onSelect,
  showFinished,
  onShowFinished,
}: {
  stage: Stage;
  rows: Row[];
  source: StageList | undefined;
  capped: boolean;
  isPending: boolean;
  error: unknown;
  /** How many records this step holds that are already finished. */
  finished: number;
  /** Whether that count is still being taken. */
  countingFinished: boolean;
  selectedId: string | null;
  onSelect: (id: string) => void;
  showFinished: boolean;
  onShowFinished: (show: boolean) => void;
}) {
  const { ui } = useT();
  const finishedId = useId();
  const [search, setSearch] = useState("");
  const [page, setPage] = useState(0);

  const matches = useMemo(() => {
    const term = search.trim().toLowerCase();
    return term === "" ? rows : rows.filter((r) => haystack(r).includes(term));
  }, [rows, search]);

  const pages = Math.max(1, Math.ceil(matches.length / PER_PAGE));
  const current = Math.min(page, pages - 1);
  const shown = matches.slice(current * PER_PAGE, current * PER_PAGE + PER_PAGE);

  if (!source)
    return (
      <div className="px-4 py-6 text-sm text-muted-foreground sm:px-5">
        This step keeps no list of its own — its verb acts on what you choose inside it.
      </div>
    );

  /**
   * Why this step is showing nothing.
   *
   * Three reasons, and the step used to give one sentence for the first two.
   * "No documents at goods receipt yet. Receipts appear here once goods are
   * received against a purchase order" was shown over two posted receipts,
   * hidden by a tickbox — so it told the reader that nothing existed and then
   * instructed them to do the thing they had already done twice.
   *
   * A step counts outstanding work. Empty means the work is done at least as
   * often as it means the work has not started, and the two read nothing alike.
   */
  const emptyState = stageEmptyState({
    noun: source.noun,
    nounPlural: source.nounPlural,
    label: stage.label,
    fedBy: stage.fedBy,
    toggle: stage.showFinishedLabel ? ui(stage.showFinishedLabel) : ui("Show finished"),
    showing: shown.length,
    held: rows.length,
    finished,
    counting: countingFinished,
  });

  return (
    <div className="min-w-0">
      <div className="flex items-center gap-3 border-b border-border px-4 py-2 sm:px-5">
        <input
          type="search"
          value={search}
          onChange={(e) => {
            setSearch(e.target.value);
            setPage(0);
          }}
          aria-label={`Search ${source.nounPlural}`}
          placeholder={`Search ${source.nounPlural}…`}
          className="w-full min-w-0 flex-1 rounded-md border border-border bg-background px-2 py-1.5 text-xs outline-none focus-visible:border-accent focus-visible:ring-2 focus-visible:ring-accent/30"
        />
        {/* History, on request. The step lists what is waiting there; the
            finished ones are a press away rather than in the way. */}
        {stage.states && stage.states.length > 0 ? (
          <label
            htmlFor={finishedId}
            className="flex shrink-0 cursor-pointer items-center gap-1.5 text-xs text-muted-foreground"
          >
            {/* Named twice over — by the label it sits in and by the id the
                label points at — because a reader that walked the tree reported
                this box as "on", its value, and a checkbox named after its
                value is a checkbox nobody can find. */}
            <input
              id={finishedId}
              type="checkbox"
              checked={showFinished}
              onChange={(e) => {
                onShowFinished(e.target.checked);
                setPage(0);
              }}
            />
            {stage.showFinishedLabel ? ui(stage.showFinishedLabel) : ui("Show finished")}
          </label>
        ) : null}
      </div>

      <div className="min-h-[12rem]">
        {isPending ? (
          <LoadingRows rows={4} className="px-4 py-4 sm:px-5" />
        ) : error ? (
          <div className="px-4 py-4 sm:px-5">
            <ErrorNote error={error} />
          </div>
        ) : shown.length === 0 ? (
          <p className="px-4 py-4 text-sm text-muted-foreground sm:px-5">{emptyState}</p>
        ) : (
          <ul>
            {shown.map((row, index) => {
              const id = String(row[source.id] ?? "");
              const open = id === selectedId;
              // Never an empty name. The row's title comes from the read, and a
              // row the read gave no title to was a button a screen reader
              // announced as nothing at all.
              const title = join(row, source.title);
              const rowName =
                [title, join(row, source.subtitle)].filter(Boolean).join(", ") ||
                `${source.noun} ${index + 1 + current * PER_PAGE}`;
              return (
                <li key={id}>
                  <button
                    type="button"
                    onClick={() => onSelect(id)}
                    aria-current={open ? "true" : undefined}
                    aria-label={rowName}
                    className={`w-full border-b border-border/50 px-4 py-2 text-left outline-none last:border-0 hover:bg-muted/60 focus-visible:bg-muted focus-visible:ring-2 focus-visible:ring-accent/40 sm:px-5 ${
                      open ? "bg-muted" : ""
                    }`}
                  >
                    <span className="flex items-baseline justify-between gap-2">
                      <span className="truncate font-mono text-xs">{join(row, source.title)}</span>
                      {source.status && row[source.status] ? (
                        <span className="shrink-0 rounded-full bg-muted px-1.5 py-0.5 text-[11px] text-muted-foreground">
                          {String(row[source.status])}
                        </span>
                      ) : null}
                    </span>
                    {source.subtitle ? (
                      <span className="mt-0.5 block truncate text-xs text-muted-foreground">
                        {join(row, source.subtitle) || "—"}
                      </span>
                    ) : null}
                  </button>
                </li>
              );
            })}
          </ul>
        )}
      </div>

      <div className="flex items-center justify-between gap-2 border-t border-border px-4 py-2 text-[11px] text-muted-foreground sm:px-5">
        <span>
          {matches.length} {matches.length === 1 ? source.noun : source.nounPlural}
          {capped ? ` — the first ${CAP}. Search to reach the rest.` : ""}
        </span>
        <span className="flex shrink-0 items-center gap-1">
          <button
            type="button"
            onClick={() => setPage(Math.max(0, current - 1))}
            disabled={current === 0}
            aria-label="Previous page"
            className="rounded-md border border-input px-2 py-0.5 disabled:opacity-40"
          >
            ←
          </button>
          <span className="tabular-nums">
            Page {current + 1} of {pages}
          </span>
          <button
            type="button"
            onClick={() => setPage(Math.min(pages - 1, current + 1))}
            disabled={current >= pages - 1}
            aria-label="Next page"
            className="rounded-md border border-input px-2 py-0.5 disabled:opacity-40"
          >
            →
          </button>
        </span>
      </div>
    </div>
  );
}

/** What erp_document returns, as much of it as the record panel reads. */
type DocumentPayload = {
  lines: DocumentLine[];
};

/**
 * The chosen record, as a person reads it.
 *
 * It used to print the read's columns under their own names — STATE ordered,
 * TOTAL MINOR 317100, IS CANCELLED false — and every verb the step carries,
 * whatever state the record was in; and a draft purchase order offered nothing
 * that could move it on. Now a document shows its number and state, its
 * customer or supplier, its dates, its total as money and its first lines, and
 * links to its page. The step's verbs are offered only where the record's state
 * allows them (`offerFor`), and the document's other moves are offered beside
 * them as its own page offers them (`DocumentTransitions`).
 */
function StageRecord({
  stage,
  source,
  row,
  recordActions,
  createAction,
  next,
}: {
  stage: Stage;
  source: StageList | undefined;
  row: Row | null;
  recordActions: ActionSpec[];
  createAction: ActionSpec | undefined;
  next: NextStep | null;
}) {
  const { ui } = useT();
  const { session } = useErpSession();
  const { currencies } = useCurrencies();
  const permitted = (a: ActionSpec) => !a.permission || hasPermission(session, a.permission);
  const id = row && source ? String(row[source.id] ?? "") : "";
  const summary =
    row && source
      ? [join(row, source.title), join(row, source.subtitle)].filter(Boolean).join(" · ")
      : undefined;
  const state = stateOf(row, source?.status);
  const settled = settledAtStage(row, source?.status, stage.states);
  const isDocument = Boolean(row && source?.fn === DOCUMENT_READ && id);

  // The moves the document's current state has, read as its own page reads
  // them, and its lines. Both keyed by the state as well: a move made from
  // this panel changes the state the list reports, and what is offered must
  // follow it rather than wait for the next poll.
  const moves = useAvailableTransitions(id, { enabled: isDocument, state });
  const detail = useQuery({
    queryKey: ["erp_document", { p_document_id: id }, state],
    queryFn: () => callErp<DocumentPayload>("erp_document", { p_document_id: id }),
    enabled: isDocument,
  });
  const transitions = isDocument && Array.isArray(moves.data) ? moves.data : [];
  const available: string[] | null | undefined = !isDocument
    ? null
    : moves.isPending
      ? undefined
      : moves.error || !Array.isArray(moves.data)
        ? null
        : moves.data.map((t) => t.code);

  const minorUnits = (code: string) => minorUnitsOf(currencies, code);
  const fields = row && source ? summariseRecord(row, source, minorUnits, stage.partyRole) : [];
  const lines = isDocument ? (detail.data?.lines ?? []) : [];
  const currency = typeof row?.["currency"] === "string" ? row["currency"] : "GBP";

  const offers: { action: ActionSpec; offer: Offer }[] = row
    ? recordActions.map((action) => ({
        action,
        offer: offerFor({
          transition: action.transition,
          offeredIn: stage.actionStates?.[actionKey(action)],
          state,
          stageStates: stage.states,
          available,
          settled: settled !== null,
          staysOpen: actionStaysOpen(action),
        }),
      }))
    : [];
  const offered = offers.filter((o) => o.offer === "offer" || o.offer === "settled");
  // A move a step verb makes is offered by that verb, under the step's words,
  // and not a second time as the lifecycle's bare move.
  const coveredMoves = recordActions.flatMap((a) => (a.transition ? [a.transition] : []));
  const documentType = typeof row?.["document_type"] === "string" ? row["document_type"] : null;
  const movesOffered = offersAnyTransition(documentType, transitions, coveredMoves);
  const nothingApplies =
    row !== null &&
    offers.length > 0 &&
    offers.every((o) => o.offer === "hide") &&
    !movesOffered &&
    !(isDocument && moves.isPending);

  return (
    <div className="min-w-0 px-4 py-4 sm:px-5">
      <h3 className="text-sm font-semibold">{ui(stage.label)}</h3>
      <p className="mt-0.5 text-xs text-muted-foreground">{ui(stage.hint)}</p>

      {row && source ? (
        <>
          <p className="mt-3 flex flex-wrap items-center gap-2 font-mono text-sm">
            <span className="truncate">{join(row, source.title)}</span>
            {source.fn === DOCUMENT_READ ? (
              <span className="font-sans">
                <Pill tone={row["is_committed"] === true ? "ok" : "muted"}>
                  {String(row["state_name"] ?? row["state"] ?? "—")}
                </Pill>
              </span>
            ) : source.status && row[source.status] ? (
              <span className="font-sans">
                <StatusPill value={row[source.status]} />
              </span>
            ) : null}
            {settled ? (
              <span className="shrink-0 rounded-full bg-muted px-2 py-0.5 font-sans text-[11px] font-medium text-muted-foreground">
                Already {prettifyField(settled).toLowerCase()}
              </span>
            ) : null}
          </p>
          {fields.length > 0 ? (
            <dl className="mt-3 grid grid-cols-2 gap-x-4 gap-y-2 sm:grid-cols-3">
              {fields.map((f) => (
                <div key={f.key} className="min-w-0">
                  <dt className="text-[11px] font-medium text-muted-foreground">{ui(f.label)}</dt>
                  <dd
                    className={`mt-0.5 truncate text-sm ${
                      f.kind === "money" || f.kind === "number" ? "tabular-nums" : ""
                    }`}
                  >
                    {f.kind === "flag" ? ui(f.value) : f.value}
                  </dd>
                </div>
              ))}
            </dl>
          ) : null}

          {lines.length > 0 ? (
            <div className="mt-3">
              <p className="text-[11px] font-medium text-muted-foreground">{ui("Lines")}</p>
              <ul className="mt-1 divide-y divide-border/60 rounded-md border border-border/60">
                {lines.slice(0, LINES_SHOWN).map((line) => (
                  <li
                    key={`${line.line_no}`}
                    className="flex items-baseline justify-between gap-3 px-2 py-1 text-xs"
                  >
                    <span className="min-w-0 truncate">{describeLine(line)}</span>
                    <span className="shrink-0 tabular-nums text-muted-foreground">
                      {line.quantity}
                      {line.net_minor !== null && line.net_minor !== undefined
                        ? ` · ${formatMinor(line.net_minor, currency, minorUnits(currency))}`
                        : ""}
                      {/* The tax the line was determined at, once the document
                          committed and determined it (20260916030000). A line
                          with none reads exactly as it did before. */}
                      {line.tax_minor
                        ? ` + ${formatMinor(line.tax_minor, currency, minorUnits(currency))} ${ui("Tax")}`
                        : ""}
                    </span>
                  </li>
                ))}
              </ul>
              {lines.length > LINES_SHOWN ? (
                <p className="mt-1 text-[11px] text-muted-foreground">
                  {ui("More lines are on the document.")}
                </p>
              ) : null}
            </div>
          ) : null}

          {isDocument ? (
            <DocumentTransitions
              documentId={id}
              documentType={documentType}
              transitions={transitions}
              committed={row["is_committed"] === true}
              exclude={coveredMoves}
              quiet
            />
          ) : null}

          {/* A step whose verbs are all spent is not a dead end: this record
              has been worked here and belongs to the step after this one. Say
              which, and put the way there beside the sentence. */}
          {nothingApplies ? (
            <p className="mt-3 text-xs text-muted-foreground">
              {ui("Nothing on this step applies to this record in its current state.")}
              {next ? ` ${fill(ui("The next step is {step}."), { step: ui(next.label) })}` : ""}
            </p>
          ) : null}
        </>
      ) : (
        <p className="mt-3 text-sm text-muted-foreground">
          {source
            ? `Choose ${article(source.noun)} ${source.noun} on the left, and what you can do to it appears here.`
            : "Nothing to choose at this step."}
        </p>
      )}

      <div className="mt-4 flex flex-wrap gap-2">
        {offered.map(({ action, offer }) => {
          const answer = recordAnswer(stage, action, id);
          const carried = Object.keys(answer.preselect).length > 0;
          return (
            <StageAction
              // Keyed by the record as well, so a form that arrives holding the
              // chosen one starts again when a different one is chosen.
              key={`${actionKey(action)}:${id}`}
              action={action}
              prefill={answer.prefill}
              preselect={answer.preselect}
              permitted={permitted(action)}
              settled={offer === "settled" ? settled : null}
              // A form that shows the record in its own picker does not need a
              // box above it saying the same thing.
              {...(summary && !carried ? { context: summary } : {})}
            />
          );
        })}
        {isDocument ? (
          <Link
            to="/documents/$documentId"
            params={{ documentId: id }}
            className={`${TOUCH} inline-flex items-center justify-center rounded-md border border-input px-3 text-sm font-medium`}
          >
            {ui("Open the document")}
          </Link>
        ) : null}
        {stage.typeCode ? (
          <NewDocumentForType
            typeCode={stage.typeCode}
            {...(stage.partyRole ? { partyRole: stage.partyRole } : {})}
            label={`New ${ui(stage.label).toLowerCase()}`}
          />
        ) : null}
        {createAction ? (
          // No record is chosen, so the form acts on nothing yet: no "Acting
          // on" box repeating the step's description, and no second line on
          // the toast saying it again.
          <StageAction action={createAction} prefill={{}} permitted={permitted(createAction)} />
        ) : null}
        {stage.to ? (
          <Link
            to={stage.to}
            className={`${TOUCH} inline-flex items-center justify-center rounded-md border border-input px-3 text-sm font-medium`}
          >
            {ui(stage.toLabel ?? "Open")}
          </Link>
        ) : null}
        {nothingApplies && next ? (
          <button
            type="button"
            onClick={next.go}
            className={`${TOUCH} inline-flex items-center justify-center rounded-md border border-input px-3 text-sm font-medium`}
          >
            {fill(ui("Go to {step}"), { step: ui(next.label) })}
          </button>
        ) : null}
      </div>
    </div>
  );
}

/** The workbench for one chosen stage: its list on the left, its record on the right. */
function StageWorkbench({
  stage,
  actions,
  next,
}: {
  stage: Stage;
  actions: ActionSpec[];
  next: NextStep | null;
}) {
  const [showFinished, setShowFinished] = useState(false);
  const { source, rows, capped, isPending, error, finished, countingFinished } = useStageRows(
    stage,
    showFinished,
  );
  const [selectedId, setSelectedId] = useState<string | null>(null);

  const byFn = new Map(actions.map((a) => [actionKey(a), a]));
  const names = [...(stage.actionFn ? [stage.actionFn] : []), ...(stage.actionFns ?? [])];
  const recordActions = names
    .map((fn) => byFn.get(fn))
    .filter((a): a is ActionSpec => Boolean(a))
    // A verb that needs no record is not a verb for the record on the right.
    .filter((a) => actionKey(a) !== stage.createFn);
  const createAction = stage.createFn ? byFn.get(stage.createFn) : undefined;

  const row = source ? (rows.find((r) => String(r[source.id] ?? "") === selectedId) ?? null) : null;

  return (
    <div className="grid min-w-0 border-t border-border lg:grid-cols-[minmax(0,22rem)_minmax(0,1fr)]">
      <div className="min-w-0 border-b border-border lg:border-b-0 lg:border-r">
        <StageList
          stage={stage}
          rows={rows}
          source={source}
          capped={capped}
          isPending={isPending}
          error={error}
          finished={finished}
          countingFinished={countingFinished}
          selectedId={selectedId}
          onSelect={setSelectedId}
          showFinished={showFinished}
          onShowFinished={setShowFinished}
        />
      </div>
      <StageRecord
        stage={stage}
        source={source}
        row={row}
        recordActions={recordActions}
        next={next}
        {...(createAction ? { createAction } : { createAction: undefined })}
      />
    </div>
  );
}

/**
 * One step of the chain, drawn as an arrow pointing at the next one.
 *
 * The step used to be a card carrying its own hint, which made the strip three
 * lines tall and the chain hard to read as a chain. The hint now sits under the
 * strip for the step you are on — the only one it describes — and the arrows
 * say the rest.
 */
function StageTab({
  stage,
  index,
  total,
  active,
  onSelect,
  disabled,
}: {
  stage: Stage;
  index: number;
  /** How many steps the strip has, so a screen reader hears "step 3 of 8". */
  total: number;
  active: boolean;
  onSelect: () => void;
  disabled: boolean;
}) {
  const { ui } = useT();
  const hintId = useId();
  // The count is what is waiting at the step, never its history.
  const { source, rows, capped, isPending } = useStageRows(stage);
  const count = source && !isPending ? (capped ? `${rows.length}+` : String(rows.length)) : null;

  // The step's name as a screen reader says it. It used to be whatever the
  // button's text and title added up to, and the tree reported the whole hint,
  // cut mid-word — "Somebody asking for something, before anyone has committed
  // to buying it. Submitting it starts the ap" — so a person who could not see
  // the strip never heard the word Requisition. The hint is still there, as
  // the description, where it belongs.
  // Whole sentences, so a translation can put the words in its own order.
  const values = { step: ui(stage.label), n: index + 1, total, count: count ?? "0" };
  const name = !source
    ? fill(ui("{step}, step {n} of {total}, not counted here"), values)
    : isPending
      ? fill(ui("{step}, step {n} of {total}, still counting"), values)
      : fill(ui("{step}, step {n} of {total}, {count} outstanding"), values);

  return (
    <li className="min-w-0">
      <button
        type="button"
        onClick={onSelect}
        disabled={disabled}
        aria-pressed={active}
        aria-label={name}
        aria-describedby={hintId}
        title={ui(stage.hint)}
        className={[
          "flex h-full min-h-14 w-full min-w-0 items-center gap-2 pr-5 text-left transition-colors",
          index === 0 ? "step-chevron-first pl-4" : "step-chevron pl-7",
          active
            ? "bg-accent text-accent-foreground"
            : "bg-soft text-foreground hover:bg-muted-foreground/15",
          disabled ? "opacity-50" : "",
        ].join(" ")}
      >
        <span
          className={`grid size-6 shrink-0 place-items-center rounded-full text-[11px] font-semibold tabular-nums ${
            active ? "bg-accent-foreground/25" : "bg-card text-muted-foreground"
          }`}
        >
          {index + 1}
        </span>
        {/* Never cut. A step whose name reads "Purchas…" is a step nobody can
            choose with confidence; two lines is the price of saying it. */}
        <span className="line-clamp-2 min-w-0 flex-1 text-sm font-semibold leading-tight break-words">
          {ui(stage.label)}
        </span>
        {/* A badge on every step, or the strip reads as if the last step —
            Hand on, Payment, Pick — were missing something. A step that keeps
            no list of its own says so with a dash; one still counting shows
            the badge's shape rather than nothing. */}
        {source && isPending ? (
          <span
            aria-hidden="true"
            className="h-5 w-6 shrink-0 animate-pulse rounded-full bg-card"
          />
        ) : (
          <span
            aria-hidden="true"
            className={`shrink-0 rounded-full px-1.5 py-0.5 text-[11px] tabular-nums ${
              active ? "bg-accent-foreground/25" : "bg-card text-muted-foreground"
            }`}
          >
            {count ?? "—"}
          </span>
        )}
        <span id={hintId} className="sr-only">
          {ui(stage.hint)}
        </span>
      </button>
    </li>
  );
}

/** The narrowest a step may be and still say its name without cutting it. */
const STEP_MIN_REM = 10.5;

/**
 * How many steps fit on a row of the strip at the width it has now.
 *
 * Measured rather than left to the grid's auto-fill, because auto-fill packs a
 * row as full as it will go: eight steps with room for six come out six and
 * two. `stepsPerRow` evens them out. Until the first measurement every step is
 * on one row and squeezes rather than overflows, so nothing is ever off the
 * edge, even for the moment before the width is known.
 */
function useStepsPerRow(count: number) {
  const ref = useRef<HTMLDivElement | null>(null);
  const [perRow, setPerRow] = useState(count);

  useEffect(() => {
    const el = ref.current;
    if (!el || typeof ResizeObserver === "undefined") return;
    const measure = () => {
      const rem = Number.parseFloat(getComputedStyle(document.documentElement).fontSize) || 16;
      setPerRow(stepsPerRow(count, el.clientWidth / (STEP_MIN_REM * rem)));
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(el);
    return () => observer.disconnect();
  }, [count]);

  return { ref, perRow };
}

export function ProcessFlow({ flow, actions }: { flow: FlowSpec; actions: ActionSpec[] }) {
  const { ui } = useT();
  const { session } = useErpSession();
  const [chosen, setChosen] = useState(0);

  // Keyed the way the workbench keys them. Keyed by function alone, a step that
  // names a verb by its code found nothing, and a step with nothing is never
  // greyed.
  const byFn = new Map(actions.map((a) => [actionKey(a), a]));
  const allowed = (stage: Stage) => {
    const specs = stageActionKeys(stage)
      .map((fn) => byFn.get(fn))
      .filter((a): a is ActionSpec => Boolean(a));
    if (specs.length === 0) return true;
    return specs.some((a) => !a.permission || hasPermission(session, a.permission));
  };

  const { ref: stripRef, perRow } = useStepsPerRow(flow.stages.length);

  const at = Math.min(chosen, flow.stages.length - 1);
  const stage = flow.stages[at];
  // Where work goes from here. The last step of a chain has nowhere further to
  // point, and says so by pointing nowhere.
  const after = flow.stages[at + 1];
  const next: NextStep | null = after ? { label: after.label, go: () => setChosen(at + 1) } : null;

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card shadow-[var(--shadow-card)]">
      <div className="p-4 sm:p-5">
        <h2 className="text-sm font-semibold">{ui(flow.title)}</h2>
        {flow.note ? <p className="mt-0.5 text-xs text-muted-foreground">{ui(flow.note)}</p> : null}
        {/* Rows rather than an edge. Purchasing's eight steps ran off a
            1512px screen with the last one — Payment — out of sight and
            nothing to say it was there. Every step is now always on screen;
            when they do not fit side by side they wrap, evenly. */}
        <div ref={stripRef} className="mt-3">
          <ol
            className="grid items-stretch gap-1"
            style={{ gridTemplateColumns: `repeat(${perRow}, minmax(0, 1fr))` }}
          >
            {flow.stages.map((s, i) => (
              <StageTab
                key={s.label}
                stage={s}
                index={i}
                total={flow.stages.length}
                active={i === chosen}
                onSelect={() => setChosen(i)}
                disabled={!allowed(s)}
              />
            ))}
          </ol>
        </div>
        {stage ? <p className="mt-2 text-xs text-muted-foreground">{ui(stage.hint)}</p> : null}
      </div>

      {stage ? (
        <StageWorkbench key={stage.label} stage={stage} actions={actions} next={next} />
      ) : null}
    </section>
  );
}
