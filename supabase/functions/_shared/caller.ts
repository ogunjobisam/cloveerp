/**
 * What every function the browser calls on a person's behalf needs first.
 *
 * One Supabase project per client, one subdomain each (7 October): the work
 * that used to run in the application's own server — rendering an invoice,
 * signing a link to a stored document, answering a supplier's link — moved
 * into Edge Functions so that it runs in each client's own project with that
 * project's own keys, and the application's server holds no client's key at
 * all. These helpers are the ones supabase/functions/invite wrote first: the
 * project's keys from its environment, the bearer a request carries, whether
 * Supabase Auth says it is a real signed-in person, the reply shape and the
 * CORS headers the browser's client needs.
 *
 * Imported by path from the functions beside this folder; no index.ts here,
 * so the deploy loop never treats it as a function.
 */

// deno-lint-ignore no-explicit-any
const Deno = (globalThis as any).Deno;

export function env(name: string): string | null {
  const value = Deno.env.get(name);
  return typeof value === "string" && value.trim() !== "" ? value.trim() : null;
}

/** Refuse to start half-configured, naming the variable. */
export function required(name: string): string {
  const value = env(name);
  if (!value) throw new Error(`${name} is not set`);
  return value;
}

/**
 * A project key by its legacy name, or the default entry of the JSON map that
 * replaces it. Supabase injects both during the move to the new key format.
 */
export function projectKey(legacy: string, map: string): string {
  const direct = env(legacy);
  if (direct) return direct;
  const raw = env(map);
  if (raw) {
    try {
      const parsed = JSON.parse(raw) as Record<string, unknown>;
      const value = parsed["default"];
      if (typeof value === "string" && value.trim() !== "") return value.trim();
    } catch {
      /* not JSON; refused below */
    }
  }
  throw new Error(`neither ${legacy} nor ${map}.default is set`);
}

/** The three things every function here reads from its own project. */
export function project(): { url: string; anonKey: string; serviceKey: string } {
  return {
    url: required("SUPABASE_URL").replace(/\/+$/, ""),
    anonKey: projectKey("SUPABASE_ANON_KEY", "SUPABASE_PUBLISHABLE_KEYS"),
    serviceKey: projectKey("SUPABASE_SERVICE_ROLE_KEY", "SUPABASE_SECRET_KEYS"),
  };
}

/**
 * The request's own origin, echoed. A request carries its session as a bearer
 * header and never as a cookie, so a page on another origin can do nothing
 * here without a session it could not have. The header list is the one
 * supabase-js sends: a header missing from the preflight fails the whole
 * request in the browser before it is sent, and says so nowhere.
 */
export function cors(req: Request): Record<string, string> {
  return {
    "access-control-allow-origin": req.headers.get("origin") ?? "*",
    "access-control-allow-headers":
      "authorization, x-client-info, apikey, content-type, x-retry-count, traceparent, tracestate, baggage",
    "access-control-allow-methods": "POST, OPTIONS",
    "access-control-max-age": "86400",
    vary: "origin",
  };
}

export function reply(req: Request, status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store", ...cors(req) },
  });
}

export function bearerOf(req: Request): string | null {
  const header = req.headers.get("authorization") ?? "";
  const match = /^Bearer\s+(\S+)$/i.exec(header.trim());
  return match ? match[1] : null;
}

/**
 * A real signed-in user, as Supabase Auth says, by the account's id; null for
 * anybody else. The anon key is a JWT too, and is not one.
 */
export async function signedIn(
  url: string,
  anonKey: string,
  bearer: string,
): Promise<string | null> {
  if (bearer === anonKey) return null;
  const response = await fetch(`${url}/auth/v1/user`, {
    headers: { apikey: anonKey, authorization: `Bearer ${bearer}` },
  });
  if (response.status >= 500) {
    throw new Error(`auth/v1/user answered ${response.status}`);
  }
  if (!response.ok) {
    await response.body?.cancel();
    return null;
  }
  const user = (await response.json()) as { id?: unknown };
  return typeof user.id === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(user.id)
    ? user.id
    : null;
}

/**
 * A refusal from the database is already plain language; keep its code. The
 * same sentence the application's server used to throw, now thrown here and
 * answered as JSON the browser turns back into a refusal it can word.
 */
export function refuse(message: string): never {
  const match = /(CLOVEERP_[A-Z_]+)\s*:?\s*(.*)/.exec(message);
  throw new Error(match ? `${match[1]}: ${(match[2] ?? "").trim() || message}` : message);
}

/**
 * What went wrong, as the browser reads it: { error, code?, hint? }. A
 * refusal the database made (CLOVEERP_…) is a 409, a bad request a 400, and
 * anything else a 500 that says what it can without a secret in it.
 */
export function failure(req: Request, error: unknown): Response {
  const message = error instanceof Error ? error.message : String(error);
  const match = /^(CLOVEERP_[A-Z_]+):\s*(.*)$/s.exec(message);
  if (match) {
    return reply(req, 409, { error: message, code: match[1] });
  }
  console.error(message);
  return reply(req, 500, { error: message.slice(0, 300) || "The function failed." });
}

/** The request's JSON body, or null when it is not JSON. */
export async function jsonBody(req: Request): Promise<unknown> {
  try {
    return await req.json();
  } catch {
    return null;
  }
}
