import { prettifyField } from "../../lib/friendly";
import { useT } from "../../lib/i18n";
import { byTone, transitionTone } from "../../lib/plain-words";
import { ActionButton, ActionDialog, ErrorNote, useErpAction } from "./action";
import {
  heldReasons,
  isCompletable,
  manualTransitions,
  type Transition,
} from "./available-transitions";
import { TOUCH } from "./page";

type ExplainedMove = {
  fn: "erp_transition_document";
  label: string;
  title: string;
  description: string;
  hint: string;
  submitLabel: string;
};

/**
 * The moves a person makes only with the reason said (20260922360000).
 *
 * A purchase order is received by its goods and closed by its bill, and the
 * database refuses either one asserted over nothing. Two stay a person's to
 * make when the fact will never come: the supplier who will send nothing more,
 * and the bill that is kept somewhere else. The database takes them only with
 * a reason, which the transition log keeps beside the move, so each opens a
 * form that asks for the reason instead of moving on a press.
 */
const EXPLAINED_MOVES: Readonly<Record<string, Readonly<Record<string, ExplainedMove>>>> = {
  purchase_order: {
    receive_rest: {
      fn: "erp_transition_document",
      label: "Close short",
      title: "Close this order short",
      description:
        "Nothing more is coming from the supplier. The order reads Received for what arrived, and the bill for that closes it.",
      hint: "Kept on the order's history with the move.",
      submitLabel: "Close it short",
    },
    close: {
      fn: "erp_transition_document",
      label: "Close without the bill",
      title: "Close this order without its bill",
      description:
        "An order closes itself when the bill for what arrived is registered. Close it here only when that bill is kept somewhere else.",
      hint: "Kept on the order's history with the move.",
      submitLabel: "Close it",
    },
  },
};

/**
 * What may happen to this document next, and the buttons that make it happen.
 *
 * Written for the document's own page and shared with the process strip,
 * because a draft purchase order chosen on Purchasing's "Purchase order" step
 * offered nothing that could move it on: the step carried one verb, and the
 * moves its lifecycle has — submit, approve, send — were a page away. One read
 * and one door, on both screens, so they cannot offer different things.
 *
 * Three states, and the difference between the last two is the reason
 * `erp_available_transitions` exists:
 *
 *   permitted, guard passes  — offered
 *   not permitted            — not offered at all, because the caller may not
 *   guard does not pass      — offered, disabled, and named
 *
 * "You may not do this" and "you may do this but not yet" are different facts,
 * and collapsing them into a greyed button tells the reader neither.
 *
 * A move another document or door makes is never offered here
 * (`DOOR_ONLY_TRANSITIONS`). `exclude` leaves out moves a screen offers through
 * a verb of its own — the
 * strip's "Submit for approval", or "Convert to a purchase order", which
 * performs the requisition's move to Ordered and raises the order with it.
 * `quiet` says nothing when nothing is offered, for a screen that says it
 * itself.
 *
 * The way forward is the one dark button. A way back (reject, send back) is a
 * plain one and a way out (cancel) is drawn in the destructive colour, last:
 * the owner found Cancel beside Submit looking exactly like it.
 */
