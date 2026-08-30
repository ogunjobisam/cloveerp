import { createContext, useContext } from "react";

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
