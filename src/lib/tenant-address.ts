/**
 * An organisation's address: cloveerp.com/acme.
 *
 * The address is erp.tenant.code, and it is a way in, never an authority. The
 * organisation a session works in is derived from its account by
 * current_tenant_id(); typing another organisation's address changes nothing
 * but the name on the sign-in form. So what is decided here is only what to
 * suggest and what to show, and the database refuses a code that is taken,
 * reserved or the wrong shape regardless.
 *
 * Pure, so it can be tested without a browser. Nothing here imports the
 * Supabase client.
 */

/**
 * The shape the database holds an address to: lower-case letters, digits and
 * hyphens, starting and ending with a letter or digit, three to sixty-three
 * characters — the most one DNS label carries, so the same code can become
 * acme.cloveerp.com without a rename.
 */
export const ADDRESS_PATTERN = /^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$/;

export const ADDRESS_MAX = 63;

export function addressShaped(candidate: string): boolean {
  return ADDRESS_PATTERN.test(candidate);
}

/**
 * Words a company name carries that say nothing about which company it is.
 * "Acme Manufacturing Ltd" is found at /acme-manufacturing, not
 * /acme-manufacturing-ltd.
 */
const LEGAL_SUFFIXES = new Set([
  "ltd",
  "limited",
  "plc",
  "llp",
  "llc",
  "inc",
  "incorporated",
  "corp",
  "corporation",
  "co",
  "company",
  "gmbh",
  "sa",
  "bv",
  "pty",
]);

/**
 * An address suggested from an organisation's name. A suggestion only: the
 * person edits it, and the database decides whether it is free.
 *
 * Returns "" when the name holds nothing an address can be made of.
 */
export function suggestAddress(name: string): string {
  const words = name
    .normalize("NFKD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replace(/&/g, " and ")
    .replace(/['’]/g, "")
    .split(/[^a-z0-9]+/)
    .filter((w) => w !== "");
  while (words.length > 1 && LEGAL_SUFFIXES.has(words[words.length - 1] ?? "")) words.pop();
  return words.join("-").slice(0, ADDRESS_MAX).replace(/-+$/, "");
}

/**
 * What a person types into the address box, kept to characters an address can
 * hold as they type: upper case folds down, a space becomes a hyphen, anything
 * else is dropped. The ends are not trimmed here, because "acme-" is on its
 * way to "acme-tools".
 */
export function typedAddress(input: string): string {
  return input
    .toLowerCase()
    .replace(/\s+/g, "-")
    .replace(/[^a-z0-9-]/g, "")
    .replace(/-{2,}/g, "-")
    .slice(0, ADDRESS_MAX);
}

/** The path an address opens. */
export function addressPath(code: string): string {
  return `/${code}`;
}

/** How an address is written for a person to read: host and path, no scheme. */
export function displayAddress(host: string, code: string): string {
  return `${host}${addressPath(code)}`;
}

/** What public.erp_tenant_by_address() answers, read strictly. */
export type AddressLookup = { code: string; name: string };

/**
 * Anything but an object carrying a code and a name is "no organisation here":
 * a null answer, an error payload, or an older schema that has no such door.
 * The code is the organisation's current address, which differs from the one
 * asked about when the organisation has since renamed it.
 */
export function readAddressLookup(answer: unknown): AddressLookup | null {
  if (typeof answer !== "object" || answer === null) return null;
  const code: unknown = Reflect.get(answer, "code");
  const name: unknown = Reflect.get(answer, "name");
  if (typeof code !== "string" || typeof name !== "string") return null;
  if (!addressShaped(code) || name.trim() === "") return null;
  return { code, name };
}
