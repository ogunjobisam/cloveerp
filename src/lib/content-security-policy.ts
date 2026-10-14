/**
 * The Content Security Policy: what a page of cloveerp.com may load and
 * where it may send things (the penetration test, finding 12, 14 October
 * 2026: only frame-ancestors was set, so scripts, styles and connections
 * were unrestricted).
 *
 * Scripts: our own files, and the inline scripts the router writes as it
 * renders, each carrying a nonce made fresh for the request (TanStack's
 * router stamps router.options.ssr.nonce on every script it writes and
 * publishes it in a csp-nonce meta tag for the browser). No unsafe-inline for
 * scripts. WebAssembly may be compiled ('wasm-unsafe-eval'): the scanner's
 * barcode decoder on a phone without its own is ZXing in WebAssembly. And
 * Cloudflare's Web Analytics beacon, which Cloudflare inserts into the page.
 *
 * Styles keep 'unsafe-inline': React's style attributes, and the components
 * that write a style element (the chart, the toaster), need it, and a style
 * cannot run code.
 *
 * Connections: our own origin, and Supabase, where each client's project is
 * <ref>.supabase.co (the database, its sign-in, its Edge Functions and its
 * realtime), and Cloudflare's analytics.
 */
export function contentSecurityPolicy(nonce: string, reportUri?: string): string {
  const directives: [string, string][] = [
    ["default-src", "'self'"],
    [
      "script-src",
      `'self' 'nonce-${nonce}' 'wasm-unsafe-eval' https://static.cloudflareinsights.com`,
    ],
    ["style-src", "'self' 'unsafe-inline'"],
    ["img-src", "'self' data: blob: https://*.supabase.co"],
    ["font-src", "'self'"],
    [
      "connect-src",
      "'self' https://*.supabase.co wss://*.supabase.co https://cloudflareinsights.com",
    ],
    ["worker-src", "'self' blob:"],
    ["media-src", "'self' blob:"],
    ["manifest-src", "'self'"],
    ["object-src", "'none'"],
    ["base-uri", "'self'"],
    ["form-action", "'self'"],
    ["frame-ancestors", "'none'"],
  ];
  if (reportUri) directives.push(["report-uri", reportUri]);
  return directives.map(([name, value]) => `${name} ${value}`).join("; ");
}

/** A nonce: sixteen random bytes, base64, made fresh for each request. */
export function newNonce(): string {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  let text = "";
  for (const b of bytes) text += String.fromCharCode(b);
  return btoa(text);
}

/** Where a browser sends what the policy would have refused. */
export const CSP_REPORT_PATH = "/api/csp-report";

/**
 * The nonce of the request being rendered, for the router, which is made per
 * request inside it. The Worker keeps it in an AsyncLocalStorage it places on
 * globalThis (src/server.ts); the browser has no store and reads the nonce
 * from the page instead, so this is undefined there.
 */
type NonceStore = { getStore(): string | undefined };

export function currentNonce(): string | undefined {
  const store = (globalThis as { __cloveCspNonce?: NonceStore }).__cloveCspNonce;
  return store?.getStore();
}
