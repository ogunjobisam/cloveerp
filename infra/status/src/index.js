/**
 * The status page: a Cloudflare Worker that stores what the product sends it
 * and serves it. No inference, no polling of the product — if the product
 * cannot publish, the page says when it last heard, which is itself the truth.
 *
 *   POST /publish        one incident update (erp.status_payload() shape),
 *                        Authorization: Bearer <STATUS_PUBLISH_TOKEN>,
 *                        Idempotency-Key: <key> — a key seen before is
 *                        answered 200 and stored nowhere twice
 *   GET  /               the page
 *   GET  /status.json    current incidents and the last 90 days, as JSON
 *   GET  /health         200
 */

const HISTORY_DAYS = 90;

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });

async function readState(env) {
  const raw = await env.STATUS.get("state");
  return raw ? JSON.parse(raw) : { incidents: {}, keys: [], updated_at: null };
}

async function publish(request, env) {
  const auth = request.headers.get("authorization") || "";
  const token = env.STATUS_PUBLISH_TOKEN || "";
  if (!token || auth !== `Bearer ${token}`) return json({ error: "unauthorised" }, 401);

  let body;
  try {
    body = await request.json();
  } catch {
    return json({ error: "the body is not JSON" }, 400);
  }
  if (!body || typeof body.incident_code !== "string" || typeof body.body !== "string") {
    return json({ error: "incident_code and body are required" }, 400);
  }

  const key =
    request.headers.get("idempotency-key") ||
    `${body.incident_code}:${body.update_id || "declared"}`;
  const state = await readState(env);
  if (state.keys.includes(key)) return json({ ok: true, duplicate: true });

  const inc = state.incidents[body.incident_code] || { updates: [] };
  state.incidents[body.incident_code] = {
    code: body.incident_code,
    title: body.title,
    severity: body.severity,
    state: body.state,
    declared_at: body.declared_at || inc.declared_at || body.posted_at,
    contained_at: body.contained_at || null,
    resolved_at: body.resolved_at || null,
    scope: body.scope || null,
    affects_everyone: Boolean(body.affects_everyone),
    origin: body.origin || null,
    components: Array.isArray(body.components) ? body.components : [],
    next_update_at: body.next_update_at || null,
    updates: [
      ...inc.updates,
      {
        posted_at: body.posted_at,
        body: body.body,
        is_no_change: Boolean(body.is_no_change),
        affected: body.affected || null,
        not_affected: body.not_affected || null,
        being_done: body.being_done || null,
        meanwhile: body.meanwhile || null,
      },
    ].sort((a, b) => (a.posted_at < b.posted_at ? -1 : 1)),
  };

  // History: resolved incidents older than the window fall off the page, not
  // out of the product — the product keeps the record (D36); this is the view.
  const cutoff = Date.now() - HISTORY_DAYS * 24 * 60 * 60 * 1000;
  for (const [code, i] of Object.entries(state.incidents)) {
    if (i.resolved_at && new Date(i.resolved_at).getTime() < cutoff) delete state.incidents[code];
  }
  state.keys = [...state.keys, key].slice(-2000);
  state.updated_at = new Date().toISOString();
  await env.STATUS.put("state", JSON.stringify(state));
  return json({
    ok: true,
    incident: body.incident_code,
    updates: state.incidents[body.incident_code].updates.length,
  });
}

