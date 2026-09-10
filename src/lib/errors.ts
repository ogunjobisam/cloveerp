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
  return (
    /permission denied for (?:schema|table|function|relation) ([\w.]+)/.exec(message)?.[1] ?? null
  );
}

/**
 * The refusal register, D34 (§21.1).
 *
 * `erp_ref.refusal` says, for each engine token, what was refused, why, and
 * the next action — and mirrors the three into the resource dictionary as
 * `refusal.<token>.refused`, `.why` and `.next_action`, lower-cased. The
 * dictionary already arrives with every other string through erp_resources(),
 * with the organisation's own overrides applied, so this file does not fetch
 * anything: the ResourceProvider hands the loaded dictionary here once, and a
 * refusal resolves through it before falling back to the wording below.
 *
 * A family token — CLOVEERP_QUOTE_IS_ACCEPTED, raised with the state as a
 * suffix — is registered once as CLOVEERP_QUOTE_IS_% and mirrors with the
 * suffix dropped, so a family key ends in an underscore and matches by prefix.
 */
let refusalResources: Record<string, string> = {};
let refusalFamilies: string[] = [];

/**
 * Both prefixes, for one release.
 *
 * 20260904980000 moved every refusal from ERPWARE_ to CLOVEERP_. The database
 * and this site are deployed separately and by hand, so between the two there
 * is a window where one is ahead of the other — and in that window a lookup
 * pinned to a single spelling finds nothing, the register is never consulted,
 * and the person who tripped the refusal reads raw database text instead of
 * what was refused and what to do next.
 *
 * Accepting both costs one extra dictionary lookup and takes the deploy order
 * off the list of things somebody has to get right. Delete the retired half —
 * this pair of constants, alternate(), the second branch in registeredRefusal()
 * and the tests that pin them — once both sides have been carried.
 */
const PREFIX = "CLOVEERP_";
const RETIRED_PREFIX = "ERPWARE_";

/** The same token spelled under the other prefix, or null if it has neither. */
function alternate(token: string): string | null {
  if (token.startsWith(PREFIX)) return RETIRED_PREFIX + token.slice(PREFIX.length);
  if (token.startsWith(RETIRED_PREFIX)) return PREFIX + token.slice(RETIRED_PREFIX.length);
  return null;
}

export function setRefusalResources(resources: Record<string, string>): void {
  refusalResources = resources;
  refusalFamilies = Object.keys(resources)
    .map((k) => /^refusal\.((?:cloveerp|erpware)_[a-z0-9_]*_)\.next_action$/.exec(k)?.[1])
    .filter((k): k is string => Boolean(k));
}

function resolveRefusal(
  token: string,
): { refused: string; why: string | null; nextAction: string } | null {
  const exact = token.toLowerCase();
  const code =
    refusalResources[`refusal.${exact}.next_action`] !== undefined
      ? exact
      : refusalFamilies.find((f) => exact.startsWith(f));
  if (!code) return null;
  const nextAction = refusalResources[`refusal.${code}.next_action`];
  const refused = refusalResources[`refusal.${code}.refused`];
  if (!nextAction || !refused) return null;
  return { refused, why: refusalResources[`refusal.${code}.why`] ?? null, nextAction };
}

function registeredRefusal(
  token: string,
): { refused: string; why: string | null; nextAction: string } | null {
  const found = resolveRefusal(token);
  if (found) return found;
  const other = alternate(token);
  return other ? resolveRefusal(other) : null;
}

const REFUSAL_MESSAGES: Record<string, { title: string; body: string }> = {
  CLOVEERP_PERMISSION_DENIED: {
    title: "You do not have permission to do this.",
    body: "An administrator can grant the missing permission on the Permissions screen.",
  },
  CLOVEERP_TENANT_FROZEN: {
    title: "This tenant is frozen.",
    body: "Changes are blocked while the tenant is being exported or deleted.",
  },
  CLOVEERP_PERIOD_CLOSED: {
    title: "That accounting period is closed.",
    body: "Reopen the period, or post the entry into an open one.",
  },
  CLOVEERP_NO_PRICE_TO_POST: {
    title: "This document has no price on any line.",
    body: "Add a unit price to each line and post it again. A despatch raised from an order takes the order's price, so a missing price usually means the line was added by hand.",
  },
  CLOVEERP_ALREADY_RESERVED: {
    title: "That line already holds stock.",
    body: "The reservation is in place; pick the order rather than reserving it again.",
  },
};

/** This map is ours, so it is keyed once and the retired spelling is folded in. */
function builtInMessage(token: string): { title: string; body: string } | undefined {
  const other = alternate(token);
  return REFUSAL_MESSAGES[token] ?? (other ? REFUSAL_MESSAGES[other] : undefined);
}

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

  const token = erp?.erpCode;
  const registered = token ? registeredRefusal(token) : null;
  if (token && registered) {
    // What was refused, why, and the next action — the organisation's own
    // wording where it has overridden the product's. The engine's hint, when
    // the raise carried one, is more specific than the register and wins.
    return {
      title: registered.refused,
      body: registered.why,
      hint: hint ?? registered.nextAction,
      technical,
    };
  }
  const builtIn = token ? builtInMessage(token) : undefined;
  if (builtIn) {
    return out(builtIn.title, builtIn.body);
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

  if (/invalid login credentials/i.test(raw)) {
    return out("That email and password do not match.", "Check both and try again.");
  }
  if (/email not confirmed/i.test(raw)) {
    return out(
      "This email is not confirmed yet.",
      "Open the confirmation link we sent you, then sign in.",
    );
  }
  if (/rate limit|too many requests/i.test(raw)) {
    return out("Too many attempts.", "Wait a moment before trying again.");
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
