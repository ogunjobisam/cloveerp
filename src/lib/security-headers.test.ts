import { readFileSync } from "node:fs";

import { describe, expect, test } from "bun:test";

import { SECURITY_HEADERS, withSecurityHeaders } from "./security-headers";

describe("every response carries the security headers", () => {
  test("a page rendered by the Worker gets each of them", () => {
    const r = withSecurityHeaders(
      new Response("<html></html>", { headers: { "content-type": "text/html" } }),
    );
    for (const [name, value] of Object.entries(SECURITY_HEADERS))
      expect(r.headers.get(name)).toBe(value);
    expect(r.headers.get("content-type")).toBe("text/html");
  });

  test("the desk may not be framed, and the camera is this site's alone", () => {
    expect(SECURITY_HEADERS["Content-Security-Policy"]).toContain("frame-ancestors 'none'");
    expect(SECURITY_HEADERS["X-Frame-Options"]).toBe("DENY");
    expect(SECURITY_HEADERS["Permissions-Policy"]).toContain("camera=(self)");
  });

  test("a header the response already set is kept, and a redirect keeps its status and place", async () => {
    const own = withSecurityHeaders(
      new Response("x", { headers: { "Referrer-Policy": "no-referrer" } }),
    );
    expect(own.headers.get("Referrer-Policy")).toBe("no-referrer");
    const moved = withSecurityHeaders(Response.redirect("https://cloveerp.com/acme", 302));
    expect(moved.status).toBe(302);
    expect(moved.headers.get("location")).toBe("https://cloveerp.com/acme");
    expect(moved.headers.get("X-Frame-Options")).toBe("DENY");
    expect(await withSecurityHeaders(new Response("body")).text()).toBe("body");
  });

  test("static files are given the same values, in public/_headers", () => {
    const file = readFileSync("public/_headers", "utf8");
    const lines = file.split("\n").filter((l) => /^\s+\S+:/.test(l));
    const given = Object.fromEntries(
      lines.map((l) => {
        const at = l.indexOf(":");
        return [l.slice(0, at).trim(), l.slice(at + 1).trim()];
      }),
    );
    expect(given).toEqual({ ...SECURITY_HEADERS });
    expect(file).toMatch(/^\/\*$/m);
  });
});
