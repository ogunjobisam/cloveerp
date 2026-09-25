import { useMutation, useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { type ReactNode, type RefObject, useId, useMemo, useRef, useState } from "react";
import { flushSync } from "react-dom";

import { ErpError, callErp, hasPermission } from "../../lib/erp";
import {
  actionsFor,
  groupBySheet,
  heldReason,
  inSite,
  normalise,
  splitWorklist,
  type CountTaskRow,
  type RenderedDocument,
} from "../../lib/count-worklist";
import { useT } from "../../lib/i18n";
import { ActionButton, ActionDialog, ErrorNote, useErpAction, type Field } from "./action";
import { CountSheetPrint } from "./count-sheet-print";
import { EmptyState, LoadingRows, Prose, TOUCH } from "./page";
import { Pill, Table } from "./panel";
import { useErpSession, useScope } from "./session-context";

/**
 * The counter's worklist (PR10 M3b, node I2).
 *
 * Since 20260927300000 a count inside its tolerance posts as it is recorded,
 * so the figure is the only decision a counter makes, and the screen used to
 * charge a dialog and a picker for it: open "Record a count", find the task
 * among two hundred by item, location and status, type the figure. Here every
 * place waiting to be counted is a row with a box and a Record button, in the
 * order of the paper — sheet by sheet, line by line — and Enter records the
 * figure and moves to the next place. One press per place.
 *
 * What does not simply wait for a counter goes in a second table (doctrine
 * rule 9: exceptions get a screen of their own): a count held for somebody to
 * post and why, one agreed by its approver, one outside its tolerance with
 * nobody to approve it, one refused, one with its approver. Each row carries
 * only the verbs its door accepts in that state, for somebody who holds what
 * the door asks (src/lib/count-worklist.ts, actionsFor). The database refuses
 * regardless; hiding a control is convenience.
 *
 * The site chosen in the header narrows the list here, on the screen, as the
 * balance panels below narrow theirs; the door's signature is unchanged
 * (20260927400000), so a client of either age works against a database of
 * either age.
 */

const INVALIDATES = [
  "erp_count_tasks",
  "erp_stock_audit",
  "erp_stock_audit_lines",
  "erp_count_accuracy",
  "erp_stock_health",
  "erp_stock_valuation",
];

/** Open work comes first from the door, so the cap bites history before work. */
const LIMIT = 500;

const RECORD = { fn: "erp_record_count", permission: "inventory.count" } as const;

const POST = { fn: "erp_post_count", permission: "inventory.adjust" } as const;
const RECOUNT = { fn: "erp_recount_task", permission: "inventory.adjust" } as const;
const DOOR = { fn: "erp_render_count_sheet", permission: "inventory.count" } as const;

/**
 * Render the sheet, draw it, then open the print dialog on it — once. A second
 * press while the first is rendering, or while its dialog is open, is ignored
 * rather than queued behind it as a second dialog.
 */
function usePrintCountSheet() {
  const [sheet, setSheet] = useState<RenderedDocument | null>(null);
  const busy = useRef(false);
  const [printing, setPrinting] = useState(false);

  function print() {
    if (busy.current) return;
    busy.current = true;
    setPrinting(true);
    try {
      window.print();
    } finally {
      busy.current = false;
      setPrinting(false);
    }
  }

  const render = useMutation({
    mutationFn: (documentId: string) =>
      callErp<RenderedDocument>(DOOR.fn, { p_document_id: documentId }),
    onSuccess: (rendered) => {
      // Drawn before the print dialog opens, or the paper is the last sheet.
      flushSync(() => setSheet(rendered));
      busy.current = false;
      print();
    },
    onError: () => {
      busy.current = false;
    },
  });

  function open(documentId: string) {
    if (busy.current || render.isPending) return;
    busy.current = true;
    render.mutate(documentId);
  }

  return {
    sheet,
    render,
    open,
    print,
    printing: printing || render.isPending,
    close: () => setSheet(null),
    permission: DOOR.permission,
  };
}

const qty = (n: number | null) =>
  n === null ? "—" : new Intl.NumberFormat(undefined, { maximumFractionDigits: 3 }).format(n);

const signed = (n: number | null) => {
  if (n === null) return "—";
  if (n === 0) return "0";
  return `${n > 0 ? "+" : ""}${qty(n)}`;
};

const CANCEL_FIELDS: Field[] = [
  {
    kind: "text",
    name: "p_reason",
    label: "Why the count is cancelled",
    required: true,
    placeholder: "The bay was emptied for a refit",
  },
];

/** Where a row is, for the name of each of its buttons: "Record A-01 P1". */
const placeOf = (row: CountTaskRow) => [row.location, row.item].filter(Boolean).join(" ");

function Place({ row }: { row: CountTaskRow }) {
  return <span className="sr-only"> {placeOf(row)}</span>;
}

/** A row's verb that asks nothing: Post, Count it again. */
function RowVerb({
  door,
  label,
  row,
  variant = "secondary",
}: {
  door: { fn: string; permission: string };
  label: string;
  row: CountTaskRow;
  variant?: "primary" | "secondary";
}) {
  const action = useErpAction({ fn: door.fn, invalidates: INVALIDATES });
  return (
    <span className="inline-flex flex-col gap-1">
      <ActionButton
        variant={variant}
        busy={action.isPending}
        onClick={() => action.mutate({ p_task_id: row.task_id })}
      >
        {label}
        <Place row={row} />
      </ActionButton>
      {action.error ? <ErrorNote error={action.error} /> : null}
    </span>
  );
}

const DANGER = `${TOUCH} inline-flex shrink-0 items-center justify-center rounded-md border border-destructive/40 px-4 text-sm font-medium text-destructive hover:bg-destructive/5`;

function Product({ row }: { row: CountTaskRow }) {
  return (
    <>
      <span className="font-mono text-xs">{row.item}</span>
      {row.item_name ? <span className="ml-2 text-muted-foreground">{row.item_name}</span> : null}
      {row.batch ? (
        <span className="ml-2 font-mono text-xs text-muted-foreground">{row.batch}</span>
      ) : null}
    </>
  );
}

/** Where a count stands, in a word or two. */
function StatePill({ row }: { row: CountTaskRow }) {
  const { ui } = useT();
  switch (row.status) {
    case "open":
      return <Pill tone="muted">{ui("To count")}</Pill>;
    case "posted":
      return (
        <Pill tone="ok">
          {row.posted_by_system ? ui("Posted as it was recorded") : ui("Posted")}
        </Pill>
      );
    case "approved":
      return row.post_held_reason ? (
        <Pill tone="warn">{ui("Held")}</Pill>
      ) : (
        <Pill tone="ok">{ui("Agreed")}</Pill>
      );
    case "pending_approval":
      return <Pill tone="warn">{ui("With its approver")}</Pill>;
    case "counted":
      return <Pill tone="bad">{ui("Outside its tolerance")}</Pill>;
    case "rejected":
      return <Pill tone="bad">{ui("Refused")}</Pill>;
    case "cancelled":
      return <Pill tone="muted">{ui("Cancelled")}</Pill>;
    default:
      return <Pill tone="muted">{row.status}</Pill>;
  }
}

/** Why an exception waits, in words; the database's own text where it adds something. */
function Why({ row }: { row: CountTaskRow }) {
  const { ui } = useT();
  const held = heldReason(row.post_held_reason);
  let words: string;
  if (row.status === "approved" && held) {
    switch (held.code) {
      case "held_by_policy":
        words = ui(
          "The site's count posting policy holds a count inside its tolerance for somebody to post.",
        );
        break;
      case "held_own_count":
        words = ui(
          "The site's count posting policy holds the counter's own count for somebody else to post.",
        );
        break;
      case "held_cumulative":
        words = ui(
          "Inside its tolerance on its own, but with what the system has already posted at this place it is outside it, so a person posts it.",
        );
        break;
      case "post_refused":
        words = ui(
          "It was to post as it was recorded, and the post was refused. The figure is kept for somebody to post.",
        );
        break;
      default:
        words = ui("Held for somebody to post.");
    }
  } else if (row.status === "approved") {
    words = ui("Agreed by its approver.");
  } else if (row.status === "counted") {
    words = ui("Outside its tolerance, with nobody to approve it. Count it again, or cancel it.");
  } else if (row.status === "pending_approval") {
    words = ui("Waiting for its approver.");
  } else if (row.status === "rejected") {
    words = ui("Refused by its approver.");
  } else {
    words = "";
  }
  return (
    <div className="flex max-w-md flex-col gap-1 text-xs">
      <span>{words}</span>
      {held?.detail ? (
        <span className="break-words font-mono text-[11px] text-muted-foreground">
          {held.detail}
        </span>
      ) : null}
    </div>
  );
}

/**
 * Cancel, with a reason. Its door asks inventory.count of an open count and
 * inventory.adjust of a counted or refused one, so there are two declarations,
 * each naming what it asks.
 */
function CancelCount({
  row,
  permission,
}: {
  row: CountTaskRow;
  permission: "inventory.count" | "inventory.adjust";
}) {
  const { ui } = useT();
  const trigger = (
    <button type="button" className={DANGER}>
      {ui("Cancel")}
      <Place row={row} />
    </button>
  );
  const context = [row.location, row.item, row.item_name].filter(Boolean).join(" · ");
  return permission === "inventory.count" ? (
    <ActionDialog
      trigger={trigger}
      title="Cancel the count"
      description="For a count nobody is going to finish: open, counted, or refused by its approver. Its place is released, and the next scheduled count is raised as usual."
      permission="inventory.count"
      fn="erp_cancel_count_task"
      fields={CANCEL_FIELDS}
      prefill={{ p_task_id: row.task_id }}
      context={context}
      invalidates={INVALIDATES}
      submitLabel="Cancel the count"
    />
  ) : (
    <ActionDialog
      trigger={trigger}
      title="Cancel the count"
      description="For a count nobody is going to finish: open, counted, or refused by its approver. Its place is released, and the next scheduled count is raised as usual."
      permission="inventory.adjust"
      fn="erp_cancel_count_task"
      fields={CANCEL_FIELDS}
      prefill={{ p_task_id: row.task_id }}
      context={context}
      invalidates={INVALIDATES}
      submitLabel="Cancel the count"
    />
  );
}

/** What became of a count recorded from this screen, beside the place. */
function Outcome({ row }: { row: CountTaskRow }) {
  const { ui } = useT();
  return (
    <span className="inline-flex flex-wrap items-center gap-2">
      <StatePill row={row} />
      {row.status === "posted" && row.adjustment_document_id ? (
        <Link
          to="/documents/$documentId"
          params={{ documentId: row.adjustment_document_id }}
          className="font-mono text-xs underline-offset-2 hover:underline"
        >
          {row.adjustment_number ?? ui("Stock adjustment")}
        </Link>
      ) : null}
    </span>
  );
}

function CountRow({
  row,
  draft,
  can,
  onDraft,
  onRecorded,
  register,
  onNext,
}: {
  row: CountTaskRow;
  draft: string;
  can: (code: string) => boolean;
  onDraft: (taskId: string, value: string) => void;
  onRecorded: (taskId: string) => void;
  register: (taskId: string, el: HTMLInputElement | null) => void;
  onNext: (taskId: string) => void;
}) {
  const { ui } = useT();
  const record = useErpAction({
    fn: RECORD.fn,
    invalidates: INVALIDATES,
    onDone: () => onRecorded(row.task_id),
  });
  const acts = actionsFor(row, can);
  const open = row.status === "open";
  const errorId = useId();

  /**
   * Sends the figure, if there is one. From the keyboard, the next place is
   * ready once this one is recorded, and not before: a refusal keeps the
   * counter on the place it refused, with the figure still in the box.
   */
  function submit(thenNext: boolean) {
    const typed = draft.trim();
    if (typed === "" || !Number.isFinite(Number(typed)) || record.isPending) return;
    record.mutate(
      { p_task_id: row.task_id, p_quantity: Number(typed) },
      thenNext ? { onSuccess: () => onNext(row.task_id) } : undefined,
    );
  }

  const place = placeOf(row);

  return (
    <>
      <tr
        data-task={row.task_id}
        className={record.error ? "" : "border-b border-border/60 last:border-0"}
      >
        <td className="py-2 pr-4 tabular-nums text-muted-foreground">{row.sheet_line_no ?? "—"}</td>
        <td className="py-2 pr-4 font-mono text-xs">{row.location ?? "—"}</td>
        <td className="py-2 pr-4">
          <Product row={row} />
        </td>
        <td className="py-2 pr-4 tabular-nums">{qty(row.expected)}</td>
        <td className="py-2 pr-4">
          {open && acts.record ? (
            <input
              ref={(el) => register(row.task_id, el)}
              type="number"
              inputMode="decimal"
              step="any"
              aria-label={`${ui("Counted")} ${place}`}
              value={draft}
              onChange={(e) => onDraft(row.task_id, e.target.value)}
              aria-invalid={record.error ? true : undefined}
              aria-describedby={record.error ? errorId : undefined}
              onKeyDown={(e) => {
                if (e.key !== "Enter") return;
                e.preventDefault();
                submit(true);
              }}
              className={`${TOUCH} w-28 rounded-md border border-input bg-background px-2 text-sm tabular-nums`}
            />
          ) : (
            <span className="tabular-nums">{qty(row.counted)}</span>
          )}
        </td>
        <td className="py-2 pr-4">
          <span className="inline-flex flex-wrap items-center gap-2">
            {open ? (
              acts.record ? (
                <ActionButton busy={record.isPending} onClick={() => submit(false)}>
                  {ui("Record")}
                  <Place row={row} />
                </ActionButton>
              ) : (
                <StatePill row={row} />
              )
            ) : (
              <Outcome row={row} />
            )}
            {acts.cancel === "inventory.count" ? (
              <CancelCount row={row} permission="inventory.count" />
            ) : null}
          </span>
        </td>
      </tr>
      {record.error ? (
        <tr className="border-b border-border/60 last:border-0">
          <td colSpan={6} className="pb-3" id={errorId}>
            <ErrorNote error={record.error} />
          </td>
        </tr>
      ) : null}
    </>
  );
}

function ExceptionRow({ row, can }: { row: CountTaskRow; can: (code: string) => boolean }) {
  const { ui } = useT();
  const acts = actionsFor(row, can);
  return (
    <tr data-task={row.task_id} className="border-b border-border/60 align-top last:border-0">
      <td className="py-2 pr-4 font-mono text-xs">{row.location ?? "—"}</td>
      <td className="py-2 pr-4">
        <Product row={row} />
        {row.document_number ? (
          <span className="block font-mono text-[11px] text-muted-foreground">
            {row.document_number}
            {row.sheet_line_no !== null ? ` / ${row.sheet_line_no}` : ""}
          </span>
        ) : null}
      </td>
      <td className="py-2 pr-4 tabular-nums">{qty(row.expected)}</td>
      <td className="py-2 pr-4 tabular-nums">{qty(row.counted)}</td>
      <td className="py-2 pr-4 tabular-nums">{signed(row.variance)}</td>
      <td className="py-2 pr-4">
        <StatePill row={row} />
      </td>
      <td className="py-2 pr-4">
        <Why row={row} />
      </td>
      <td className="py-2 pr-4">
        <span className="inline-flex flex-wrap items-start gap-2">
          {acts.post ? (
            <RowVerb door={POST} label={ui("Post")} row={row} variant="primary" />
          ) : null}
          {acts.postIsSomebodyElses ? (
            <span className="max-w-48 text-xs text-muted-foreground">
              {ui("You counted this, so somebody else posts it.")}
            </span>
          ) : null}
          {acts.recount ? <RowVerb door={RECOUNT} label={ui("Count it again")} row={row} /> : null}
          {acts.cancel === "inventory.adjust" ? (
            <CancelCount row={row} permission="inventory.adjust" />
          ) : null}
        </span>
      </td>
    </tr>
  );
}

function Card({
  title,
  description,
  headingRef,
  children,
}: {
  title: string;
  description: string;
  /** Somewhere for the keyboard to land when the list above it is done. */
  headingRef?: RefObject<HTMLHeadingElement | null>;
  children: ReactNode;
}) {
  return (
    <section className="min-w-0 rounded-xl border border-border bg-card print:hidden">
      <header className="border-b border-border px-4 py-4 sm:px-5">
        <h2
          ref={headingRef}
          tabIndex={headingRef ? -1 : undefined}
          className="text-sm font-semibold"
        >
          {title}
        </h2>
        <Prose className="mt-0.5 text-xs text-muted-foreground">{description}</Prose>
      </header>
      <div className="px-4 py-4 sm:px-5">{children}</div>
    </section>
  );
}

export function CountWorklist() {
  const { siteId } = useScope();
  const { session } = useErpSession();
  const { ui } = useT();
  const can = (code: string) => hasPermission(session, code);

  const query = useQuery({
    queryKey: ["erp_count_tasks", { p_limit: LIMIT }],
    queryFn: () => callErp<Record<string, unknown>[]>("erp_count_tasks", { p_limit: LIMIT }),
    refetchInterval: (q) => (q.state.error ? false : 30_000),
  });

  // What has been typed, by task, outside the query cache: the refetch every
  // thirty seconds must not wipe a half-typed column.
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  // The counts recorded from here since the screen opened, which stay on the
  // worklist saying what their figure did.
  const [recorded, setRecorded] = useState<ReadonlySet<string>>(() => new Set());
  const inputs = useRef(new Map<string, HTMLInputElement>());
  const waitingHeading = useRef<HTMLHeadingElement | null>(null);
  const print = usePrintCountSheet();

  const data = query.data;
  const listed = Array.isArray(data) ? data.length : 0;
  const rows = useMemo(
    () => inSite((Array.isArray(data) ? data : []).map(normalise), siteId),
    [data, siteId],
  );
  const { toCount, exceptions } = useMemo(() => splitWorklist(rows, recorded), [rows, recorded]);
  const groups = groupBySheet(toCount);
  const walk = toCount.filter((r) => r.status === "open").map((r) => r.task_id);
  // A figure typed for a count that has since moved on — posted or cancelled
  // by somebody else, or sent to its approver — is no longer the counter's
  // to send, and is dropped rather than carried to a box that is not there.
  const liveDrafts = useMemo(() => {
    const open = new Set(rows.filter((r) => r.status === "open").map((r) => r.task_id));
    return Object.fromEntries(Object.entries(drafts).filter(([id]) => open.has(id)));
  }, [drafts, rows]);

  const refused = query.error instanceof ErpError && query.error.isPermissionDenied;

  function state(body: () => ReactNode, empty: string) {
    if (query.isPending) return <LoadingRows />;
    if (refused)
      return (
        <p role="status" className="text-sm text-muted-foreground">
          This account does not hold the permission this panel needs, so there is nothing to show
          here.
        </p>
      );
    if (query.error) return <ErrorNote error={query.error} />;
    return body() ?? <EmptyState message={empty} />;
  }

  return (
    <>
      <Card
        title={ui("Counts to record")}
        description={ui(
          "Every place waiting to be counted, sheet by sheet in the order of the paper. Type what you found and press Enter: the figure is recorded and the next place is ready. A count inside its tolerance posts as it is recorded.",
        )}
      >
        {state(
          () =>
            groups.length === 0 ? null : (
              <div className="flex flex-col gap-6">
                {listed >= LIMIT ? (
                  <p role="status" className="text-xs text-muted-foreground">
                    {ui(
                      "Only the first 500 counts are listed, open work first. Counts past them are not shown here.",
                    )}
                  </p>
                ) : null}
                <ErrorNote error={print.render.error} />
                {groups.map((g) => {
                  const sheetId = g.document_id;
                  return (
                    <div
                      key={g.document_number ?? "no-sheet"}
                      data-sheet={g.document_number ?? ""}
                      className="flex flex-col gap-2"
                    >
                      <div className="flex flex-wrap items-center justify-between gap-2">
                        <h3 className="text-sm font-semibold">
                          {g.document_number ? (
                            <span className="font-mono">{g.document_number}</span>
                          ) : (
                            ui("No sheet")
                          )}
                        </h3>
                        {sheetId && can(print.permission) ? (
                          <ActionButton
                            variant="secondary"
                            busy={print.printing}
                            onClick={() => print.open(sheetId)}
                          >
                            {ui("Print the count sheet")}
                            <span className="sr-only"> {g.document_number}</span>
                          </ActionButton>
                        ) : null}
                      </div>
                      <Table
                        columns={[
                          ui("Line"),
                          ui("Location"),
                          ui("Product"),
                          ui("Expected"),
                          ui("Counted"),
                          ui("Record the count"),
                        ]}
                      >
                        {g.rows.map((r) => (
                          <CountRow
                            key={r.task_id}
                            row={r}
                            draft={liveDrafts[r.task_id] ?? ""}
                            can={can}
                            onDraft={(id, value) => setDrafts((d) => ({ ...d, [id]: value }))}
                            onRecorded={(id) => {
                              setDrafts((d) => {
                                const next = { ...d };
                                delete next[id];
                                return next;
                              });
                              setRecorded((s) => new Set(s).add(id));
                            }}
                            register={(id, el) => {
                              if (el) inputs.current.set(id, el);
                              else inputs.current.delete(id);
                            }}
                            onNext={(id) => {
                              // The next place, or, after the last, the counts
                              // that wait on somebody.
                              const next = walk[walk.indexOf(id) + 1];
                              const box = next ? inputs.current.get(next) : undefined;
                              if (box) box.focus();
                              else waitingHeading.current?.focus();
                            }}
                          />
                        ))}
                      </Table>
                    </div>
                  );
                })}
              </div>
            ),
          ui(
            "Nothing is waiting to be counted. Raise count tasks from a counting programme, and each place to count is listed here in the order of its sheet.",
          ),
        )}
      </Card>

      <Card
        title={ui("Counts that wait on somebody")}
        headingRef={waitingHeading}
        description={ui(
          "Counts that did not post as they were recorded: held for somebody to post, agreed by an approver, outside their tolerance, refused, or with their approver. Each says why, and offers only what can be done with it.",
        )}
      >
        {state(
          () =>
            exceptions.length === 0 ? null : (
              <Table
                columns={[
                  ui("Location"),
                  ui("Product"),
                  ui("Expected"),
                  ui("Counted"),
                  ui("Difference"),
                  ui("State"),
                  ui("Why"),
                  ui("What can be done"),
                ]}
              >
                {exceptions.map((r) => (
                  <ExceptionRow key={r.task_id} row={r} can={can} />
                ))}
              </Table>
            ),
          ui(
            "Nothing is waiting on anybody. Every count recorded has posted, or is still to be counted above.",
          ),
        )}
      </Card>

      {print.sheet ? (
        <CountSheetPrint
          sheet={print.sheet}
          onPrint={print.print}
          onClose={print.close}
          printing={print.printing}
        />
      ) : null}
    </>
  );
}
