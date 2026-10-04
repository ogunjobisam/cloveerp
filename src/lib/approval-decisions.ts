/**
 * Who decided a document's approval, in a sentence.
 *
 * public.erp_document_approval_decisions returns every task asked on a
 * document: its step, whose it was, who decided it and how. An administrator
 * may approve for the people asked, or approve their own request, where the
 * organisation allows it (20260914098000), and the page says so plainly:
 * "Approved by Ada Lovelace as administrator, for Sam Carter".
 */

export type ApprovalDecision = {
  task_id: string;
  request_id: string;
  request_status: string;
  requested_at: string | null;
  requested_by: string | null;
  step: string;
  status: string;
  assignee: string | null;
  assignee_role: string | null;
  decided_by: string | null;
  decided_at: string | null;
  decided_via: "desk" | "email" | "administrator" | string;
  own_request: boolean;
  comment: string | null;
};

function who(name: string | null | undefined, fallback: string): string {
  const trimmed = (name ?? "").trim();
  return trimmed === "" ? fallback : trimmed;
}

/** The decision on one task, as the document page says it. */
export function decisionWords(d: ApprovalDecision): string {
  const asked = who(d.assignee, who(d.assignee_role, "the approving role"));
  const decider = who(d.decided_by, "somebody");

  switch (d.status) {
    case "pending":
      return `Waiting on ${asked}`;
    case "approved":
    case "rejected": {
      const verb = d.status === "approved" ? "Approved" : "Rejected";
      if (d.decided_via === "administrator") {
        const forWhom = d.own_request
          ? ", on their own request"
          : d.assignee && d.assignee.trim() !== "" && d.assignee !== d.decided_by
            ? `, for ${d.assignee.trim()}`
            : "";
        return `${verb} by ${decider} as administrator${forWhom}`;
      }
      if (d.decided_via === "email") return `${verb} by ${decider} from an approval email`;
      return `${verb} by ${decider}`;
    }
    case "delegated":
      return `Delegated by ${asked}`;
    case "escalated":
      return `Escalated from ${asked}`;
    case "cancelled":
      return "No longer needed";
    default:
      return d.status;
  }
}

/** True when any decision on the document was made as an administrator. */
export function anyAdministratorDecision(decisions: readonly ApprovalDecision[]): boolean {
  return decisions.some((d) => d.decided_via === "administrator");
}

/**
 * The comment beside a decision, or null where there is nothing to add.
 *
 * erp.approve_request_as_administrator writes "Approved as administrator" (or
 * "..., for the person asked") into the comment, and decisionWords already says
 * that in full, so the row read the same sentence twice (J-121). A comment
 * somebody typed is shown as typed.
 */
export function decisionComment(d: ApprovalDecision): string | null {
  const comment = (d.comment ?? "").trim();
  if (comment === "") return null;
  if (d.decided_via === "administrator" && comment.startsWith("Approved as administrator")) {
    return null;
  }
  return comment;
}

/**
 * Whether the latest routing stamp resolved any step.
 *
 * Only erp_stamp_document_approval writes a stamp, from the routing rules; a
 * document approved through its tasks has none, and a stamp taken where no
 * rule applied has no steps. Either way the routing card had nothing to show
 * and said so above the decisions that were really made (J-121).
 */
export function stampHasSteps(
  stamps: readonly { resolved_chain?: { steps?: readonly unknown[] } | null }[] | undefined,
): boolean {
  return (stamps?.[0]?.resolved_chain?.steps?.length ?? 0) > 0;
}
