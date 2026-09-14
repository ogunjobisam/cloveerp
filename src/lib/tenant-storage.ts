/**
 * A key in the browser's storage that belongs to one organisation.
 *
 * What a screen remembers for one person at one browser — the records they
 * opened last, the company and site they chose in the header — is about the
 * organisation they were working in when they chose it. A person who works in
 * two organisations (staff moving between a demonstration and a customer, or
 * anybody with a second account on the same browser) used to see the first
 * organisation's products under "Recently opened" in the second, because the
 * key named only the list. Every such key now carries the organisation's id
 * from the session.
 *
 * No organisation, no key: nothing is read or written until the session says
 * which organisation this is, so a list can never be filed under the wrong one.
 *
 * Pure, so it is tested on its own.
 */
export function tenantStorageKey(base: string, tenantId: string | null | undefined): string | null {
  const id = (tenantId ?? "").trim();
  if (base.trim() === "" || id === "") return null;
  return `${base}:${id}`;
}
