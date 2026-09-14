import { createMiddleware } from "@tanstack/react-start";

import { supabase } from "./erp";

/**
 * The signed-in person's bearer token, on a server function's request.
 *
 * A server function that acts as the caller (requireSupabaseAuth) needs the
 * caller's token in the Authorization header, and nothing put it there: the
 * generated attacher reads the integration client, which this application does
 * not sign in with. This reads the session the desk signed in through
 * (src/lib/erp.ts), and is attached only to the functions that ask for it.
 */
export const attachErpSession = createMiddleware({ type: "function" }).client(async ({ next }) => {
  const session = supabase ? (await supabase.auth.getSession()).data.session : null;
  const token = session?.access_token;
  return next({ headers: token ? { Authorization: `Bearer ${token}` } : {} });
});
