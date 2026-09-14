import type { ActionSpec } from "../components/erp/actions-bar";
import type { FlowSpec, Stage } from "../components/erp/process-flow";

/**
 * Which of a module's verbs its process strip carries, and which it does not.
 *
 * A module with a strip drew only the verbs a step names, and the action bar
 * that lists every verb was switched off for it. So every verb no step named —
 * releasing a batch, opening a period close, defining a bill of materials —
 * was declared, permitted, and reachable from nowhere. The strip is where a
 * verb appears in the chain; it was never meant to be the only place it can
 * appear at all.
 */

/**
 * How a stage names an action: its code when it has one, its function when not.
 *
 * Two verbs on one function need a code each. Without one they share a name,
 * and whichever is declared later silently answers for both.
 */
export function actionKey(action: Pick<ActionSpec, "code" | "fn">): string {
  return action.code ?? action.fn;
}

/** Every action name one stage carries: its verbs for a record, and its verb for none. */
export function stageActionKeys(
  stage: Pick<Stage, "actionFn" | "actionFns" | "createFn">,
): string[] {
  return [
    ...(stage.actionFn ? [stage.actionFn] : []),
    ...(stage.actionFns ?? []),
    ...(stage.createFn ? [stage.createFn] : []),
  ];
}

/** The action names any stage of a flow carries. */
export function stagedKeys(flow: FlowSpec): Set<string> {
  return new Set(flow.stages.flatMap(stageActionKeys));
}

/**
 * The actions no stage names, in their declared order.
 *
 * With no flow there is no strip, so every action is one of these.
 */
export function unstagedActions(flow: FlowSpec | undefined, actions: ActionSpec[]): ActionSpec[] {
  if (!flow) return actions;
  const staged = stagedKeys(flow);
  return actions.filter((a) => !staged.has(actionKey(a)));
}
