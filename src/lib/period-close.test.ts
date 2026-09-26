import { describe, expect, test } from "bun:test";

import {
  checklistKeptOn,
  checkSaid,
  closePresses,
  closesWith,
  normaliseChecklist,
  taskPresses,
  type CloseTask,
} from "./period-close";

const GL = "00000000-0000-4000-8000-0000000000f1";
const COMMIT = "00000000-0000-4000-8000-0000000000f2";

const period = (id: string, ledger: string) => ({
  fiscal_period_id: id,
  code: "2026-09",
  status: "closing",
  starts_on: "2026-09-01",
  ends_on: "2026-09-30",
  ledger,
});

const rawTask = (over: Record<string, unknown> = {}) => ({
  task_id: "t1",
  code: "grni_reviewed",
  name: "Goods received not invoiced reviewed",
  seq: 40,
  status: "open",
  blocking_check: "erp.assert_grni_reconciles()",
  is_waivable: true,
  blocked_by: null,
  check_passes: false,
  check_failure: "CLOVEERP_GRNI_DOES_NOT_RECONCILE: 2100 is £957.00 more than the open receipts",
  completed_by: null,
  completed_at: null,
  waiver_reason: null,
  check_output: null,
  owner_role_code: null,
  can_complete: false,
  can_waive: true,
  ...over,
});

const checklist = (over: Record<string, unknown> = {}) =>
  normaliseChecklist({
    period: period(GL, "GL"),
    tasks: [rawTask()],
    state: "in_progress",
    blocking: "Goods received not invoiced reviewed is not done yet.",
    can_open: true,
    can_close: false,
    open_tasks: 1,
    failing_checks: 1,
    failing_since_completed: 0,
    siblings: [{ fiscal_period_id: COMMIT, code: "2026-09", status: "closing", ledger: "COMMIT" }],
    checklist_period: { fiscal_period_id: GL, code: "2026-09", ledger: "GL" },
    ...over,
  });

const all = () => true;
const none = () => false;

describe("the checklist as the door answers it", () => {
  test("reads every key 20260929400000 added", () => {
    const c = checklist();
    expect(c.state).toBe("in_progress");
    expect(c.can_open).toBe(true);
    expect(c.siblings).toEqual([
      { fiscal_period_id: COMMIT, code: "2026-09", status: "closing", ledger: "COMMIT" },
    ]);
    expect(c.tasks[0]?.can_waive).toBe(true);
    expect(c.tasks[0]?.check_failure).toContain("GRNI");
  });

  test("an older door, which says nothing of what it would take, draws nothing", () => {
    const c = normaliseChecklist({
      period: period(GL, "GL"),
      tasks: [{ code: "trial_balance", name: "Trial balance", status: "open", check_passes: true }],
      state: "in_progress",
      can_close: false,
    });
    expect(c.can_open).toBe(false);
    expect(c.siblings).toEqual([]);
    expect(c.checklist_period).toBeNull();
    expect(closePresses(c, all)).toEqual({ open: null, close: false });
    const t = c.tasks[0] as CloseTask;
    expect(taskPresses(t, all)).toEqual({ complete: false, waive: false });
  });

  test("nothing at all is a month with no period, not a crash", () => {
    const c = normaliseChecklist([]);
    expect(c.state).toBe("no_period");
    expect(c.period).toBeNull();
    expect(c.tasks).toEqual([]);
    expect(closePresses(c, all)).toEqual({ open: null, close: false });
  });
});

describe("the two presses", () => {
  test("a month not opened offers Open, and not Close", () => {
    const c = checklist({ state: "not_opened", tasks: [], checklist_period: null });
    expect(closePresses(c, all)).toEqual({ open: "open", close: false });
  });

  test("a month in progress offers the checks again, and not Close", () => {
    expect(closePresses(checklist(), all)).toEqual({ open: "rerun", close: false });
  });

  test("a ready month offers Close only where the door would take it", () => {
    expect(closePresses(checklist({ state: "ready", can_close: true }), all)).toEqual({
      open: null,
      close: true,
    });
    // A completed check failing since: the door would refuse, and says so.
    expect(closePresses(checklist({ state: "ready", can_close: false }), all).close).toBe(false);
  });

  test("a closed month offers nothing, whatever the flags", () => {
    expect(
      closePresses(checklist({ state: "closed", can_open: true, can_close: true }), all),
    ).toEqual({ open: null, close: false });
  });

  test("somebody without finance.close_period is offered nothing", () => {
    expect(closePresses(checklist({ state: "not_opened" }), none)).toEqual({
      open: null,
      close: false,
    });
    expect(closePresses(checklist({ state: "ready", can_close: true }), none).close).toBe(false);
  });
});

describe("a task's verbs", () => {
  test("Waive and Complete follow the door's answer", () => {
    const [failing] = checklist().tasks;
    expect(taskPresses(failing as CloseTask, all)).toEqual({ complete: false, waive: true });
    const [unchecked] = checklist({
      tasks: [rawTask({ blocking_check: null, check_passes: null, can_complete: true })],
    }).tasks;
    expect(taskPresses(unchecked as CloseTask, all)).toEqual({ complete: true, waive: true });
  });

  test("not without the permission, nor without a task to name", () => {
    const [t] = checklist().tasks;
    expect(taskPresses(t as CloseTask, none)).toEqual({ complete: false, waive: false });
    const [nameless] = checklist({ tasks: [rawTask({ task_id: null })] }).tasks;
    expect(taskPresses(nameless as CloseTask, all)).toEqual({ complete: false, waive: false });
  });
});

describe("what is said", () => {
  test("a failing check in its own words, and a waived one's recorded failure", () => {
    const [failing] = checklist().tasks;
    expect(checkSaid(failing as CloseTask)).toEqual({
      words: "CLOVEERP_GRNI_DOES_NOT_RECONCILE: 2100 is £957.00 more than the open receipts",
      failed: true,
    });
    const [waived] = checklist({
      tasks: [
        rawTask({
          status: "waived",
          check_passes: false,
          check_failure: null,
          check_output: "FAILED: the difference is 95700",
        }),
      ],
    }).tasks;
    expect(checkSaid(waived as CloseTask)).toEqual({
      words: "the difference is 95700",
      failed: true,
    });
    const [passed] = checklist({
      tasks: [
        rawTask({
          status: "complete",
          check_passes: true,
          check_failure: null,
          check_output: "GRNI reconciles",
        }),
      ],
    }).tasks;
    expect(checkSaid(passed as CloseTask)).toEqual({ words: "GRNI reconciles", failed: false });
    const [silent] = checklist({
      tasks: [rawTask({ blocking_check: null, check_passes: null, check_failure: null })],
    }).tasks;
    expect(checkSaid(silent as CloseTask)).toBeNull();
  });

  test("the ledgers that close together, and where the checklist is kept", () => {
    expect(closesWith(checklist())).toEqual(["COMMIT 2026-09"]);
    expect(checklistKeptOn(checklist())).toBeNull();
    // COMMIT's month, whose close was opened from GL.
    const fromCommit = checklist({
      period: period(COMMIT, "COMMIT"),
      siblings: [{ fiscal_period_id: GL, code: "2026-09", status: "closing", ledger: "GL" }],
    });
    expect(checklistKeptOn(fromCommit)).toBe("GL 2026-09");
    expect(closesWith(fromCommit)).toEqual(["GL 2026-09"]);
  });
});
