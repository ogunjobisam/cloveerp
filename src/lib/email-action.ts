/**
 * A decision link from an approval email: what the page it opens reads, keeps
 * and says.
 *
 * The email's Approve and Reject buttons open /act#t=<token>&d=approve|reject.
 * The token only finds the approval task. It never signs anybody in and never
 * decides: the page asks the database who the link is for
 * (erp_email_action_peek, answered only to that person, signed in), shows what
 * is being asked, and decides only when the person presses the one button, as
 * themselves, through erp_decide_approval_from_email, where every rule of a
 * desk decision applies.
 *
 * Everything after the # stays in the browser, so no server, proxy or link
 * scanner receives the token. The page takes it out of the address bar on
 * arrival and keeps it for this tab only, which is what lets it survive
 * signing in — Google and a sign-in link both leave the page and come back —
 * the same way /join keeps an invitation (lib/invitation-token.ts).
 *
 * Pure apart from sessionStorage, which every read and write guards.
 */

import { formatMinor } from "./money";

export type ActDecision = "approve" | "reject";

export type ActArrival = { token: string | null; decision: ActDecision | null };

/** 32 random bytes, as hex: what erp.claim_email_batch() mints. */
const TOKEN = /^[0-9a-f]{64}$/;

export function plausibleActionToken(value: unknown): value is string {
  return typeof value === "string" && TOKEN.test(value);
}

function decisionOf(value: unknown): ActDecision | null {
  return value === "approve" || value === "reject" ? value : null;
}

