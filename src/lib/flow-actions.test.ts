import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import type { ActionSpec } from "../components/erp/actions-bar";
import type { FlowSpec } from "../components/erp/process-flow";
import {
  actionKey,
  recordAnswer,
  stageActionKeys,
  stagedKeys,
  unstagedActions,
} from "./flow-actions";
import { MODULES, PLANNING, QUALITY, RELEASE_BATCH } from "./modules";

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

const flowOf = (...stages: FlowSpec["stages"]): FlowSpec => ({
  code: "test",
  title: "Flow",
  stages,
});

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

/**
 * A form does not ask for the document the step has already chosen.
 *
 * Receiving is reached from the purchase order step, where an order is in front
 * of you, and asked which order all over again — a picker of every order sent to
 * every supplier, to find the one you were looking at. The step hands it over
 * now; it is still a question, because the goods might be against a different
 * order, but it is a question that arrives answered.
 */
describe("recordAnswer", () => {
  test("a verb the step names takes the record and stops asking", () => {
    expect(
      recordAnswer({ recordArg: "p_document_id" }, act("erp_set_order_behaviour"), "doc-1"),
    ).toEqual({ prefill: { p_document_id: "doc-1" }, preselect: {} });
  });

  test("a carried verb takes it under its own name, and still asks", () => {
    const stage = {
      recordArg: "p_document_id",
      carriedArgs: { receive_this_order: "p_order_id" },
    };
    expect(
      recordAnswer(
        stage,
        act("erp_create_receipt_from_order", {
          code: "receive_this_order",
        }),
        "doc-1",
      ),
    ).toEqual({ prefill: {}, preselect: { p_order_id: "doc-1" } });
  });

  test("the step's own argument is not sent with a carried verb", () => {
    // erp_create_receipt_from_order has no p_document_id: sending one would be
    // a call to a function that does not exist.
    const answer = recordAnswer(
      { recordArg: "p_document_id", carriedArgs: { receive_this_order: "p_order_id" } },
      act("erp_create_receipt_from_order", { code: "receive_this_order" }),
      "doc-1",
    );
    expect(answer.prefill).toEqual({});
  });

  test("with nothing chosen, nothing is answered either way", () => {
    expect(
      recordAnswer(
        { recordArg: "p_document_id", carriedArgs: { receive_this_order: "p_order_id" } },
        act("erp_create_receipt_from_order", { code: "receive_this_order" }),
        "",
      ),
    ).toEqual({ prefill: {}, preselect: {} });
    expect(recordAnswer({ recordArg: "p_document_id" }, act("erp_a"), "")).toEqual({
      prefill: {},
      preselect: {},
    });
  });

  test("a step with no record argument answers nothing", () => {
    expect(recordAnswer({}, act("erp_a"), "doc-1")).toEqual({ prefill: {}, preselect: {} });
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

describe("a step whose verbs are spent points at the one after it", () => {
  // As above, the source rather than a render: the fault was that the sentence
  // ended there, and a dead end is a thing you can read in the file.
  const strip = readFileSync(
    join(import.meta.dir, "..", "components", "erp", "process-flow.tsx"),
    "utf8",
  );

  test("the step after this one is worked out from the chain", () => {
    expect(strip).toContain("const after = flow.stages[at + 1];");
  });

  // One whole sentence with the name put into it, not a fragment joined to a
  // name: a translator has to be able to move the name within the sentence.
  test("the sentence names it", () => {
    expect(strip).toContain('fill(ui("The next step is {step}."), { step: ui(next.label) })');
  });

  test("and there is a way to get there", () => {
    expect(strip).toContain("nothingApplies && next");
    expect(strip).toContain('fill(ui("Go to {step}"), { step: ui(next.label) })');
  });

  // The step is called whatever the organisation calls it, and that name is put
  // in as it was written. Lowercasing it would make "Companies House-style
  // entity structure" read "companies house-style entity structure".
  test("the name of the step is not recased", () => {
    expect(strip).not.toContain("ui(next.label).toLowerCase()");
  });

  test("the last step of a chain points nowhere", () => {
    expect(strip).toContain("const next: NextStep | null = after");
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
    const stage = PLANNING.flow?.stages.find((s) => s.label === "Work out what to order");
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

  test("the release sends the inspection it relies on, chosen from that batch's own", () => {
    expect(RELEASE_BATCH.fields?.map((f) => f.name)).toEqual([
      "p_batch_id",
      "p_site_id",
      "p_inspection_id",
      "p_basis",
      "p_signature",
    ]);
    const inspection = RELEASE_BATCH.fields?.find((f) => f.name === "p_inspection_id");
    if (inspection?.kind !== "select") throw new Error("the inspection is not chosen from a list");
    expect(inspection.required).toBe(false);
    expect(inspection.options.fn).toBe("erp_inspections");
    expect(inspection.options.argsFrom).toEqual({ p_batch_id: "p_batch_id" });
    expect(inspection.options.value).toBe("inspection_id");
    // The floor's inspection of the order that made the batch is offered too,
    // and says which order it was of (20260925400000).
    expect(inspection.options.label).toContain("works_order");
    expect(QUALITY.actions).toContain(RELEASE_BATCH);
    // Asked for only where a plan sampled the batch (20260925300000); the
    // database demands them there.
    for (const name of ["p_basis", "p_signature"]) {
      expect(RELEASE_BATCH.fields?.find((f) => f.name === name)?.required).toBe(false);
    }
  });

  test("an inspection is asked for from the actions, against a plan that covers the batch", () => {
    const raise = (QUALITY.actions ?? []).find((a) => a.fn === "erp_raise_inspection");
    expect(raise?.permission).toBe("quality.inspect");
    expect(raise?.fields?.map((f) => f.name)).toEqual([
      "p_site_id",
      "p_batch_id",
      "p_plan_id",
      "p_quantity",
    ]);
    const plan = raise?.fields?.find((f) => f.name === "p_plan_id");
    if (plan?.kind !== "select") throw new Error("the plan is not chosen from a list");
    expect(plan.required).toBe(false);
    expect(plan.options.fn).toBe("erp_inspection_plans");
    expect(plan.options.argsFrom).toEqual({ p_batch_id: "p_batch_id", p_site_id: "p_site_id" });
    // An action, not a stage: the strip's budget stays where it is.
    expect(stagedKeys(QUALITY.flow as FlowSpec).has("erp_raise_inspection")).toBe(false);
  });
});
