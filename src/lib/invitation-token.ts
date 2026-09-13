import { plausibleInvitationToken } from "./invitation-email";

/**
 * The invitation a person arrived with, held for the length of one tab.
 *
 * /join takes the token out of the address bar as soon as it has read it, so
 * it does not sit in history or get copied along with the URL. It still has to
 * survive signing in — the email's sign-in link sending the browser to Supabase
 * Auth and back, Google doing the same, or a password — which is what
 * sessionStorage is for: it outlives all three within the tab, dies with the
 * tab, and is never sent to a server.
 *
 * Every read and write is guarded. There is no window during server rendering,
 * and a private window or blocked site data makes the storage accessor throw.
 */
export const INVITATION_STORAGE_KEY = "clove-erp.invitation";

function storage(): Storage | null {
  if (typeof window === "undefined") return null;
  try {
    return window.sessionStorage;
  } catch {
    return null;
  }
}

export function storeInvitation(token: string): void {
  const value = token.trim();
  if (!plausibleInvitationToken(value)) return;
  try {
    storage()?.setItem(INVITATION_STORAGE_KEY, value);
  } catch {
    /* storage full or blocked; the join page still holds it for this visit */
  }
}

export function readStoredInvitation(): string | null {
  try {
    const value = storage()?.getItem(INVITATION_STORAGE_KEY) ?? null;
    return plausibleInvitationToken(value) ? value : null;
  } catch {
    return null;
  }
}

export function clearStoredInvitation(): void {
  try {
    storage()?.removeItem(INVITATION_STORAGE_KEY);
  } catch {
    /* nothing to clear if storage cannot be reached */
  }
}
