/**
 * The invitation a person arrived with, held for the length of one tab.
 *
 * /join takes the token out of the address bar as soon as it has read it, so
 * it does not sit in history or get copied along with the URL. It still has to
 * survive signing in — a password round trip, or Google sending the browser
 * away and back — which is what sessionStorage is for: it outlives both, dies
 * with the tab, and is never sent to a server.
 *
 * Every read and write is guarded. There is no window during server rendering,
 * and a private window or blocked site data makes the storage accessor throw.
 */
export const INVITATION_STORAGE_KEY = "clove-erp.invitation";

/** A token is hex today; this only keeps obvious rubbish out of storage. */
const PLAUSIBLE = /^[A-Za-z0-9._~-]{32,512}$/;

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
  if (!PLAUSIBLE.test(value)) return;
  try {
    storage()?.setItem(INVITATION_STORAGE_KEY, value);
  } catch {
    /* storage full or blocked; the paste box on the onboarding screen still works */
  }
}

export function readStoredInvitation(): string | null {
  try {
    const value = storage()?.getItem(INVITATION_STORAGE_KEY) ?? null;
    return value && PLAUSIBLE.test(value) ? value : null;
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
