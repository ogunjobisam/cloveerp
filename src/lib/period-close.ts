/**
 * The month's close, as data (PR12 M5).
 *
 * public.erp_close_checklist answers where a month's close stands
 * (20260929400000): the period, the periods of its other ledgers that close
 * with it, the checklist wherever it was raised, each task's check and what it
 * said, and what the doors would take from this reader. The close is two
 * presses (20260929200000): opening it runs every check and completes what
 * passes, closing it asks the checks again and shuts every ledger of the month.
 * What is left between the two is a task whose check failed, waived with a
 * reason, or a task nothing checks.
 *
 * Everything here is pure so that `bun test` can hold it. The verbs follow the
 * X4 rule: a control is drawn only where the database says its door would take
 * it, and only for somebody holding the permission it asks. The database
 * refuses regardless; this only keeps the screen from offering refusals.
 */

export type CloseState = "no_period" | "not_opened" | "in_progress" | "ready" | "closed";

export type CloseTask = {
  task_id: string | null;
  code: string;
  name: string;
  seq: number;
  status: string;
  blocking_check: string | null;
  is_waivable: boolean;
  blocked_by: string | null;
  /** Null where the task carries no check at all, neither passing nor failing. */
  check_passes: boolean | null;
  /** What the check says now, where it does not pass. */
  check_failure: string | null;
  completed_by: string | null;
  completed_at: string | null;
  waiver_reason: string | null;
  /** What the check said when the task was completed or waived. */
  check_output: string | null;
  owner_role_code: string | null;
  can_complete: boolean;
  can_waive: boolean;
};

export type ClosePeriod = {
  fiscal_period_id: string;
  code: string;
  status: string;
  starts_on: string;
  ends_on: string;
  ledger: string;
};

/** A period of another ledger of the same company and dates. */
export type Sibling = {
  fiscal_period_id: string;
  code: string;
  status: string;
  ledger: string;
};

export type Checklist = {
  period: ClosePeriod | null;
  tasks: CloseTask[];
  state: CloseState;
  /** The database's own sentence, which names a task, so it is not renameable. */
  blocking: string | null;
  can_open: boolean;
  can_close: boolean;
  open_tasks: number;
  failing_checks: number;
  /** Completed tasks whose check fails now: the close asks them again, and refuses. */
  failing_since_completed: number;
  siblings: Sibling[];
  /** Where the month's checklist is kept: this period, or the sibling it was opened from. */
  checklist_period: { fiscal_period_id: string; code: string; ledger: string } | null;
};

type Raw = Record<string, unknown>;

const record = (v: unknown): Raw | null =>
  typeof v === "object" && v !== null && !Array.isArray(v) ? (v as Raw) : null;

const text = (v: unknown): string | null =>
  typeof v === "string" && v !== "" ? v : typeof v === "number" ? String(v) : null;

const num = (v: unknown): number => {
  const n = typeof v === "number" ? v : typeof v === "string" ? Number(v) : NaN;
  return Number.isFinite(n) ? n : 0;
};

const bool = (v: unknown): boolean | null => (typeof v === "boolean" ? v : null);

const STATES: readonly CloseState[] = ["no_period", "not_opened", "in_progress", "ready", "closed"];

function task(raw: Raw): CloseTask {
  return {
    task_id: text(raw["task_id"]),
    code: text(raw["code"]) ?? "",
    name: text(raw["name"]) ?? text(raw["code"]) ?? "",
    seq: num(raw["seq"]),
    status: text(raw["status"]) ?? "open",
    blocking_check: text(raw["blocking_check"]),
    is_waivable: bool(raw["is_waivable"]) ?? false,
    blocked_by: text(raw["blocked_by"]),
    check_passes: bool(raw["check_passes"]),
    check_failure: text(raw["check_failure"]),
    completed_by: text(raw["completed_by"]),
    completed_at: text(raw["completed_at"]),
    waiver_reason: text(raw["waiver_reason"]),
    check_output: text(raw["check_output"]),
    owner_role_code: text(raw["owner_role_code"]),
    // A database older than 20260929400000 does not say, and nothing is drawn.
    can_complete: bool(raw["can_complete"]) ?? false,
    can_waive: bool(raw["can_waive"]) ?? false,
  };
}

function period(raw: unknown): ClosePeriod | null {
  const r = record(raw);
  const id = r ? text(r["fiscal_period_id"]) : null;
  if (!r || !id) return null;
  return {
    fiscal_period_id: id,
    code: text(r["code"]) ?? "",
    status: text(r["status"]) ?? "",
    starts_on: text(r["starts_on"]) ?? "",
    ends_on: text(r["ends_on"]) ?? "",
    ledger: text(r["ledger"]) ?? "",
  };
}

