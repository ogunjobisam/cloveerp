import { createContext, useContext, useEffect } from "react";

import type { ErpSession } from "../../lib/erp";
import type { Scope } from "./shell";

/**
 * The session context lives in its own module on purpose.
 *
 * When it was declared inside gate.tsx, a dev-server hot update of that file
 * could leave a route component holding the *previous* module instance of the
 * context while the provider rendered the new one — two distinct context
 * objects, so the consumer read `null` and threw. A leaf module that only
 * declares the context keeps a single instance for everyone.
 */
export const ErpSessionContext = createContext<{
  session: ErpSession;
  scope: Scope;
} | null>(null);

export function useErpSession() {
  const ctx = useContext(ErpSessionContext);
  if (!ctx) throw new Error("useErpSession must be used inside the authenticated shell");
  return ctx;
}

/**
 * Which pages read the company and site chosen in the header.
 *
 * Most pages act on the whole organisation and never read that choice; the
 * header's "Where you are working" said records and totals followed it, which
 * was only true of creating a document and of Home. So a component that does
 * read it asks through useScope(), which registers it while it is mounted, and
 * the header can say plainly when the page in front of you ignores the choice.
 * Registration is counting, not fetching: nothing is loaded here.
 */
export const ScopeUsageContext = createContext<{ register: () => () => void } | null>(null);

export function useScope(reads = true): Scope {
  const { scope } = useErpSession();
  const usage = useContext(ScopeUsageContext);
  // A page that reads the choice says so; one that only wants to know what it
  // is — to decide whether it reads it — does not. Registering unconditionally
  // would make every module page claim to follow the site, which is the same
  // lie the header used to tell, pointing the other way.
  useEffect(() => (usage && reads ? usage.register() : undefined), [usage, reads]);
  return scope;
}
