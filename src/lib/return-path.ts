/**
 * Where to send somebody once they have signed in.
 *
 * Signing out and following a link to /inventory put the sign-in form in front
 * of the page, which is right — but signing in with an emailed link or with
 * Google returned to the bare site, so the page they had asked for was gone and
 * the back button could not bring it back. The path they were on travels with
 * them now.
 *
 * Only ever a path on this site. A return address taken from a URL is the
 * classic open redirect: "//evil.example" and "https://evil.example" are both
 * addresses a browser will happily leave for, and a sign-in screen that honours
 * them is one that can be used to send people somewhere that looks like it.
 */
export function safeReturnPath(candidate: string | null | undefined): string | null {
  if (typeof candidate !== "string") return null;
  const path = candidate.trim();
  if (!path.startsWith("/")) return null; // not a path on this site
  if (path.startsWith("//") || path.startsWith("/\\")) return null; // protocol-relative
  // Control characters: a newline in a return address is a header waiting to
  // be injected somewhere downstream.
  for (let i = 0; i < path.length; i++) {
    const code = path.charCodeAt(i);
    if (code < 32 || code === 127) return null;
  }
  const bare = path.split(/[?#]/)[0] ?? "";
  if (bare === "/signin" || bare.startsWith("/signin/")) return null; // not back to the door
  return path;
}