function escapeHtml(s) {
  return String(s ?? "").replace(
    /[&<>"']/g,
    (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c],
  );
}

function page(state, title) {
  const incidents = Object.values(state.incidents).sort((a, b) =>
    a.declared_at < b.declared_at ? 1 : -1,
  );
  const live = incidents.filter((i) => i.state !== "resolved");
  const past = incidents.filter((i) => i.state === "resolved");
  const overall =
    live.length === 0
      ? { cls: "ok", text: "All components operating normally" }
      : live.some((i) => i.severity === "sev1" || i.severity === "sev2")
        ? { cls: "bad", text: "Service disruption in progress" }
        : { cls: "warn", text: "Degraded service in progress" };

  const render = (i) => `
    <article class="incident ${escapeHtml(i.state)}">
      <header>
        <h3>${escapeHtml(i.title)}</h3>
        <p class="meta">${escapeHtml(i.severity)} · ${escapeHtml(i.state)} · declared ${escapeHtml(i.declared_at)}${i.resolved_at ? ` · resolved ${escapeHtml(i.resolved_at)}` : ""}</p>
        ${i.components.length ? `<p class="meta">Components: ${i.components.map(escapeHtml).join(", ")}</p>` : ""}
        ${i.origin ? `<p class="meta">Origin: ${escapeHtml(i.origin)}</p>` : ""}
        ${i.scope ? `<p class="meta">Scope: ${escapeHtml(i.scope)}${i.affects_everyone ? " (every organisation)" : ""}</p>` : ""}
        ${i.next_update_at && i.state !== "resolved" ? `<p class="meta">Next update by ${escapeHtml(i.next_update_at)}</p>` : ""}
      </header>
      <ol>
        ${[...i.updates]
          .reverse()
          .map(
            (u) =>
              `<li><time>${escapeHtml(u.posted_at)}</time>${u.is_no_change ? " <em>(no change)</em>" : ""}<pre>${escapeHtml(u.body)}</pre></li>`,
          )
          .join("")}
      </ol>
    </article>`;

  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escapeHtml(title)}</title>
<style>
  body{font:15px/1.5 system-ui,sans-serif;margin:0;background:#f7f7f5;color:#1d1d1b}
  main{max-width:56rem;margin:0 auto;padding:2rem 1rem}
  .overall{padding:1rem 1.25rem;border-radius:.75rem;font-weight:600}
  .overall.ok{background:#e6f4ea;color:#1e6b3a}.overall.warn{background:#fff4d6;color:#8a5a00}.overall.bad{background:#fde8e8;color:#9b1c1c}
  .meta{color:#666;font-size:.85rem;margin:.1rem 0}
  article{background:#fff;border:1px solid #e4e4e0;border-radius:.75rem;padding:1rem 1.25rem;margin:1rem 0}
  article.resolved{opacity:.8}
  h1{font-size:1.4rem}h2{font-size:1.05rem;margin-top:2rem}h3{margin:0;font-size:1.05rem}
  ol{list-style:none;padding:0;margin:.75rem 0 0}li{border-top:1px solid #eee;padding:.5rem 0}
  time{font-size:.8rem;color:#666}pre{white-space:pre-wrap;font:inherit;margin:.25rem 0 0}
  footer{color:#666;font-size:.8rem;margin-top:2rem}
</style></head><body><main>
<h1>${escapeHtml(title)}</h1>
<div class="overall ${overall.cls}">${overall.text}</div>
<h2>Current</h2>
${live.length ? live.map(render).join("") : '<p class="meta">No incident is in progress.</p>'}
<h2>Past ${HISTORY_DAYS} days</h2>
${past.length ? past.map(render).join("") : '<p class="meta">No incident has been resolved in this period.</p>'}
<footer>Maintained by the platform, not by inference: every entry above was published by Clove ERP's incident register. Last publication ${escapeHtml(state.updated_at || "never")}. <a href="/status.json">JSON</a></footer>
</main></body></html>`;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/health") return json({ ok: true });
    if (request.method === "POST" && url.pathname === "/publish") return publish(request, env);
    if (request.method === "GET" && url.pathname === "/status.json") {
      const state = await readState(env);
      return json({ updated_at: state.updated_at, incidents: Object.values(state.incidents) });
    }
    if (request.method === "GET" && url.pathname === "/") {
      const state = await readState(env);
      return new Response(page(state, env.PAGE_TITLE || "Status"), {
        headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" },
      });
    }
    return json({ error: "not found" }, 404);
  },
};
