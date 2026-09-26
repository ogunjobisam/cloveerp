import {
  HELD_BECAUSE,
  isCompletable,
  manualTransitions,
  type Transition,
} from "../components/erp/available-transitions";
import { byTone } from "./plain-words";

/**
 * The decision a list row offers on a document that waits for one
 * (PR11 M6).
 *
 * A transfer over its threshold waited in Pending approval, and the one place
 * it could be approved was the document's own page: the screen that listed it
 * showed the state and nothing to do about it. A row now carries the decision,
 * drawn exactly as the document page draws it, from the same read
 * (erp_available_transitions) and through the same door
 * (erp_transition_document), and only where the door would take it
 * (isCompletable: permitted, the guard passes, and erp.transition_refusal()
 * foresees no refusal).
 *
 * Nothing here names a document type. Any lifecycle whose waiting state is
 * `pending_approval` and whose decisions are `approve` and `reject` is served:
 * the transfer order's version 2 today, and the stock adjustment's the day its
 * lifecycle gains them.
 */

/** The moves that decide a document waiting for approval. */
export const DECISION_MOVES: readonly string[] = ["approve", "reject"];

/** The state a document waits for a decision in. */
export const AWAITING_DECISION = "pending_approval";

/**
 * Whether a row in this state waits for somebody's decision, and so whether its
 * moves are worth asking the database for. Every other row draws nothing, and
 * asks nothing: a list of two hundred transfers is not two hundred reads.
 */
export function awaitsDecision(state: string | null | undefined): boolean {
  return state === AWAITING_DECISION;
}

function decisions<T extends Transition>(
  documentType: string | null | undefined,
  moves: readonly T[],
) {
  return manualTransitions(documentType, moves).filter((t) => DECISION_MOVES.includes(t.code));
}

/**
 * The decisions this person can complete now, the way forward first. A move
 * the door would refuse is not among them, so no button is drawn over a
 * refusal.
 */
export function decisionMoves<T extends Transition>(
  documentType: string | null | undefined,
  moves: readonly T[],
): T[] {
  return byTone(decisions(documentType, moves).filter(isCompletable));
}

/**
 * The refusals a row says in words when it draws no decision: waiting on
 * somebody else, the person's own request, or a decision already refused.
 * Each is said once. A decision the person may not make at all says nothing,
 * as the document page says nothing for it; nor does a permission refusal,
 * whose words are about discounts and credit and not about a row like this.
 */
const SAID_ON_A_ROW: readonly string[] = [
  "CLOVEERP_DOCUMENT_APPROVAL_PENDING",
  "CLOVEERP_DOCUMENT_SELF_APPROVAL",
  "CLOVEERP_DOCUMENT_APPROVAL_REJECTED",
];

export function decisionHeld(
  documentType: string | null | undefined,
  moves: readonly Transition[],
): string[] {
  const reasons: string[] = [];
  for (const t of decisions(documentType, moves)) {
    if (!t.permitted || t.is_automatic || isCompletable(t) || !t.refused) continue;
    if (!SAID_ON_A_ROW.includes(t.refused)) continue;
    const reason = HELD_BECAUSE[t.refused];
    if (reason && !reasons.includes(reason)) reasons.push(reason);
  }
  return reasons;
}
