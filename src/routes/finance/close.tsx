import { createFileRoute } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";

import { ActionBar } from "../../components/erp/actions-bar";
import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { Pill, Table } from "../../components/erp/panel";
import { callErp } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { PERIOD_CLOSE_ACTIONS } from "../../lib/modules";

export const Route = createFileRoute("/finance/close")({
  head: () => ({
    meta: [
      { title: "Closing the month — Clove ERP" },
      {
        name: "description",
        content:
          "The period close checklist: every task, its state, who did it, and the one thing stopping the month from closing.",
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

/** Shaped by public.erp_close_checklist(). */
type Task = {
  code: string;
  name: string;
  seq: number;
  status: string;
  blocking_check: string | null;
  is_waivable: boolean;
  blocked_by: string | null;
  /** Null where the task carries no check at all — neither passing nor failing. */
  check_passes: boolean | null;
  completed_by: string | null;
  completed_at: string | null;
  waiver_reason: string | null;
  check_output: string | null;
  owner_role_code: string | null;
};

type Period = {
  fiscal_period_id: string;
  code: string;
  status: string;
  starts_on: string;
  ends_on: string;
  ledger: string;
};

type Checklist = {
  period: Period | null;
  tasks: Task[];
  state: "no_period" | "not_opened" | "in_progress" | "ready" | "closed";
  /** The database's own sentence, which names a task, so it is not renameable. */
  blocking: string | null;
  can_close: boolean;
  open_tasks: number;
  failing_checks: number;
};

const DONE = new Set(["complete", "waived"]);

/**
 * The close, as a person works it at month end.
 *
 * The checklist has been in the database since August and the reader for it
 * since the day after; nothing called either. A finance person could complete a
 * close task by picking its code out of a dropdown listing every period's
 * tasks, and could not see which period was closing, what was left, who had
 * done what, or what the close was waiting for.
 *
 * One screen, one question: what is stopping this month from closing. The
 * status line answers it in a sentence; the table says who is doing what; the
 * verbs are the three the close actually has. No summary tiles — every figure
 * one would carry is either the sentence above or a row below it.
 */
function Close() {
  const { t, ui } = useT();

  const close = useQuery({
    queryKey: ["erp_close_checklist"],
    queryFn: () => callErp<Checklist>("erp_close_checklist", {}),
  });

  const data = close.data;
  const tasks = data?.tasks ?? [];

  /**
   * The one sentence. Three of the five states say the same thing however the
   * organisation is set up, so they are said in words a tenant can rename; the
   * fourth names a task of theirs and comes from the database as it found it.
   */
  const blocking = (): string => {
    if (!data) return "";
    if (data.state === "closed") return ui("This period is closed.");
    if (data.state === "not_opened")
      return ui("The close has not been opened for this period yet.");
    if (data.state === "ready") return ui("Nothing is stopping the close.");
    return data.blocking ?? "";
  };

  const stateTone = (status: string): "ok" | "warn" | "bad" | "muted" =>
    status === "complete"
      ? "ok"
      : status === "waived"
        ? "warn"
        : status === "blocked"
          ? "bad"
          : "muted";

  const stateLabel = (status: string): string =>
    status === "complete"
      ? ui("Complete")
      : status === "waived"
        ? ui("Waived")
        : status === "blocked"
          ? ui("Blocked")
          : ui("Open");

  /** Who did it, or whose job it is while it is not done. */
  const who = (task: Task): string => {
    if (DONE.has(task.status) && task.completed_by) {
      return task.completed_at
        ? `${task.completed_by} · ${task.completed_at.slice(0, 10)}`
        : task.completed_by;
    }
    return task.owner_role_code ?? "—";
  };

  /** What the task is waiting for, said before anybody presses it. */
  const needed = (task: Task): string => {
    if (task.status === "waived") return task.waiver_reason ?? "—";
    if (DONE.has(task.status)) return "—";
    if (task.blocked_by) return `${ui("Waiting on")} ${task.blocked_by}`;
    if (task.check_passes === false) {
      return task.is_waivable
        ? ui("The check does not pass yet")
        : `${ui("The check does not pass yet")} · ${ui("Cannot be waived")}`;
    }
    return task.is_waivable ? "—" : ui("Cannot be waived");
  };

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={t("nav.finance_close", "Closing the month")}>
        What has to be true before this period&rsquo;s books are closed, and what is stopping it.
        Each task&rsquo;s check is run against the ledger as this screen is read, so a task that
        cannot be finished says so before anybody tries it.
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
              {data.period.code}
              <span className="ml-2 font-normal text-muted-foreground">
                {data.period.starts_on} – {data.period.ends_on}
              </span>
            </p>
            <p className="mt-1 text-sm text-muted-foreground">{blocking()}</p>
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
            <Table columns={[ui("Task"), ui("State"), ui("Who and when"), ui("What is needed")]}>
              {tasks.map((task) => (
                <tr key={task.code} className="border-b border-border/60 align-top last:border-0">
                  <td className="py-2 pr-4 text-sm">{task.name}</td>
                  <td className="py-2 pr-4">
                    <Pill tone={stateTone(task.status)}>{stateLabel(task.status)}</Pill>
                  </td>
                  <td className="py-2 pr-4 text-xs text-muted-foreground">{who(task)}</td>
                  <td className="py-2 pr-4 text-xs text-muted-foreground">{needed(task)}</td>
                </tr>
              ))}
            </Table>
          )}
        </section>
      ) : null}

      <ActionBar actions={[...PERIOD_CLOSE_ACTIONS]} title="Working the close" />
    </div>
  );
}