/** The token and the decision the address's fragment carries, if they look right. */
export function readActArrival(hash: string): ActArrival {
  const fragment = new URLSearchParams(hash.replace(/^#/, ""));
  const token = fragment.get("t")?.trim() ?? "";
  return {
    token: plausibleActionToken(token) ? token : null,
    decision: decisionOf(fragment.get("d")),
  };
}

/* -------------------------------------------------------------------------- */
/* Held for this tab                                                          */
/* -------------------------------------------------------------------------- */

export const ACT_STORAGE_KEY = "clove-erp.email-action";

function storage(): Storage | null {
  if (typeof window === "undefined") return null;
  try {
    return window.sessionStorage;
  } catch {
    return null;
  }
}

export function storeAction(arrival: ActArrival): void {
  if (!arrival.token) return;
  try {
    storage()?.setItem(
      ACT_STORAGE_KEY,
      JSON.stringify({ token: arrival.token, decision: arrival.decision }),
    );
  } catch {
    /* storage full or blocked; the page still holds it for this visit */
  }
}

export function readStoredAction(): ActArrival {
  try {
    const raw = storage()?.getItem(ACT_STORAGE_KEY) ?? null;
    if (!raw) return { token: null, decision: null };
    const parsed = JSON.parse(raw) as { token?: unknown; decision?: unknown };
    return plausibleActionToken(parsed.token)
      ? { token: parsed.token, decision: decisionOf(parsed.decision) }
      : { token: null, decision: null };
  } catch {
    return { token: null, decision: null };
  }
}

export function clearStoredAction(): void {
  try {
    storage()?.removeItem(ACT_STORAGE_KEY);
  } catch {
    /* nothing to clear if storage cannot be reached */
  }
}

/* -------------------------------------------------------------------------- */
/* What the database says about a link                                        */
/* -------------------------------------------------------------------------- */

/** What public.erp_email_action_peek() returns. */
export type EmailActionPeek = {
  tenant_id: string;
  tenant_name: string | null;
  in_active_organisation: boolean;
  state: "usable" | "expired" | "used" | "superseded";
  decision: ActDecision | null;
  expires_at: string | null;
  task_id: string;
  document_id: string | null;
  summary: {
    object_type?: string;
    document_type?: string;
    document_number?: string;
    partner?: string;
    value_minor?: number;
    currency?: string;
    minor_units?: number;
    step?: string;
    requested_by?: string;
    requested_at?: string;
    due_at?: string;
  };
};

/** The refusal token an error leads with, as the engine wrote it. */
export function refusalCode(error: unknown): string | null {
  const message = error instanceof Error ? error.message : typeof error === "string" ? error : "";
  return /^((?:CLOVEERP|ERPWARE)_[A-Z0-9_]+)/.exec(message)?.[1] ?? null;
}

export type ActView =
  | "nothing"
  | "checking"
  | "not_for_you"
  | "unavailable"
  | "wrong_organisation"
  | "usable"
  | "expired"
  | "used"
  | "superseded";

/**
 * Which of the page's states to show.
 *
 * The session's organisation is compared as well as the door's own answer, so
 * the page moves to the confirm step as soon as a switch lands, before the
 * look is asked again.
 */
export function actView(input: {
  token: string | null;
  peek: EmailActionPeek | undefined;
  peekError: unknown;
  pending: boolean;
  sessionTenantId: string | null;
}): ActView {
  if (!input.token) return "nothing";
  if (input.peekError) {
    return refusalCode(input.peekError) === "CLOVEERP_EMAIL_ACTION_NOT_FOR_YOU"
      ? "not_for_you"
      : "unavailable";
  }
  if (input.pending || !input.peek) return "checking";
  const peek = input.peek;
  if (peek.state !== "usable") return peek.state;
  return peek.tenant_id === input.sessionTenantId ? "usable" : "wrong_organisation";
}

/** A refusal from pressing the button that says the link itself has moved on. */
export function viewForRefusal(error: unknown): ActView | null {
  switch (refusalCode(error)) {
    case "CLOVEERP_EMAIL_ACTION_NOT_FOR_YOU":
      return "not_for_you";
    case "CLOVEERP_EMAIL_ACTION_WRONG_ORGANISATION":
      return "wrong_organisation";
    case "CLOVEERP_EMAIL_ACTION_EXPIRED":
      return "expired";
    case "CLOVEERP_EMAIL_ACTION_USED":
      return "used";
    case "CLOVEERP_EMAIL_ACTION_SUPERSEDED":
      return "superseded";
    default:
      return null;
  }
}

/** The heading and sentence for a state that is not a decision to make. */
export function explain(
  view: ActView,
  organisation?: string | null,
): {
  heading: string;
  body: string;
} {
  switch (view) {
    case "nothing":
      return {
        heading: "Nothing to decide here",
        body: "This page opens from the Approve and Reject buttons in an approval email, and this visit did not bring one. Your approvals are on My approvals.",
      };
    case "checking":
      return { heading: "Finding the request", body: "Checking what this link is for." };
    case "not_for_you":
      return {
        heading: "This link is not for this account",
        body: "A link in an approval email works only for the person it was sent to, signed in as themselves. If the email was sent to you, sign out and sign in with the address it came to.",
      };
    case "unavailable":
      return {
        heading: "The request could not be found",
        body: "Clove ERP could not check this link just now. Try again in a moment, or open the request from My approvals.",
      };
    case "wrong_organisation":
      return {
        heading: organisation
          ? `This request belongs to ${organisation}`
          : "This request belongs to another organisation",
        body: "A decision is recorded in the organisation you are working in. Switch to the organisation the request belongs to, then decide it.",
      };
    case "expired":
      return {
        heading: "This link has run out",
        body: "A link in an approval email works for seven days at most, and not past the day the decision is due. The request may still be waiting for you: open it from My approvals.",
      };
    case "used":
      return {
        heading: "This link has already been used",
        body: "Each link in an approval email works once, and this one has made its decision. Open the request to see where it has got to.",
      };
    case "superseded":
      return {
        heading: "This request has moved on",
        body: "Since the email was sent, the request was decided at the desk or by somebody else, what is being approved changed, or a newer email replaced this one. Open the request to see what it says now.",
      };
    case "usable":
      return { heading: "Your approval is needed", body: "" };
  }
}

/** What happened after the button was pressed, in one sentence. */
export function outcomeWords(decision: ActDecision, status: string | null | undefined): string {
  if (decision === "reject") {
    return "You rejected the request. It goes back to whoever asked for it, with your reason.";
  }
  return status === "approved"
    ? "You approved the request. Nothing else is waiting on it."
    : "You approved the request. It now waits for the next approver.";
}

/** The request as rows of label and value, leaving out what it does not have. */
export function summaryRows(
  peek: EmailActionPeek,
  formatInstant: (iso: string) => string = (iso) => new Date(iso).toLocaleString(),
): { label: string; value: string }[] {
  const s = peek.summary;
  const value =
    typeof s.value_minor === "number" && s.currency
      ? formatMinor(s.value_minor, s.currency, s.minor_units ?? 2)
      : null;
  const rows: [string, string | null | undefined][] = [
    ["Organisation", peek.tenant_name],
    ["Document", s.document_type],
    ["Number", s.document_number],
    ["Business partner", s.partner],
    ["Value", value],
    ["Approval step", s.step],
    ["Requested by", s.requested_by],
    ["Requested", s.requested_at ? formatInstant(s.requested_at) : null],
    ["Decision due by", s.due_at ? formatInstant(s.due_at) : null],
  ];
  return rows.flatMap(([label, v]) =>
    typeof v === "string" && v.trim() !== "" ? [{ label, value: v }] : [],
  );
}
