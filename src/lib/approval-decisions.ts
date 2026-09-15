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
