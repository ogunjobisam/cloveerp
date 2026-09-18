/**
 * The cron-driven entrypoint.
 *
 * Same core as worker/src/main.ts — this file decides only when a pass
 * happens, never what a pass does. An Edge Function is short-lived, so it
 * drains once and returns rather than looping; point a schedule at it.
 *
 * Deploy: nothing to type. supabase/config.toml declares this function, so the
 * Supabase GitHub integration deploys it from main with verify_jwt and the
 * import map that block carries; an undeclared function is skipped. And
 * .github/workflows/deploy.yml schedules it: after the replay it creates the
 * vault secret cloveerp_dispatch_secret inside the database when it is absent,
 * then runs erp.ensure_platform_schedule(<this function's URL>), whose pg_cron
 * job clove-dispatch posts here every minute with that secret, read from the
 * vault at fire time, in x-dispatch-secret. Its last step waits for a pass to be
 * recorded, which is the proof the whole path works.
 *
 * Secrets. None has to be set on Supabase; each is here for what it overrides:
 *   SUPABASE_DB_URL           injected into every Edge Function by the platform;
 *                             the connection used when CLOVEERP_DATABASE_URL is unset
 *   CLOVEERP_DATABASE_URL     a different connection (a role that bypasses RLS)
 *   CLOVEERP_DISPATCH_SECRET  a second accepted value for x-dispatch-secret, beside
 *                             the vault's: for a caller other than pg_cron, or a
 *                             host without the vault
 *   RESEND_API_KEY            already a project secret; without it no email leaves
 *   CLOVEERP_TENANTS / CLOVEERP_PRINCIPALS
 *                             both or neither: organisations served as a named
 *                             service principal. Every other active organisation is
 *                             served regardless, as erp.dispatch_bindings() lists it
 *   CLOVEERP_SYSTEMS          external system codes whose outbox and commands to drain
 *   CLOVEERP_WORKER_NAME      the name each pass is recorded under
 *
 * verify_jwt is false (supabase/config.toml says why at length): pg_cron's
 * request carries no Authorization header, so a gateway JWT check refused every
 * tick before this file ran. The gate is the secret, checked below before any
 * configuration is parsed or any work is claimed.
 *
 * The imports below carry explicit .ts extensions and the core they reach does
 * too, because Deno requires them. Without that this file did not resolve past
 * its own first import, which nothing noticed until `deno check` was run on it
 * for the first time.
 *
 * The database connection must be a role that bypasses row-level security:
 * erp.set_job_tenant() and erp.dispatch_bindings() check
 * erp.session_is_trusted() and refuse otherwise. That is the same trust
 * boundary B1 already uses.
 */
import { loadConfig } from "../../../worker/src/core/config.ts";
import { connect, type Sql } from "../../../worker/src/core/db.ts";
import { assertHandlersExist, drainOnce } from "../../../worker/src/core/drain.ts";

// deno-lint-ignore no-explicit-any
const Deno = (globalThis as any).Deno;

/** The vault entry deploy.yml creates and the clove-dispatch job signs with. */
const SECRET_NAME = "cloveerp_dispatch_secret";

/**
 * How long one isolate trusts what it read from the vault.
 *
 * Five minutes for a value: a warm isolate serves a tick a minute, and one read
 * in five is plenty for a secret nobody rotates by hand. A rotation is refused
 * for at most that long, and queued email simply waits. Thirty seconds for an
 * absence, so a stray request just before deploy.yml creates the secret cannot
 * hold the first real tick off for five minutes.
 *
 * The cache is also why a wrong header costs no database round trip once the
 * value is known: a mismatch is compared against the cache, never re-read.
 */
const VALUE_TTL_MS = 5 * 60_000;
const ABSENT_TTL_MS = 30_000;

let cached: { value: string | null; until: number } | null = null;
let reading: Promise<string | null> | null = null;

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

/** The same fallback worker/src/core/config.ts applies, needed before it runs. */
function databaseUrl(env: Record<string, string | undefined>): string | null {
  return env["CLOVEERP_DATABASE_URL"]?.trim() || env["SUPABASE_DB_URL"]?.trim() || null;
}

