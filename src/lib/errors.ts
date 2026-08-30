import { ErpError } from "./erp";

/**
 * Plain-language failures.
 *
 * The engine speaks Postgres: `duplicate key value violates unique constraint
 * "change_set_tenant_id_code_key"` is precise and completely useless to the
 * person who pressed Install. Every screen renders through here, so a failure
 * arrives as a sentence about what happened and what to do, with the raw
 * database text kept — folded away — for whoever needs it.
 */
export type FriendlyError = {
  /** One short sentence: what happened. */
  title: string;
  /** What to do about it, when there is something to do. */
  body: string | null;
  /** The engine's own next-step hint, when it supplied one. */
  hint: string | null;
  /** Verbatim database text, shown only on request. */
  technical: string | null;
};

/** `duplicate key ... constraint "x_y_key"` → `x_y_key`. */
function constraintName(message: string): string | null {
  return /unique constraint "([^"]+)"/.exec(message)?.[1] ?? null;
}

/** `permission denied for schema erp_meta` → `erp_meta`. */
function deniedObject(message: string): string | null {
  return /permission denied for (?:schema|table|function|relation) ([\w.]+)/.exec(message)?.[1] ?? null;
}

const ERPWARE_MESSAGES: Record<string, { title: string; body: string }> = {
  ERPWARE_PERMISSION_DENIED: {
    title: "You do not have permission to do this.",
    body: "An administrator can grant the missing permission on the Permissions screen.",
  },
  ERPWARE_TENANT_FROZEN: {
    title: "This tenant is frozen.",
    body: "Changes are blocked while the tenant is being exported or deleted.",
  },
  ERPWARE_PERIOD_CLOSED: {
    title: "That accounting period is closed.",
    body: "Reopen the period, or post the entry into an open one.",
  },
};

/** Turn any thrown value into something worth reading. */
export function friendlyError(error: unknown): FriendlyError {
  if (!error) return { title: "Something went wrong.", body: null, hint: null, technical: null };

  const raw = error instanceof Error ? error.message : String(error);
  const erp = error instanceof ErpError ? error : null;
  const technical = [raw, erp?.details].filter(Boolean).join(" — ") || null;
  const hint = erp?.hint ?? null;
  const out = (title: string, body: string | null = null): FriendlyError => ({
    title,
    body,
    hint,
    technical,
  });

  const token = erp?.erpwareCode;
  if (token && ERPWARE_MESSAGES[token]) {
    const m = ERPWARE_MESSAGES[token];
    return out(m.title, m.body);
  }
  if (token) {
    // An engine rule we have no wording for: show its own words, minus the token.
    return out("This is not allowed right now.", raw.replace(token, "").replace(/^[:\s-]+/, ""));
  }

  if (erp?.isPermissionDenied || /permission denied/i.test(raw)) {
    const obj = deniedObject(raw);
    return out(
      "You do not have permission to do this.",
      obj
        ? `Your role cannot reach ${obj}. An administrator can grant the missing permission on the Permissions screen.`
        : "An administrator can grant the missing permission on the Permissions screen.",
    );
  }

  switch (erp?.code) {
    case "23505": {
      const c = constraintName(raw) ?? "";
      if (c.startsWith("change_set")) {
        return out(
          "This module has already been set up.",
          "Installing it again would author a second change set with the same code. Open Change requests to review or promote the existing one.",
        );
      }
      return out(
        "That already exists.",
        "Something with the same code or name is already on file. Choose a different code, or open the existing record.",
      );
    }
    case "23503":
      return out(
        "Something this depends on is missing.",
        "A record it points at no longer exists. Refresh the page and try again.",
      );
    case "23502":
      return out("A required value is missing.", "Fill in every required field and try again.");
    case "23514":
      return out(
        "That value is not allowed.",
        "It falls outside the range this field accepts. Check the value and try again.",
      );
    case "22P02":
    case "22003":
      return out(
        "One of the values is not in the expected format.",
        "Check numbers, dates and codes, then try again.",
      );
    case "PGRST202":
      return out(
        "This action is not available yet.",
        "The operation behind this button is not installed on your workspace.",
      );
    case "PGRST301":
    case "401":
      return out("Your session has expired.", "Sign in again to continue.");
    default:
      break;
  }

  if (/failed to fetch|networkerror|load failed/i.test(raw)) {
    return out("Could not reach the server.", "Check your connection and try again.");
  }
  if (/timeout|statement canceled/i.test(raw)) {
    return out("That took too long.", "The request was cancelled. Try a narrower selection.");
  }

  // Nothing matched: the message is likely an engine sentence already.
  return out("This did not work.", raw);
}