/** The checklist as the door answers it, whatever age the door is. */
export function normaliseChecklist(raw: unknown): Checklist {
  const r = record(raw) ?? {};
  const state = STATES.find((s) => s === r["state"]) ?? "no_period";
  const tasks = Array.isArray(r["tasks"])
    ? (r["tasks"] as unknown[])
        .map(record)
        .filter((t): t is Raw => t !== null)
        .map(task)
    : [];
  const siblings = Array.isArray(r["siblings"])
    ? (r["siblings"] as unknown[])
        .map(record)
        .filter((s): s is Raw => s !== null && text(s["fiscal_period_id"]) !== null)
        .map((s) => ({
          fiscal_period_id: text(s["fiscal_period_id"]) ?? "",
          code: text(s["code"]) ?? "",
          status: text(s["status"]) ?? "",
          ledger: text(s["ledger"]) ?? "",
        }))
    : [];
  const home = record(r["checklist_period"]);
  const homeId = home ? text(home["fiscal_period_id"]) : null;
  return {
    period: period(r["period"]),
    tasks,
    state,
    blocking: text(r["blocking"]),
    can_open: bool(r["can_open"]) ?? false,
    can_close: bool(r["can_close"]) ?? false,
    open_tasks: num(r["open_tasks"]),
    failing_checks: num(r["failing_checks"]),
    failing_since_completed: num(r["failing_since_completed"]),
    siblings,
    checklist_period:
      home && homeId
        ? {
            fiscal_period_id: homeId,
            code: text(home["code"]) ?? "",
            ledger: text(home["ledger"]) ?? "",
          }
        : null,
  };
}

// ── The two presses ─────────────────────────────────────────────────────────

export const CLOSE_PERMISSION = "finance.close_period";

export type ClosePresses = {
  /**
   * erp_open_period_close, as the month needs it: "open" raises the checklist
   * and runs every check; "rerun" runs the checks again over what the opening
   * left open, which is the same door. Null draws nothing.
   */
  open: "open" | "rerun" | null;
  close: boolean;
};

/**
 * The doors take:
 *
 *   not_opened    Open (the door raises the checklist and runs the checks)
 *   in_progress   Run the checks again (the same door, over what is left)
 *   ready         Close; or Run the checks again, where a check has failed
 *                 since and the close would be refused
 *   closed        nothing
 *
 * each only where the checklist says the door would take it for this reader
 * (can_open, can_close) and the session holds finance.close_period.
 */
export function closePresses(c: Checklist, can: (code: string) => boolean): ClosePresses {
  const may = can(CLOSE_PERMISSION) && c.period !== null;
  const open =
    may && c.can_open
      ? c.state === "not_opened"
        ? "open"
        : c.state === "in_progress" || (c.state === "ready" && !c.can_close)
          ? "rerun"
          : null
      : null;
  return { open, close: may && c.can_close && c.state === "ready" };
}

export type TaskPresses = { complete: boolean; waive: boolean };

/** Complete and Waive on a task, where erp_complete_close_task would take them. */
export function taskPresses(t: CloseTask, can: (code: string) => boolean): TaskPresses {
  const may = can(CLOSE_PERMISSION) && t.task_id !== null;
  return { complete: may && t.can_complete, waive: may && t.can_waive };
}

// ── What is said ────────────────────────────────────────────────────────────

/**
 * What the task's check said: in its own words where it fails now, and what it
 * said when the task was completed or waived otherwise. Null where it has no
 * check and said nothing.
 */
export function checkSaid(t: CloseTask): { words: string; failed: boolean } | null {
  if (t.check_passes === false && t.check_failure) return { words: t.check_failure, failed: true };
  if (t.check_output) {
    const failed = t.check_output.startsWith("FAILED: ");
    return { words: failed ? t.check_output.slice(8) : t.check_output, failed };
  }
  return null;
}

/** The periods that close with this one, as "COMMIT 2026-09", in the door's order. */
export function closesWith(c: Checklist): string[] {
  return c.siblings.map((s) => `${s.ledger} ${s.code}`.trim());
}

/**
 * The ledger the month's checklist is kept on, where it is not this period's
 * own: a close opened from GL is read from COMMIT as GL's.
 */
export function checklistKeptOn(c: Checklist): string | null {
  const home = c.checklist_period;
  if (!home || !c.period || home.fiscal_period_id === c.period.fiscal_period_id) return null;
  return `${home.ledger} ${home.code}`.trim();
}