/** The vault's value, over this function's own connection, cached per isolate. */
function vaultSecret(sql: Sql): Promise<string | null> {
  if (cached !== null && cached.until > Date.now()) return Promise.resolve(cached.value);
  reading ??= (async () => {
    try {
      const rows = await sql`
        select s.decrypted_secret from vault.decrypted_secrets s where s.name = ${SECRET_NAME} limit 1`;
      const raw = rows[0]?.["decrypted_secret"];
      const value = typeof raw === "string" && raw.trim().length > 0 ? raw.trim() : null;
      cached = { value, until: Date.now() + (value === null ? ABSENT_TTL_MS : VALUE_TTL_MS) };
      return value;
    } finally {
      reading = null;
    }
  })();
  return reading;
}

/**
 * Whether two secrets are equal, in time that does not depend on where they
 * first differ. Both sides are hashed first, so the loop always walks 32 bytes
 * and the length of the expected value is not measurable either. `!==` stopped
 * at the first differing character.
 */
async function sameSecret(presented: string, expected: string): Promise<boolean> {
  const encoder = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(presented)),
    crypto.subtle.digest("SHA-256", encoder.encode(expected)),
  ]);
  const x = new Uint8Array(a);
  const y = new Uint8Array(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < x.length; i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

Deno.serve(async (req: Request) => {
  // A scheduler invoking this is the only legitimate caller. Requiring a shared
  // secret keeps a public function URL from becoming a way for anyone to drive
  // the outbox — the work itself is all gated, but the request rate is not.
  //
  // Unconditional. The first version stood down when the secret was unset,
  // which made "nobody configured it" indistinguishable from "anyone may call
  // it"; a function with no secret anywhere refuses every request and says why,
  // rather than serving the outbox to the internet.
  //
  // No header, no work of any kind: not even a connection is opened for it.
  const presented = (req.headers.get("x-dispatch-secret") ?? "").trim();
  if (presented.length === 0) {
    return new Response("forbidden", { status: 403 });
  }

  const env = Deno.env.toObject() as Record<string, string | undefined>;
  let sql: Sql | undefined;
  try {
    // The environment's value first, when there is one: it needs no connection.
    const fromEnv = env["CLOVEERP_DISPATCH_SECRET"]?.trim() || null;
    let accepted = fromEnv !== null && (await sameSecret(presented, fromEnv));

    // Then the vault's, which is the one pg_cron sends.
    let fromVault: string | null = null;
    if (!accepted) {
      const url = databaseUrl(env);
      if (url === null) {
        return json(
          {
            error:
              "neither CLOVEERP_DATABASE_URL nor SUPABASE_DB_URL is set, so the dispatch " +
              "secret cannot be read from the vault and nothing can be drained",
          },
          500,
        );
      }
      sql = connect(url, "edge_function");
      try {
        fromVault = await vaultSecret(sql);
      } catch (err) {
        // The detail is for the log, not for a caller who has not yet shown
        // the secret: a connection error can name a host.
        console.error(`[dispatch] the vault could not be read: ${(err as Error).message}`);
        return json({ error: "the dispatch secret could not be read from the vault; the function log says why" }, 500);
      }
      accepted = fromVault !== null && (await sameSecret(presented, fromVault));
    }

    if (!accepted) {
      if (fromEnv === null && fromVault === null) {
        return json(
          {
            error:
              `no dispatch secret exists: the vault has no ${SECRET_NAME} (deploy.yml creates it) ` +
              "and CLOVEERP_DISPATCH_SECRET is not set; the dispatch function refuses until one is",
          },
          403,
        );
      }
      return new Response("forbidden", { status: 403 });
    }

    const cfg = loadConfig(env);
    sql ??= connect(cfg.databaseUrl, "edge_function");
    await assertHandlersExist(sql);
    const report = await drainOnce(sql, cfg);

    // 500 when any stage failed, though every other organisation was served:
    // a scheduler that cannot tell a failed drain from an empty one is the
    // silent-job problem moved up a layer. The report is counts only; which
    // organisation failed, and why, is in this function's log.
    return json(report, report.failures > 0 ? 500 : 200);
  } catch (err) {
    return json({ error: (err as Error).message }, 500);
  } finally {
    await sql?.end({ timeout: 5 });
  }
});
