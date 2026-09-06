/**
 * The cron-driven entrypoint.
 *
 * Same core as worker/src/main.ts — this file decides only when a pass
 * happens, never what a pass does. An Edge Function is short-lived, so it
 * drains once and returns rather than looping; point a schedule at it.
 *
 * Deploy:
 *   supabase functions deploy dispatch
 *   supabase secrets set CLOVEERP_DATABASE_URL=... CLOVEERP_TENANTS=... \
 *                        CLOVEERP_PRINCIPALS=... CLOVEERP_SYSTEMS=...
 *
 * No flags: supabase/config.toml carries verify_jwt and the import map now, so
 * the deploy and the preview branches agree by construction rather than by
 * whoever remembers the flag. That block is also what makes this function
 * deploy at all — an undeclared function is skipped.
 *
 * The imports below carry explicit .ts extensions and the core they reach does
 * too, because Deno requires them. Without that this file did not resolve past
 * its own first import, which nothing noticed until `deno check` was run on it
 * for the first time.
 *
 * The database connection must be a role that bypasses row-level security:
 * erp.set_job_principal() checks erp.session_is_trusted() and refuses
 * otherwise. That is the same trust boundary B1 already uses.
 */
import { loadConfig } from "../../../worker/src/core/config.ts";
import { connect } from "../../../worker/src/core/db.ts";
import { assertHandlersExist, drainOnce } from "../../../worker/src/core/drain.ts";

// deno-lint-ignore no-explicit-any
const Deno = (globalThis as any).Deno;

Deno.serve(async (req: Request) => {
  // A scheduler invoking this is the only legitimate caller. Requiring a shared
  // secret keeps a public function URL from becoming a way for anyone to drive
  // the outbox — the work itself is all gated, but the request rate is not.
  //
  // Unconditional. The first version stood down when the secret was unset,
  // which made "nobody configured it" indistinguishable from "anyone may call
  // it"; a function deployed without its secret now refuses every request and
  // says why, rather than serving the outbox to the internet.
  const expected = Deno.env.get("CLOVEERP_DISPATCH_SECRET");
  if (!expected) {
    return new Response(
      JSON.stringify({ error: "CLOVEERP_DISPATCH_SECRET is not set; the dispatch function refuses until it is" }),
      { status: 403, headers: { "content-type": "application/json" } },
    );
  }
  if (req.headers.get("x-dispatch-secret") !== expected) {
    return new Response("forbidden", { status: 403 });
  }

  let sql;
  try {
    const cfg = loadConfig(Deno.env.toObject());
    sql = connect(cfg.databaseUrl);
    await assertHandlersExist(sql);
    const report = await drainOnce(sql, cfg);

    return new Response(JSON.stringify(report), {
      headers: { "content-type": "application/json" },
    });
  } catch (err) {
    // 500 rather than a quiet 200: a scheduler that cannot tell a failed drain
    // from an empty one is the silent-job problem moved up a layer.
    return new Response(
      JSON.stringify({ error: (err as Error).message }),
      { status: 500, headers: { "content-type": "application/json" } },
    );
  } finally {
    await sql?.end({ timeout: 5 });
  }
});
