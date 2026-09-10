import { Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";

import { callErp, hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { ActionButton, ActionDialog } from "./action";
import type { ActionSpec } from "./actions-bar";
import { useErpSession } from "./session-context";
import { TOUCH } from "./page";

/**
 * The process, drawn.
 *
 * Every ERP that people are fond of draws the chain across the top of the
 * screen — requisition, order, receipt, bill, payment — and lets you act on a
 * step by pressing the step. A list of eleven verbs in a card is complete and
 * unreadable: it says what you may do and nothing about what comes first.
 *
 * A stage is a box. It names the step, counts what is sitting there, and
 * carries at most one verb: the one that moves work out of it. The verb is the
 * same declared `ActionSpec` the action bar renders, looked up by function
 * name, so there is one definition of each action and the flow only chooses
 * where it appears. A stage whose permission the session does not hold stays
 * on the screen greyed out — the shape of the process is worth knowing even
 * where you cannot drive it.
 */

export type Stage = {
  label: string;
  hint: string;
  /** Counts documents of this type code, via public.erp_documents. */
  typeCode?: string;
  /** Any other read whose row count is the number at this stage. */
  count?: { fn: string; args?: Record<string, unknown> };
  /** The verb that moves work out of this stage, by function name. */
  actionFn?: string;
  /** Where the stage lives, when it lives on another screen. */
  to?: string;
  toLabel?: string;
};

export type FlowSpec = {
  title: string;
  note?: string;
  stages: Stage[];
};

/** How many documents a count read may return before the figure is "200+". */
const CAP = 200;

function useStageCount(stage: Stage) {
  const source = stage.typeCode
    ? { fn: "erp_documents", args: { p_type_code: stage.typeCode, p_limit: CAP } }
    : stage.count;

  const { data, error } = useQuery({
    queryKey: [source?.fn ?? "no-count", source?.args ?? {}],
    queryFn: () =>
      source
        ? callErp<unknown[]>(source.fn, source.args ?? {})
        : Promise.resolve([] as unknown[]),
    enabled: Boolean(source),
    refetchInterval: (q) => (q.state.error ? false : 60_000),
  });

  if (!source || error) return null;
  if (!Array.isArray(data)) return null;
  return data.length >= CAP ? `${CAP}+` : String(data.length);
}

function StageCard({
  stage,
  action,
  index,
}: {
  stage: Stage;
  action: ActionSpec | undefined;
  index: number;
}) {
  const { ui } = useT();
  const { session } = useErpSession();
  const count = useStageCount(stage);
  const permitted = !action?.permission || hasPermission(session, action.permission);

  return (
    <li className="flex min-w-0 shrink-0 items-stretch gap-2">
      {index > 0 ? (
        <span aria-hidden="true" className="self-center text-muted-foreground">
          →
        </span>
      ) : null}
      <div className="flex w-56 shrink-0 flex-col rounded-lg border border-border bg-background p-3">
        <div className="flex items-baseline justify-between gap-2">
          <span className="truncate text-sm font-semibold">{ui(stage.label)}</span>
          {count !== null ? (
            <span className="shrink-0 rounded-full bg-muted px-1.5 py-0.5 text-[11px] tabular-nums text-muted-foreground">
              {count}
            </span>
          ) : null}
        </div>
        <p className="mt-1 line-clamp-3 text-xs text-muted-foreground">{ui(stage.hint)}</p>

        <div className="mt-3 flex flex-col gap-2">
          {action && permitted ? (
            <ActionDialog
              trigger={<ActionButton variant="secondary">{ui(action.label)}</ActionButton>}
              title={action.title ?? action.label}
              {...(action.description ? { description: action.description } : {})}
              {...(action.permission ? { permission: action.permission } : {})}
              fn={action.fn}
              fields={action.fields ?? []}
              {...(action.mapArgs ? { mapArgs: action.mapArgs } : {})}
              invalidates={action.invalidates ?? []}
              submitLabel={action.submitLabel ?? action.label}
            />
          ) : action ? (
            <ActionButton
              variant="secondary"
              disabled
              title="You do not hold the permission for this step."
            >
              {ui(action.label)}
            </ActionButton>
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
    </li>
  );
}

export function ProcessFlow({ flow, actions }: { flow: FlowSpec; actions: ActionSpec[] }) {
  const { ui } = useT();
  const byFn = new Map(actions.map((a) => [a.fn, a]));

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5">
      <h2 className="text-sm font-semibold">{ui(flow.title)}</h2>
      {flow.note ? <p className="mt-0.5 text-xs text-muted-foreground">{ui(flow.note)}</p> : null}
      <div className="mt-3 overflow-x-auto pb-1">
        <ol className="flex items-stretch gap-2">
          {flow.stages.map((s, i) => (
            <StageCard
              key={s.label}
              stage={s}
              index={i}
              {...(s.actionFn ? { action: byFn.get(s.actionFn) } : { action: undefined })}
            />
          ))}
        </ol>
      </div>
    </section>
  );
}
