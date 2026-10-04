import { createFileRoute } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";

import { ActionButton, ActionDialog, ErrorNote, useErpAction } from "../../components/erp/action";
import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { Pill, Table } from "../../components/erp/panel";
import { useErpSession } from "../../components/erp/session-context";
import { callErp, hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import {
  checklistKeptOn,
  checkSaid,
  closePresses,
  closesWith,
  normaliseChecklist,
  taskPresses,
  type Checklist,
  type CloseTask,
} from "../../lib/period-close";

export const Route = createFileRoute("/finance/close")({
  head: () => ({
    meta: [
      { title: "Closing the month — Clove ERP" },
      {
        name: "description",
        content:
          "The period close in two presses: open it and every check runs, close it and every ledger of the month closes together.",
      },
      { property: "og:title", content: "Closing the month — Clove ERP" },
      {
        property: "og:description",
        content:
          "What has to be true before the books are closed, with the checks that cannot be ticked past.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <Close />
    </Gate>
  ),
});

const DONE = new Set(["complete", "waived"]);

/** The reads a press makes stale. */
const INVALIDATES = [
  "erp_close_checklist",
  "erp_close_status",
  "erp_close_tasks",
  "erp_fiscal_periods",
  "erp_book_ties",
];

/**
 * The close, as a person works it at month end: two presses (PR12 M5).
 *
 * Opening the close runs every task's check and completes each one that passes
 * (20260929200000); closing asks the checks again and closes the month on every
 * ledger that closes with it, GL and COMMIT together. What is left between the
 * two presses is a task whose check failed, shown with what the check said and
 * a waiver, or a task nothing checks. Each control is drawn only where
 * public.erp_close_checklist says its door would take it, for this reader
 * (src/lib/period-close.ts); the database refuses regardless.
 *
 * A month's checklist is raised once, on the ledger its close was opened from,
 * so COMMIT's month reads as GL's, and says so.
 *
 * This screen is the month being worked and nothing else. Any other month is
 * opened and closed from the Close step of the finance module page, which
 * lists every period, and any task is waived from that page's actions.
 */
function Close() {
  const { t, ui } = useT();
  const { session } = useErpSession();
  const can = (code: string) => hasPermission(session, code);

  const close = useQuery({
    queryKey: ["erp_close_checklist"],
    queryFn: async () => normaliseChecklist(await callErp<unknown>("erp_close_checklist", {})),
  });

  const open = useErpAction({ fn: "erp_open_period_close", invalidates: INVALIDATES });
  const shut = useErpAction({
    fn: "erp_close_period",
    invalidates: [...INVALIDATES, "erp_trial_balance"],
  });

  const data = close.data;
  const tasks = data?.tasks ?? [];
  const presses = data ? closePresses(data, can) : { open: null, close: false };
  const together = data ? closesWith(data) : [];
  const keptOn = data ? checklistKeptOn(data) : null;

  /**
   * The one sentence. Three of the five states say the same thing however the
   * organisation is set up, so they are said in words a tenant can rename; the
   * fourth names a task of theirs and comes from the database as it found it.
   */
  const blocking = (c: Checklist): string => {
    if (c.state === "closed") return ui("This period is closed.");
    if (c.state === "not_opened") return ui("The close has not been opened for this period yet.");
    if (c.state === "ready") {
      return c.failing_since_completed > 0
        ? ui("A check that passed when its task was completed fails now. Run the checks again.")
        : ui("Nothing is stopping the close.");
    }
    return c.blocking ?? "";
  };

  const periodId = data?.period?.fiscal_period_id ?? null;

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader
        title={t("nav.finance_close", "Closing the month")}
        howItWorks="Opening the close runs every task’s check and completes each one that passes; closing asks the checks again and closes the month on every ledger that closes with it. What fails is shown with what its check said, for you to fix or waive with a reason."
      >
        Two presses.
      </PageHeader>

      <section className="min-w-0 rounded-xl border border-border bg-card px-4 py-4 sm:px-5">
        {close.isPending ? (
          <p role="status" className="text-sm text-muted-foreground">
            {ui("Reading the close…")}
          </p>
        ) : !data?.period ? (
          <p className="text-sm text-muted-foreground">{data?.blocking ?? ""}</p>
        ) : (
          <>
            <p className="text-sm font-semibold">
              {data.period.ledger ? `${data.period.ledger} ` : ""}
              {data.period.code}
              <span className="ml-2 font-normal text-muted-foreground">
                {data.period.starts_on} – {data.period.ends_on}
              </span>
            </p>
            <p className="mt-1 text-sm text-muted-foreground">{blocking(data)}</p>
            {together.length > 0 ? (
              <p className="mt-1 text-xs text-muted-foreground" data-closes-with>
                {ui("Closes together with")} {together.join(", ")}
              </p>
            ) : null}
            {keptOn ? (
              <p className="mt-1 text-xs text-muted-foreground" data-checklist-on>
                {ui("The month's checklist is kept on")} {keptOn}
              </p>
            ) : null}

            {presses.open || presses.close ? (
              <div className="mt-3 flex flex-wrap gap-2" data-close-presses>
                {presses.open && periodId ? (
                  <ActionButton
                    variant={presses.open === "open" ? "primary" : "secondary"}
                    busy={open.isPending}
                    onClick={() => open.mutate({ p_fiscal_period_id: periodId })}
                  >
                    {presses.open === "open" ? ui("Open the close") : ui("Run the checks again")}
                  </ActionButton>
                ) : null}
                {presses.close && periodId ? (
                  <ActionButton
                    busy={shut.isPending}
                    onClick={() => shut.mutate({ p_fiscal_period_id: periodId })}
                  >
                    {ui("Close the period")}
                  </ActionButton>
                ) : null}
              </div>
            ) : null}
            <div className="mt-2 flex flex-col gap-2">
              <ErrorNote error={open.error} />
              <ErrorNote error={shut.error} />
            </div>
          </>
        )}
      </section>

      {data?.period ? (
        <section className="min-w-0 rounded-xl border border-border bg-card px-4 py-4 sm:px-5">
          {tasks.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              {ui("Nothing on this period's checklist yet.")}
            </p>
          ) : (
            <Table
              columns={[
                ui("Task"),
                ui("State"),
                ui("Who and when"),
                ui("What the check said"),
                ui("What can be done"),
              ]}
            >
              {tasks.map((task) => (
                <TaskRow key={task.code} task={task} can={can} context={data.period?.code ?? ""} />
              ))}
            </Table>
          )}
        </section>
      ) : null}
    </div>
  );
}

function TaskRow({
  task,
  can,
  context,
}: {
  task: CloseTask;
  can: (code: string) => boolean;
  context: string;
}) {
  const { ui } = useT();
  const complete = useErpAction({ fn: "erp_complete_close_task", invalidates: INVALIDATES });
  const presses = taskPresses(task, can);
  const said = checkSaid(task);

  const tone: "ok" | "warn" | "bad" | "muted" =
    task.status === "complete"
      ? "ok"
      : task.status === "waived"
        ? "warn"
        : task.status === "blocked" || task.check_passes === false
          ? "bad"
          : "muted";

  const label =
    task.status === "complete"
      ? ui("Complete")
      : task.status === "waived"
        ? ui("Waived")
        : task.status === "blocked"
          ? ui("Blocked")
          : task.check_passes === false
            ? ui("Check fails")
            : ui("Open");

  /** Who did it, or whose job it is while it is not done. */
  const who = (): string => {
    if (DONE.has(task.status) && task.completed_by) {
      return task.completed_at
        ? `${task.completed_by} · ${task.completed_at.slice(0, 10)}`
        : task.completed_by;
    }
    return task.owner_role_code ?? "—";
  };

  /** What is left, where no button says it. */
  const note = (): string | null => {
    if (DONE.has(task.status)) return task.status === "waived" ? task.waiver_reason : null;
    if (task.blocked_by) return `${ui("Waiting on")} ${task.blocked_by}`;
    if (task.check_passes === false && !task.is_waivable)
      return `${ui("Fix what the check names, then run the checks again")} · ${ui("Cannot be waived")}`;
    return null;
  };

  const left = note();

  return (
    <tr className="border-b border-border/60 align-top last:border-0" data-task={task.code}>
      <td className="py-2 pr-4 text-sm">{task.name}</td>
      <td className="py-2 pr-4">
        <Pill tone={tone}>{label}</Pill>
      </td>
      <td className="py-2 pr-4 text-xs text-muted-foreground">{who()}</td>
      <td
        className={`max-w-[28rem] break-words py-2 pr-4 text-xs ${said?.failed ? "text-destructive" : "text-muted-foreground"}`}
      >
        {said ? said.words : task.blocking_check ? "—" : ui("Nothing checks this task")}
      </td>
      <td className="py-2 pr-4 text-xs text-muted-foreground">
        <div className="flex flex-col gap-1.5">
          {presses.complete || presses.waive ? (
            <div className="flex flex-wrap gap-2">
              {presses.complete && task.task_id ? (
                <ActionButton
                  variant="secondary"
                  busy={complete.isPending}
                  ariaLabel={`${ui("Complete")} ${task.name}`}
                  onClick={() => complete.mutate({ p_task_id: task.task_id })}
                >
                  {ui("Complete")}
                </ActionButton>
              ) : null}
              {presses.waive && task.task_id ? (
                <ActionDialog
                  trigger={
                    <ActionButton variant="secondary" ariaLabel={`${ui("Waive")} ${task.name}`}>
                      {ui("Waive")}
                    </ActionButton>
                  }
                  title="Waive a close task"
                  description="The task is passed without its check, and the reason is kept with it for audit. Closing does not ask a waived task again."
                  permission="finance.close_period"
                  fn="erp_complete_close_task"
                  fields={[
                    {
                      kind: "text",
                      name: "p_waiver_reason",
                      label: "Why it is passed",
                      required: true,
                      placeholder: "Reviewed with the buyer: the difference is a price query",
                      hint: "Read at audit, beside what the check said.",
                    },
                  ]}
                  prefill={{ p_task_id: task.task_id }}
                  context={`${context} · ${task.name}`}
                  invalidates={INVALIDATES}
                  submitLabel="Waive"
                />
              ) : null}
            </div>
          ) : null}
          {left ? <span>{left}</span> : null}
          {!left && !presses.complete && !presses.waive ? <span>—</span> : null}
          <ErrorNote error={complete.error} />
        </div>
      </td>
    </tr>
  );
}
