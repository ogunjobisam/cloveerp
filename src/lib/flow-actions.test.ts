import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import type { ActionSpec } from "../components/erp/actions-bar";
import type { FlowSpec } from "../components/erp/process-flow";
import { actionKey, stageActionKeys, stagedKeys, unstagedActions } from "./flow-actions";
import { MODULES, PLANNING, QUALITY } from "./modules";

/**
 * Every verb a module declares can be reached from its screen.
 *
 * A module with a process strip showed only the verbs a step named, and hid the
 * action bar that lists the rest. Fifteen verbs on Stock, ten on Financials and
 * five more across Planning, Manufacturing and Quality were declared, gated,
 * and reachable from nowhere — batch release, period close, bills of material
 * among them — and nothing in the build could see it, because every one of
 * them was a correct declaration. What was wrong was where it was drawn.
 *
 * So the rule is checked against the real registry: a verb is either named by a
 * step, and the step opens that verb and not another, or it is on the bar.
 */

const act = (fn: string, extra: Partial<ActionSpec> = {}): ActionSpec => ({
  label: fn,
  fn,
  ...extra,
});

const flowOf = (...stages: FlowSpec["stages"]): FlowSpec => ({ title: "Flow", stages });

describe("actionKey", () => {
  test("is the code when an action has one", () => {
    expect(actionKey(act("erp_transition_document", { code: "requisition_submit" }))).toBe(
      "requisition_submit",
    );
  });

  test("is the function when it does not", () => {
    expect(actionKey(act("erp_post_count"))).toBe("erp_post_count");
  });
});

describe("stageActionKeys", () => {
  test("carries the record verb, the further verbs and the verb that needs no record", () => {
    expect(stageActionKeys({ actionFn: "a", actionFns: ["b", "c"], createFn: "d" })).toEqual([
      "a",
      "b",
      "c",
      "d",
    ]);
  });

  test("carries nothing for a step with no verbs", () => {
    expect(stageActionKeys({})).toEqual([]);
  });
});

describe("unstagedActions", () => {
  const flow = flowOf(
    { label: "One", hint: "", actionFn: "erp_a", actionFns: ["erp_b"] },
    { label: "Two", hint: "", createFn: "coded" },
  );

  test("leaves out every verb a step names, by function or by code", () => {
    const actions = [
      act("erp_a"),
      act("erp_b"),
      act("erp_shared", { code: "coded" }),
      act("erp_c"),
      act("erp_d"),
    ];
    expect(unstagedActions(flow, actions).map((a) => a.fn)).toEqual(["erp_c", "erp_d"]);
    expect(stagedKeys(flow)).toEqual(new Set(["erp_a", "erp_b", "coded"]));
  });

  test("a verb with a code is not staged by a step that names only its function", () => {
    const actions = [act("erp_a", { code: "erp_a_by_code" })];
    expect(unstagedActions(flow, actions)).toEqual(actions);
  });

  test("keeps the declared order", () => {
    const actions = [act("erp_z"), act("erp_a"), act("erp_m")];
    expect(unstagedActions(flow, actions).map((a) => a.fn)).toEqual(["erp_z", "erp_m"]);
  });

  test("with no flow, every action is on the bar", () => {
    const actions = [act("erp_a"), act("erp_b")];
    expect(unstagedActions(undefined, actions)).toEqual(actions);
  });
});

describe("the module page draws the bar beside the strip", () => {
  // A render is beyond this suite, so the source is read, as the empty-state
  // and accessibility checks read theirs. The fault was one condition.
  const page = readFileSync(
    join(import.meta.dir, "..", "components", "erp", "module-page.tsx"),
    "utf8",
  );

  test("the bar lists the actions no step names", () => {
    expect(page).toContain("unstagedActions(def.flow, def.actions ?? [])");
    expect(page).toMatch(/<ActionBar\s+actions=\{unstaged\}/);
  });

  test("the bar is not switched off by the strip", () => {
    expect(page).not.toContain("!def.flow");
  });
});

describe("every module with a strip: every verb is reachable", () => {
  const withFlow = MODULES.filter((m) => m.flow);

  test("the registry was read", () => {
    expect(withFlow.length).toBeGreaterThan(0);
  });

  for (const mod of withFlow) {
    const flow = mod.flow as FlowSpec;
    const actions = mod.actions ?? [];
    // The strip looks a step's verb up by this key; a later declaration under
    // the same key answers for an earlier one.
    const byKey = new Map(actions.map((a) => [actionKey(a), a]));
    const onBar = new Set(unstagedActions(flow, actions));
    const staged = stagedKeys(flow);

    test(`${mod.key}: no two verbs share the name a step would open them by`, () => {
      const keys = actions.map(actionKey);
      expect(keys.filter((k, i) => keys.indexOf(k) !== i)).toEqual([]);
    });

    test(`${mod.key}: every verb a step names is declared`, () => {
      expect([...staged].filter((k) => !byKey.has(k))).toEqual([]);
    });

    for (const action of actions) {
      test(`${mod.key}: "${action.label}" is on a step or on the bar`, () => {
        const openedByAStep =
          staged.has(actionKey(action)) && byKey.get(actionKey(action)) === action;
        expect(openedByAStep || onBar.has(action)).toBe(true);
      });
    }
  }
});

describe("the verbs the walkthrough found unreachable", () => {
  test("Planning's requirements run opens the baseline, not a scenario", () => {
    const stage = PLANNING.flow?.stages.find((s) => s.label === "Requirements run");
    expect(stage?.createFn).toBeDefined();
    // Looked up the way the strip looks it up, where the last of a name wins.
    const byKey = new Map((PLANNING.actions ?? []).map((a) => [actionKey(a), a]));
    const opened = stage?.createFn ? byKey.get(stage.createFn) : undefined;
    expect(opened?.fn).toBe("erp_run_planning");
    expect(opened?.fields?.some((f) => f.name === "p_scenario_code")).toBe(false);
  });

  test("Planning's scenario run is still offered, on the bar", () => {
    const bar = unstagedActions(PLANNING.flow, PLANNING.actions ?? []);
    expect(bar.some((a) => a.fields?.some((f) => f.name === "p_scenario_code"))).toBe(true);
  });

  test("Quality offers batch release", () => {
    const actions = QUALITY.actions ?? [];
    const release = actions.find((a) => a.fn === "erp_release_batch");
    expect(release?.permission).toBe("quality.release_batch");
    const staged = stagedKeys(QUALITY.flow as FlowSpec).has("erp_release_batch");
    const onBar = unstagedActions(QUALITY.flow, actions).some((a) => a.fn === "erp_release_batch");
    expect(staged || onBar).toBe(true);
  });
});
