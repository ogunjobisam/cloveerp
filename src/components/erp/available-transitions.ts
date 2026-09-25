import { useQuery } from "@tanstack/react-query";

import { callErp } from "../../lib/erp";

/**
 * The moves a document's current state has, shared by the document's page and
 * the process strip so the two cannot offer different things. Drawn by
 * `DocumentTransitions`.
 */

export type Transition = {
  code: string;
  name: string;
  to_state: string;
  /** The caller holds the transition's `required_permission`. */
  permitted: boolean;
  /** The transition's guard evaluates true against this document's numbers. */
  guard_passes: boolean;
  is_automatic: boolean;
  /**
   * The refusal the door would raise for this move before it is pressed
   * (erp.transition_refusal, 20260923600000): an approval waiting on somebody
   * else, one refused, or one the caller asked for. Null when it would take it.
   */
  refused?: string | null;
};

/**
 * Whether a person can complete this move now: they may make it, its guard
 * passes against the document, and the door would not refuse it. A move that
 * fails any of these is not drawn (20260923600000); the database refuses it
 * regardless.
 */
export function isCompletable(t: Transition): boolean {
  return t.permitted && t.guard_passes && !t.is_automatic && !t.refused;
}

/**
 * The moves a document's current state has, as `erp_available_transitions`
 * reads them from the lifecycle the organisation promoted.
 *
 * `state` joins the key when the caller knows it: a move made elsewhere on the
 * screen changes the state a list reports, and the moves must follow it rather
 * than wait for the next poll.
 */
export function useAvailableTransitions(
  documentId: string,
  options: { enabled?: boolean; state?: string | null } = {},
) {
  return useQuery({
    queryKey: [
      "erp_available_transitions",
      { p_document_id: documentId },
      ...(options.state ? [options.state] : []),
    ],
    queryFn: () =>
      callErp<Transition[]>("erp_available_transitions", { p_document_id: documentId }),
    refetchInterval: 30_000,
    enabled: options.enabled ?? true,
  });
}

/**
 * Moves that another document or door makes, by document type, which are never
 * a button of their own.
 *
 * A lifecycle declares these moves so the state can be reached, but the state
 * means that something else exists: a purchase order is received because a
 * goods receipt was posted against it, a sales order is picked, despatched or
 * invoiced because stock was picked, a delivery left or an invoice was raised,
 * an invoice is paid because cash was applied or a payment run paid it, and an
 * invoice is credited because a credit note reversed it.
 * Pressed as a bare move, each would say so with nothing behind it — an order
 * marked received with no receipt, an order invoiced with no invoice, an
 * invoice credited with nothing owed back. So they
 * are left to their doors, which the screens offer by name: "Receive against an
 * order", "Pick the order", "Create a delivery from this order", "Invoice a
 * delivery", "Credit this invoice", "Apply cash", "Record payment".
 * Submitting, approving, sending,
 * posting, issuing, registering, disputing, closing and cancelling
 * stay buttons: each is the whole of what it records.
 *
 * `credit` joined the list on 19 September, with the mechanism that makes it:
 * the credit note door shipped on the 18th and left the invoice Issued, so the
 * bare button beside it was the only thing that could mark an invoice Credited
 * — terminally, with no credit note, no reversing journal and no goods back.
 * Issuing a credit note that covers the whole invoice now moves it
 * (erp.credit_invoices_for_credit_note, 20260919900000).
 *
 * A requisition's `order` joined the list on 22 September (20260922360000):
 * it reads Ordered because an order was raised from every line of it, which
 * "Convert to a purchase order" does, and the bare "Convert to order" beside it
 * marked a requisition ordered with no order anywhere. The same migration took
 * `receive_rest` off it. The receipt still makes that move, but a person may
 * now make it too, with the reason said, when the supplier will send nothing
 * more. That is a short close, and `EXPLAINED_MOVES` in document-transitions.tsx
 * asks for the reason.
 *
 * 20260922380000 added `inherit_approval`. An order is approved with its
 * requisition only by the conversion that raises it, unchanged and to the
 * supplier the requisition named, so it is never a button.
 *
 * The database refuses each of these moves pressed over nothing (the receipt,
 * the conversion and the cash are what it checks), so this is only what the
 * screens offer, not what holds them. Each entry here is a row in
 * erp.transition_driver_register() naming the routine that drives it, and the
 * test below holds the two lists to each other.
 */
export const DOOR_ONLY_TRANSITIONS: Readonly<Record<string, readonly string[]>> = {
  requisition: ["order"],
  purchase_order: ["inherit_approval", "receive_partial", "receive_all"],
  // Accepted because an order was raised from it (20260923400000).
  quotation: ["accept"],
  // Part despatched and the rest are the delivery's (20260923800000).
  sales_order: [
    "pick",
    "despatch",
    "despatch_part",
    "despatch_part_picked",
    "despatch_rest",
    "invoice",
  ],
  // Issued by "Issue the invoice", which numbers it in the same press
  // (20260923500000).
  sales_invoice: ["issue", "settle", "credit"],
  purchase_invoice: ["pay"],
  // Issued when its counts are raised and closed when the last is finished
  // (20260927100000).
  count_sheet: ["issue", "close"],
};

/** Whether a move of a document of this type is left to the door that makes it. */
export function isDoorOnlyTransition(
  documentType: string | null | undefined,
  code: string,
): boolean {
  if (!documentType) return false;
  return DOOR_ONLY_TRANSITIONS[documentType]?.includes(code) ?? false;
}

/** The moves a person may press: the lifecycle's, less those only a door makes. */
export function manualTransitions<T extends Pick<Transition, "code">>(
  documentType: string | null | undefined,
  transitions: readonly T[],
): T[] {
  return transitions.filter((t) => !isDoorOnlyTransition(documentType, t.code));
}

/** Whether a set of moves offers the caller anything, in the terms `DocumentTransitions` draws. */
export function offersAnyTransition(
  documentType: string | null | undefined,
  transitions: readonly Transition[],
  exclude: readonly string[] = [],
): boolean {
  return manualTransitions(documentType, transitions).some(
    (t) => isCompletable(t) && !exclude.includes(t.code),
  );
}

/** What each refusal the list can foresee says to the person who would have pressed. */
export const HELD_BECAUSE: Readonly<Record<string, string>> = {
  CLOVEERP_DOCUMENT_APPROVAL_PENDING: "Waiting on somebody else's approval.",
  CLOVEERP_DOCUMENT_APPROVAL_REJECTED:
    "The approval asked for was refused. Send it back to draft to change what was refused.",
  CLOVEERP_DOCUMENT_SELF_APPROVAL: "You asked for this approval, so somebody else gives it.",
  CLOVEERP_PERMISSION_DENIED:
    "This step is for somebody who may approve discounts or release credit.",
};

/** Said once when a move is held on its guard rather than on a refusal. */
export const HELD_ON_A_CONDITION =
  "Some moves wait on a condition this document does not meet yet.";

/**
 * Why the moves a person may make are not drawn: one line each, in the order
 * first met, and nothing for a move that is drawn (20260923600000).
 */
export function heldReasons(transitions: readonly Transition[]): string[] {
  const reasons: string[] = [];
  for (const t of transitions) {
    if (!t.permitted || t.is_automatic || isCompletable(t)) continue;
    const reason = t.refused ? (HELD_BECAUSE[t.refused] ?? null) : HELD_ON_A_CONDITION;
    if (reason && !reasons.includes(reason)) reasons.push(reason);
  }
  return reasons;
}
