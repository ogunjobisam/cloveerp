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

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

const server = Bun.serve({
  port,
  async fetch(req: Request) {
    const url = new URL(req.url);
    if (req.method === "GET" && url.pathname === "/health") return json({ ok: true });
    if (req.method === "GET" && url.pathname === "/received") return json(received);

    if (req.method === "POST" && url.pathname === "/orders") {
      const key = req.headers.get("idempotency-key");
      received.orders += 1;
      received.lastOrder = await req.json().catch(() => null);
      if (key) {
        if (received.orderKeys.includes(key)) received.duplicateKeys += 1;
        else received.orderKeys.push(key);
      }
      return json({ ok: true, idempotency_key: key });
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
