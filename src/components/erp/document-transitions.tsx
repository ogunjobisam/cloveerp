import { prettifyField } from "../../lib/friendly";
import { byTone, transitionTone } from "../../lib/plain-words";
import { ActionButton, ErrorNote, useErpAction } from "./action";
import { manualTransitions, type Transition } from "./available-transitions";

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
  const act = useErpAction({
    fn: "erp_transition_document",
    invalidates: ["erp_document", "erp_documents", "erp_available_transitions"],
  });

  const manual = manualTransitions(documentType, transitions);
  const offered = byTone(
    manual.filter((t) => t.permitted && !t.is_automatic && !exclude.includes(t.code)),
  );

  if (offered.length === 0) {
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
        {offered.map((t) => (
          <ActionButton
            key={t.code}
            variant={
              transitionTone(t) === "out"
                ? "danger"
                : transitionTone(t) === "back" || !t.guard_passes
                  ? "secondary"
                  : "primary"
            }
            disabled={!t.guard_passes}
            busy={act.isPending}
            title={
              t.guard_passes
                ? `Moves this document to ${prettifyField(t.to_state).toLowerCase()}.`
                : "This document does not yet satisfy the condition on this transition."
            }
            onClick={() => act.mutate({ p_document_id: documentId, p_transition_code: t.code })}
          >
            {t.name}
          </ActionButton>
        ))}
      </div>
      <ErrorNote error={act.error} />
    </div>
  );
}
