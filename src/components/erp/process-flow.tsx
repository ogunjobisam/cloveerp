import { Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useMemo, useState } from "react";

import { callErp, hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { ActionButton, ActionDialog, ErrorNote } from "./action";
import type { ActionSpec } from "./actions-bar";
import { useErpSession } from "./session-context";
import { TOUCH } from "./page";

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
};

export type Stage = {
  label: string;
  hint: string;
  /** Lists documents of this type code, via public.erp_documents. */
  typeCode?: string;
  /** Any other read whose rows are what is sitting at this stage. */
  list?: StageList;
  /** Which argument the chosen record fills on this stage's verbs. */
  recordArg?: string;
  /** The verb that moves the chosen record on, by function name. */
  actionFn?: string;
  /** Further verbs for the chosen record. */
  actionFns?: string[];
  /** A verb that needs no record — raising a new one, mostly. */
  createFn?: string;
  /** Where the stage lives, when it lives on another screen. */
  to?: string;
  toLabel?: string;
};

export type FlowSpec = {
  title: string;
  note?: string;
  stages: Stage[];
};

/** How many rows a stage read may return. Beyond this the footer says so. */
const CAP = 200;
/** Rows per page in the left list. */
const PER_PAGE = 20;

type Row = Record<string, unknown>;

function sourceOf(stage: Stage): StageList | undefined {
  if (stage.list) return stage.list;
  if (stage.typeCode)
    return {
      fn: "erp_documents",
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

function useStageRows(stage: Stage) {
  const source = sourceOf(stage);

  const query = useQuery({
    queryKey: [source?.fn ?? "no-stage-list", source?.args ?? {}],
    queryFn: () =>
      source ? callErp<Row[]>(source.fn, source.args ?? {}) : Promise.resolve([] as Row[]),
    enabled: Boolean(source),
  });

  const rows = Array.isArray(query.data) ? query.data : [];
  return { source, rows, isPending: Boolean(source) && query.isPending, error: query.error };
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

/** One stage's verb, with the chosen record already answered. */
function StageAction({
  action,
  prefill,
  permitted,
  context,
}: {
  action: ActionSpec;
  prefill: Record<string, unknown>;
  permitted: boolean;
  context?: string;
}) {
  const { ui } = useT();

  if (!permitted)
    return (
      <ActionButton variant="secondary" disabled title="You do not hold the permission for this.">
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
      prefill={prefill}
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
  isPending,
  error,
  selectedId,
  onSelect,
}: {
  stage: Stage;
  rows: Row[];
  source: StageList | undefined;
  isPending: boolean;
  error: unknown;
  selectedId: string | null;
  onSelect: (id: string) => void;
}) {
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

  return (
    <div className="min-w-0">
      <div className="border-b border-border px-4 py-2 sm:px-5">
        <input
          type="search"
          value={search}
          onChange={(e) => {
            setSearch(e.target.value);
            setPage(0);
          }}
          aria-label={`Search ${source.nounPlural}`}
          placeholder={`Search ${source.nounPlural}…`}
          className="w-full min-w-0 rounded-md border border-border bg-background px-2 py-1.5 text-xs outline-none focus-visible:border-accent focus-visible:ring-2 focus-visible:ring-accent/30"
        />
      </div>

      <div className="min-h-[12rem]">
        {isPending ? (
          <p role="status" className="px-4 py-4 text-sm text-muted-foreground sm:px-5">
            Loading…
          </p>
        ) : error ? (
          <div className="px-4 py-4 sm:px-5">
            <ErrorNote error={error} />
          </div>
        ) : shown.length === 0 ? (
          <p className="px-4 py-4 text-sm text-muted-foreground sm:px-5">
            {rows.length === 0
              ? `No ${source.nounPlural} at ${stage.label.toLowerCase()} yet.`
              : `No ${source.nounPlural} match that search.`}
          </p>
        ) : (
          <ul>
            {shown.map((row) => {
              const id = String(row[source.id] ?? "");
              const open = id === selectedId;
              return (
                <li key={id}>
                  <button
                    type="button"
                    onClick={() => onSelect(id)}
                    aria-current={open ? "true" : undefined}
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
          {rows.length >= CAP ? ` — the first ${CAP}. Search to reach the rest.` : ""}
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

function StageRecord({
  stage,
  source,
  row,
  recordActions,
  createAction,
}: {
  stage: Stage;
  source: StageList | undefined;
  row: Row | null;
  recordActions: ActionSpec[];
  createAction: ActionSpec | undefined;
}) {
  const { ui } = useT();
  const { session } = useErpSession();
  const permitted = (a: ActionSpec) => !a.permission || hasPermission(session, a.permission);
  const id = row && source ? String(row[source.id] ?? "") : "";
  const prefill: Record<string, unknown> =
    stage.recordArg && id ? { [stage.recordArg]: id } : ({} as Record<string, unknown>);
  const summary =
    row && source
      ? [join(row, source.title), join(row, source.subtitle)].filter(Boolean).join(" · ")
      : undefined;

  return (
    <div className="min-w-0 px-4 py-4 sm:px-5">
      <h3 className="text-sm font-semibold">{ui(stage.label)}</h3>
      <p className="mt-0.5 text-xs text-muted-foreground">{ui(stage.hint)}</p>

      {row && source ? (
        <>
          <p className="mt-3 font-mono text-sm">{join(row, source.title)}</p>
          <dl className="mt-3 grid grid-cols-2 gap-x-4 gap-y-2 sm:grid-cols-3">
            {Object.entries(row)
              .filter(([k, v]) => k !== source.id && !k.endsWith("_id") && typeof v !== "object")
              .map(([k, v]) => (
                <div key={k} className="min-w-0">
                  <dt className="text-[11px] font-medium uppercase tracking-wide text-muted-foreground">
                    {k.replace(/_/g, " ")}
                  </dt>
                  <dd className="mt-0.5 truncate text-sm">
                    {v === null || v === undefined || v === "" ? "—" : String(v)}
                  </dd>
                </div>
              ))}
          </dl>
        </>
      ) : (
        <p className="mt-3 text-sm text-muted-foreground">
          {source
            ? `Choose a ${source.noun} on the left, and what you can do to it appears here.`
            : "Nothing to choose at this step."}
        </p>
      )}

      <div className="mt-4 flex flex-wrap gap-2">
        {row
          ? recordActions.map((a) => (
              <StageAction
                key={a.fn}
                action={a}
                prefill={prefill}
                permitted={permitted(a)}
                {...(summary ? { context: summary } : {})}
              />
            ))
          : null}
        {createAction ? (
          <StageAction
            action={createAction}
            prefill={{}}
            permitted={permitted(createAction)}
            context={`${ui(stage.label)} — ${ui(stage.hint)}`}
          />
        ) : null}
        {stage.to ? (
          <Link
            to={stage.to}
            className={`${TOUCH} inline-flex items-center justify-center rounded-md border border-input px-3 text-sm font-medium`}
          >
            {ui(stage.toLabel ?? "Open")}
          </Link>
        ) : null}
      </div>
    </div>
  );
}

/** The workbench for one chosen stage: its list on the left, its record on the right. */
function StageWorkbench({ stage, actions }: { stage: Stage; actions: ActionSpec[] }) {
  const { source, rows, isPending, error } = useStageRows(stage);
  const [selectedId, setSelectedId] = useState<string | null>(null);

  const byFn = new Map(actions.map((a) => [a.fn, a]));
  const names = [...(stage.actionFn ? [stage.actionFn] : []), ...(stage.actionFns ?? [])];
  const recordActions = names
    .map((fn) => byFn.get(fn))
    .filter((a): a is ActionSpec => Boolean(a))
    // A verb that needs no record is not a verb for the record on the right.
    .filter((a) => a.fn !== stage.createFn);
  const createAction = stage.createFn ? byFn.get(stage.createFn) : undefined;

  const row = source ? (rows.find((r) => String(r[source.id] ?? "") === selectedId) ?? null) : null;

  return (
    <div className="grid min-w-0 border-t border-border lg:grid-cols-[minmax(0,22rem)_minmax(0,1fr)]">
      <div className="min-w-0 border-b border-border lg:border-b-0 lg:border-r">
        <StageList
          stage={stage}
          rows={rows}
          source={source}
          isPending={isPending}
          error={error}
          selectedId={selectedId}
          onSelect={setSelectedId}
        />
      </div>
      <StageRecord
        stage={stage}
        source={source}
        row={row}
        recordActions={recordActions}
        {...(createAction ? { createAction } : { createAction: undefined })}
      />
    </div>
  );
}

function StageTab({
  stage,
  index,
  active,
  onSelect,
  disabled,
}: {
  stage: Stage;
  index: number;
  active: boolean;
  onSelect: () => void;
  disabled: boolean;
}) {
  const { ui } = useT();
  const { rows, isPending } = useStageRows(stage);
  const source = sourceOf(stage);
  const count =
    source && !isPending ? (rows.length >= CAP ? `${CAP}+` : String(rows.length)) : null;

  return (
    <li className="flex min-w-0 shrink-0 items-stretch gap-2">
      {index > 0 ? (
        <span aria-hidden="true" className="self-center text-muted-foreground">
          →
        </span>
      ) : null}
      <button
        type="button"
        onClick={onSelect}
        disabled={disabled}
        aria-pressed={active}
        className={`flex w-52 shrink-0 flex-col rounded-lg border p-3 text-left outline-none transition-colors focus-visible:ring-2 focus-visible:ring-accent/40 ${
          active
            ? "border-primary bg-background shadow-sm"
            : "border-border bg-background hover:bg-muted/60"
        } ${disabled ? "opacity-50" : ""}`}
      >
        <span className="flex items-baseline justify-between gap-2">
          <span className="truncate text-sm font-semibold">{ui(stage.label)}</span>
          {count !== null ? (
            <span className="shrink-0 rounded-full bg-muted px-1.5 py-0.5 text-[11px] tabular-nums text-muted-foreground">
              {count}
            </span>
          ) : null}
        </span>
        <span className="mt-1 line-clamp-3 text-xs text-muted-foreground">{ui(stage.hint)}</span>
      </button>
    </li>
  );
}

export function ProcessFlow({ flow, actions }: { flow: FlowSpec; actions: ActionSpec[] }) {
  const { ui } = useT();
  const { session } = useErpSession();
  const [chosen, setChosen] = useState(0);

  const byFn = new Map(actions.map((a) => [a.fn, a]));
  const allowed = (stage: Stage) => {
    const names = [
      ...(stage.actionFn ? [stage.actionFn] : []),
      ...(stage.actionFns ?? []),
      ...(stage.createFn ? [stage.createFn] : []),
    ];
    const specs = names.map((fn) => byFn.get(fn)).filter((a): a is ActionSpec => Boolean(a));
    if (specs.length === 0) return true;
    return specs.some((a) => !a.permission || hasPermission(session, a.permission));
  };

  const stage = flow.stages[Math.min(chosen, flow.stages.length - 1)];

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card">
      <div className="p-4 sm:p-5">
        <h2 className="text-sm font-semibold">{ui(flow.title)}</h2>
        {flow.note ? <p className="mt-0.5 text-xs text-muted-foreground">{ui(flow.note)}</p> : null}
        <p className="mt-0.5 text-xs text-muted-foreground">
          Press a step to see what is sitting there.
        </p>
        <div className="mt-3 overflow-x-auto pb-1">
          <ol className="flex items-stretch gap-2">
            {flow.stages.map((s, i) => (
              <StageTab
                key={s.label}
                stage={s}
                index={i}
                active={i === chosen}
                onSelect={() => setChosen(i)}
                disabled={!allowed(s)}
              />
            ))}
          </ol>
        </div>
      </div>

      {stage ? <StageWorkbench key={stage.label} stage={stage} actions={actions} /> : null}
    </section>
  );
}
