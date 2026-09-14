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
};

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
 * and an invoice is paid because cash was applied or a payment run paid it.
 * Pressed as a bare move, each would say so with nothing behind it — an order
 * marked received with no receipt, an order invoiced with no invoice. So they
 * are left to their doors, which the screens offer by name: "Receive against an
 * order", "Pick the order", "Create a delivery from this order", "Invoice a
 * delivery", "Apply cash", "Record payment". Submitting, approving, sending,
 * posting, issuing, registering, disputing, crediting, closing and cancelling
 * stay buttons: each is the whole of what it records.
 *
 * The database still performs these moves for whoever holds the permission;
 * this is only what the screens offer.
 */
export const DOOR_ONLY_TRANSITIONS: Readonly<Record<string, readonly string[]>> = {
  purchase_order: ["receive_partial", "receive_rest", "receive_all"],
  sales_order: ["pick", "despatch", "invoice"],
  sales_invoice: ["settle"],
  purchase_invoice: ["pay"],
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
    (t) => t.permitted && !t.is_automatic && !exclude.includes(t.code),
  );
}
