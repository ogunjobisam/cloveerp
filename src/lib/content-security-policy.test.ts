import { describe, expect, test } from "bun:test";

import { contentSecurityPolicy, newNonce } from "./content-security-policy";

const directives = (policy: string) =>
  Object.fromEntries(
    policy.split(";").map((d) => {
      const [name, ...rest] = d.trim().split(/\s+/);
      return [name ?? "", rest];
    }),
  );

describe("the Content Security Policy", () => {
  test("scripts are our own, or carry this request's nonce; never inline otherwise", () => {
    const p = directives(contentSecurityPolicy("abc123"));
    expect(p["script-src"]).toContain("'self'");
    expect(p["script-src"]).toContain("'nonce-abc123'");
    expect(p["script-src"]).not.toContain("'unsafe-inline'");
    expect(p["script-src"]).not.toContain("'unsafe-eval'");
    // The scanner's decoder on an iPhone is WebAssembly.
    expect(p["script-src"]).toContain("'wasm-unsafe-eval'");
  });

  test("nothing loads or connects anywhere but here, Supabase, and Cloudflare's analytics", () => {
    const p = directives(contentSecurityPolicy("n"));
    expect(p["default-src"]).toEqual(["'self'"]);
    expect(p["connect-src"]).toEqual([
      "'self'",
      "https://*.supabase.co",
      "wss://*.supabase.co",
      "https://cloudflareinsights.com",
    ]);
    expect(p["font-src"]).toEqual(["'self'"]);
    expect(p["object-src"]).toEqual(["'none'"]);
    expect(p["base-uri"]).toEqual(["'self'"]);
    expect(p["frame-ancestors"]).toEqual(["'none'"]);
  });

  test("it says where to report what it would refuse, when asked", () => {
    expect(contentSecurityPolicy("n")).not.toContain("report-uri");
    expect(directives(contentSecurityPolicy("n", "/api/csp-report"))["report-uri"]).toEqual([
      "/api/csp-report",
    ]);
  });

  test("a nonce is fresh each time and long enough not to be guessed", () => {
    const a = newNonce();
    const b = newNonce();
    expect(a).not.toBe(b);
    expect(atob(a)).toHaveLength(16);
    expect(a).toMatch(/^[A-Za-z0-9+/]+=*$/);
  });
});
