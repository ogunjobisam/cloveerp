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

/**
 * How a verb is handed the record the step has already chosen.
 *
 * A step answers its verbs with the record on the right, and a form does not
 * ask a question the screen has answered: `recordArg` names the argument, the
 * field is not drawn, and the value is sent whatever the form built. That is
 * right where the step and the verb are about the same record.
 *
 * It is wrong where the verb reaches past it. Receiving belongs on the purchase
 * order step, because that is where somebody stands when the goods arrive — but
 * the receipt is raised against an order, under a different argument name, and
 * what turned up at the door is *usually* the order in front of you rather than
 * always. A verb named in `carriedArgs` takes the chosen record as the argument
 * named there, arriving filled in and staying the person's to change, and the
 * step's own `recordArg` is not sent with it.
 */
export function recordAnswer(
  stage: Pick<Stage, "recordArg" | "carriedArgs">,
  action: Pick<ActionSpec, "code" | "fn">,
  id: string,
): { prefill: Record<string, unknown>; preselect: Record<string, string> } {
  const carried = stage.carriedArgs?.[actionKey(action)];
  if (carried !== undefined) return { prefill: {}, preselect: id === "" ? {} : { [carried]: id } };
  if (stage.recordArg !== undefined && id !== "")
    return { prefill: { [stage.recordArg]: id }, preselect: {} };
  return { prefill: {}, preselect: {} };
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
