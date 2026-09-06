/**
 * The other end of the wire, for the build.
 *
 * The dispatch worker delivers commands to external systems and email to
 * Resend, and until this file nothing in CI ever received either: the queues
 * were proven to claim and settle, never to reach anything. This is a receiver
 * that records what arrived and answers the way the real ones do, so a build
 * can submit a command and an email, run one pass of the worker, and read back
 * that exactly one request was made for each, with its idempotency key.
 *
 *   POST /orders    — an external system. Records the body and the
 *                     idempotency-key header; answers 200 {"ok":true}. A
 *                     second request with a key already seen is answered 200
 *                     and counted separately, so a retry can be told from a
 *                     repeat.
 *   POST /emails    — Resend's shape. Answers 200 {"id":"stub_<n>"}.
 *   GET  /received  — what has arrived: counts and keys, as JSON.
 *   GET  /health    — 200 when listening.
 *
 * Usage: bun run supabase/ci/stub_endpoint.ts [port]   (default 8788)
 */

type Received = {
  orders: number;
  orderKeys: string[];
  duplicateKeys: number;
  emails: number;
  emailIds: string[];
  lastOrder: unknown;
  lastEmail: unknown;
};

const received: Received = {
  orders: 0,
  orderKeys: [],
  duplicateKeys: 0,
  emails: 0,
  emailIds: [],
  lastOrder: null,
  lastEmail: null,
};

const port = Number(process.argv[2] ?? process.env["STUB_PORT"] ?? 8788);

/**
 * Per-route evidence, for the recovery rehearsal: every POST is logged under
 * its path with its key, so a script can read back exactly how many requests
 * each system received and in what order.
 *
 *   POST /orders/hang   — the first request ever on this route is never
 *                         answered (the endpoint stopped mid-command); later
 *                         requests are answered 200. What a worker's timeout
 *                         and the ambiguous state are for.
 *   POST /orders/flaky  — the first request is answered 503; later requests
 *                         200. What a backoff is for.
 */
type Route = {
  requests: number;
  keys: string[];
  duplicateKeys: number;
  log: { at: string; key: string | null }[];
};
const routes: Record<string, Route> = {};
const statusPublished: { key: string | null; body: unknown }[] = [];
const feeds: Record<string, { indicator: string; description: string }> = {};
const route = (path: string): Route =>
  (routes[path] ??= { requests: 0, keys: [], duplicateKeys: 0, log: [] });

function record(path: string, key: string | null): Route {
  const r = route(path);
  r.requests += 1;
  r.log.push({ at: new Date().toISOString(), key });
  if (key) {
    if (r.keys.includes(key)) r.duplicateKeys += 1;
    else r.keys.push(key);
  }
  return r;
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

const server = Bun.serve({
  port,
  async fetch(req: Request) {
    const url = new URL(req.url);
    if (req.method === "GET" && url.pathname === "/health") return json({ ok: true });
    if (req.method === "GET" && url.pathname === "/received") return json({ ...received, routes });

    if (req.method === "POST" && url.pathname === "/orders") {
      const key = req.headers.get("idempotency-key");
      received.orders += 1;
      received.lastOrder = await req.json().catch(() => null);
      if (key) {
        if (received.orderKeys.includes(key)) received.duplicateKeys += 1;
        else received.orderKeys.push(key);
      }
      record(url.pathname, key);
      return json({ ok: true, idempotency_key: key });
    }

    if (req.method === "POST" && url.pathname === "/orders/hang") {
      const key = req.headers.get("idempotency-key");
      await req.json().catch(() => null);
      const r = record(url.pathname, key);
      if (r.requests === 1) {
        // Never answered. The connection stays open until the client gives up.
        await new Promise<void>(() => {});
      }
      return json({ ok: true, idempotency_key: key });
    }

    if (req.method === "POST" && url.pathname === "/orders/flaky") {
      const key = req.headers.get("idempotency-key");
      await req.json().catch(() => null);
      const r = record(url.pathname, key);
      if (r.requests === 1) return json({ error: "not now" }, 503);
      return json({ ok: true, idempotency_key: key });
    }

    // A status page: what an incident update looks like when it leaves the
    // building. Records the body under its key like any other route.
    if (req.method === "POST" && url.pathname === "/status/publish") {
      const key = req.headers.get("idempotency-key");
      const body = await req.json().catch(() => null);
      const r = record(url.pathname, key);
      statusPublished.push({ key, body });
      return json({ ok: true, idempotency_key: key, received: r.requests });
    }
    if (req.method === "GET" && url.pathname === "/status/published") return json(statusPublished);

    // A provider's status feed, in Statuspage v2 shape, set by the rehearsal:
    //   POST /status/feed {"code":"supabase","indicator":"major","description":"..."}
    //   GET  /status/feed/<code>/status.json
    if (req.method === "POST" && url.pathname === "/status/feed") {
      const body = (await req.json().catch(() => null)) as {
        code?: string;
        indicator?: string;
        description?: string;
      } | null;
      if (!body?.code) return json({ error: "code is required" }, 400);
      feeds[body.code] = {
        indicator: body.indicator ?? "none",
        description: body.description ?? "All Systems Operational",
      };
      return json({ ok: true, feed: feeds[body.code] });
    }
    const feed = url.pathname.match(/^\/status\/feed\/([a-z0-9_]+)\/status\.json$/);
    if (req.method === "GET" && feed) {
      const f = feeds[feed[1]] ?? { indicator: "none", description: "All Systems Operational" };
      record(url.pathname, null);
      return json({ page: { id: feed[1], name: feed[1] }, status: f });
    }

    if (req.method === "POST" && url.pathname === "/emails") {
      received.emails += 1;
      received.lastEmail = await req.json().catch(() => null);
      const id = `stub_${received.emails}`;
      received.emailIds.push(id);
      return json({ id });
    }

    return json({ error: `no such route: ${req.method} ${url.pathname}` }, 404);
  },
});

console.log(`[stub] listening on http://localhost:${server.port}`);
