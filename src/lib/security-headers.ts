/**
 * The security headers every response from cloveerp.com carries.
 *
 * Found by the first penetration test (14 October 2026): the Worker answered
 * with Content-Type and nothing else, so a browser was not told to keep to
 * HTTPS, any site could frame the desk under a decoy and have a user press
 * Approve or Post through it, and the scanner's camera was not limited to
 * this site. These are the ones that cannot break a screen; a full Content
 * Security Policy (scripts, styles, connections) is its own change.
 *
 * Static files are served by Cloudflare before the Worker sees them, so the
 * same set is written for them in public/_headers; a test holds the two to
 * the same values.
 */
export const SECURITY_HEADERS: Readonly<Record<string, string>> = {
  // A year, every subdomain: each client is served at <code>.cloveerp.com,
  // always over HTTPS. Not preloaded, which is a decision of its own.
  "Strict-Transport-Security": "max-age=31536000; includeSubDomains",
  // Never framed: no screen of the desk is meant to sit inside another site.
  "Content-Security-Policy": "frame-ancestors 'none'",
  "X-Frame-Options": "DENY",
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "strict-origin-when-cross-origin",
  // The camera for the scanner on this site; nothing else a page may ask for.
  "Permissions-Policy": "camera=(self), microphone=(), geolocation=(), payment=(), usb=()",
  // Found by the ZAP baseline of the demonstration (14 October 2026): no
  // other site keeps a handle on a window of ours (sign-in and HMRC's are
  // full redirects, never pop-ups), and our files are for the page that
  // asked (same-origin since the ZAP retest: each client's pages load their
  // own files from their own address, so same-site gave nothing). Cross-Origin-Embedder-Policy is not set: require-corp would
  // refuse the fonts and Cloudflare's own analytics, which send no CORP.
  "Cross-Origin-Opener-Policy": "same-origin",
  "Cross-Origin-Resource-Policy": "same-origin",
};

/** The response with every security header it does not already set. */
export function withSecurityHeaders(response: Response): Response {
  const missing = Object.entries(SECURITY_HEADERS).filter(([name]) => !response.headers.has(name));
  if (missing.length === 0) return response;
  const headers = new Headers(response.headers);
  for (const [name, value] of missing) headers.set(name, value);
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}
