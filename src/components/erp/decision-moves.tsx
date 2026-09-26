import { awaitsDecision, decisionHeld, decisionMoves } from "../../lib/decision-moves";
import { useT } from "../../lib/i18n";
import { transitionTone } from "../../lib/plain-words";
import { ActionButton, ErrorNote, useErpAction } from "./action";
import { useAvailableTransitions } from "./available-transitions";

/**
 * Approve and Reject on a list row, for a document waiting for a decision
 * (PR11 M6).
 *
 * The moves are the database's: erp_available_transitions for this document,
 * less what a door makes, drawn only where erp_transition_document would take
 * them (src/lib/decision-moves.ts). A row not waiting asks nothing and draws
 * nothing. Where the approval is not the reader's to give, the row says why in
 * the words the document page uses, once.
 *
 * The database refuses an approval given by the wrong person regardless; this
 * only stops the screen offering one.
 */
export function DecisionMoves({
  documentId,
  documentNumber,
  documentType,
  state,
  invalidates,
}: {
  documentId: string;
  /** What the buttons are called to a screen reader, beside their verb. */
  documentNumber: string;
  documentType: string;
  state: string | null;
  /** The reads the row's list comes from, made stale by a decision. */
  invalidates: string[];
}) {
  const { ui } = useT();
  const waiting = awaitsDecision(state);
  const moves = useAvailableTransitions(documentId, { enabled: waiting, state });
  const act = useErpAction({
    fn: "erp_transition_document",
    invalidates: [
      ...invalidates,
      "erp_documents",
      "erp_document",
      "erp_available_transitions",
      "erp_document_approval_chain",
      "erp_my_approvals",
    ],
  });

  if (!waiting || !moves.data) return null;
  const offered = decisionMoves(documentType, moves.data);
  // Said beside what is drawn as well: the person who raised a transfer may
  // send it back to draft, and is told the approval is not theirs to give.
  const held = decisionHeld(documentType, moves.data);
  if (offered.length === 0 && held.length === 0 && !act.error) return null;

  return (
    <div className="mt-2 flex flex-col gap-1.5">
      {offered.length > 0 ? (
        <div className="flex flex-wrap gap-2">
          {offered.map((t) => (
            <ActionButton
              key={t.code}
              variant={transitionTone(t) === "forward" ? "primary" : "secondary"}
              busy={act.isPending}
              ariaLabel={`${t.name} ${documentNumber}`}
              onClick={() => act.mutate({ p_document_id: documentId, p_transition_code: t.code })}
            >
              {t.name}
            </ActionButton>
          ))}
        </div>
      ) : null}
      {held.map((reason) => (
        <p key={reason} className="text-xs text-muted-foreground">
          {ui(reason)}
        </p>
      ))}
      <ErrorNote error={act.error} />
    </div>
  );
}