export function DocumentTransitions({
  documentId,
  documentType,
  transitions,
  committed,
  exclude = [],
  quiet = false,
}: {
  documentId: string;
  /** The document's type code, which decides the moves only a door makes. */
  documentType: string | null;
  transitions: Transition[];
  committed: boolean;
  exclude?: readonly string[];
  quiet?: boolean;
}) {
  const { ui } = useT();
  const act = useErpAction({
    fn: "erp_transition_document",
    invalidates: [
      "erp_document",
      "erp_documents",
      "erp_available_transitions",
      "erp_document_approval_chain",
      "erp_my_approvals",
    ],
  });
  // An approver who holds a task on the document approves in one press
  // (20260923200000). When somebody else's decision is still needed, theirs is
  // kept and the door answers with the state the document is still in.
  const pressed = act.variables;
  const answered =
    act.isSuccess && typeof act.data === "object" && act.data !== null
      ? (act.data as Record<string, unknown>)["state"]
      : undefined;
  const stillWaiting =
    pressed?.["p_document_id"] === documentId &&
    pressed["p_transition_code"] === "approve" &&
    typeof answered === "string" &&
    answered !== transitions.find((t) => t.code === "approve")?.to_state;
  const explained = documentType ? EXPLAINED_MOVES[documentType] : undefined;

  const manual = manualTransitions(documentType, transitions);
  // Drawn only where the person can complete it (20260923600000): permitted,
  // its guard passing against the document, and not refused by the door. The
  // rest are not drawn, and why is said once.
  const offered = byTone(manual.filter((t) => isCompletable(t) && !exclude.includes(t.code)));
  // Reasons come from every move, the excluded ones too: a move a step verb
  // makes is excluded here so it is not drawn twice, and its reason is still
  // the reason (found on review).
  const held = heldReasons(manual);
  const notes = (
    <>
      {stillWaiting ? (
        <p className="text-xs text-muted-foreground">
          {ui("Your decision is recorded; it is still waiting on somebody else's.")}
        </p>
      ) : null}
      {held.map((reason) => (
        <p key={reason} className="text-xs text-muted-foreground">
          {ui(reason)}
        </p>
      ))}
    </>
  );

  if (offered.length === 0) {
    if (stillWaiting || held.length > 0)
      return (
        <div className="mt-4 flex flex-col gap-2">
          {notes}
          <ErrorNote error={act.error} />
        </div>
      );
    // Every move left is one a door makes, and the screen offers that door by
    // name: there is nothing to explain here.
    if (quiet || (transitions.length > 0 && manual.length === 0)) return null;
    return (
      <p className="mt-4 text-xs text-muted-foreground">
        {transitions.length === 0
          ? committed
            ? "This document has reached a state its lifecycle does not continue from."
            : "This document's type has no lifecycle configured, so there is nothing to move it through."
          : "Nothing here is offered to this account. The transitions this document has all require a permission it does not hold."}
      </p>
    );
  }

  return (
    <div className="mt-4 flex flex-col gap-2">
      <div className="flex flex-wrap gap-2">
        {offered.map((t) => {
          const move = explained?.[t.code];
          if (move) {
            return (
              // Keyed by the document as well as the move, so a reason typed
              // for one order is never sent for the next one chosen.
              <ActionDialog
                key={`${t.code}:${documentId}`}
                trigger={
                  <button
                    type="button"
                    className={`${TOUCH} inline-flex shrink-0 items-center justify-center rounded-md border border-input px-4 text-sm font-medium`}
                  >
                    {ui(move.label)}
                  </button>
                }
                title={move.title}
                description={move.description}
                fn={move.fn}
                fields={[
                  {
                    kind: "text",
                    name: "p_reason",
                    label: "Reason",
                    required: true,
                    hint: move.hint,
                  },
                ]}
                mapArgs={(v) => ({
                  p_document_id: documentId,
                  p_transition_code: t.code,
                  p_reason: v["p_reason"],
                })}
                invalidates={["erp_document", "erp_documents", "erp_available_transitions"]}
                submitLabel={move.submitLabel}
              />
            );
          }
          return (
            <ActionButton
              key={t.code}
              variant={
                transitionTone(t) === "out"
                  ? "danger"
                  : transitionTone(t) === "back"
                    ? "secondary"
                    : "primary"
              }
              busy={act.isPending}
              title={`Moves this document to ${prettifyField(t.to_state).toLowerCase()}.`}
              onClick={() => act.mutate({ p_document_id: documentId, p_transition_code: t.code })}
            >
              {t.name}
            </ActionButton>
          );
        })}
      </div>
      {notes}
      <ErrorNote error={act.error} />
    </div>
  );
}
