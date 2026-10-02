/**
 * A site's postal address as public.erp_sites answers it (20261004950000):
 * written by erp_set_site_address, whole or not at all, and read by carriers
 * as the place an outbound parcel leaves and an inbound one arrives.
 */

type Row = Record<string, unknown>;

const text = (v: unknown): string | null =>
  typeof v === "string" && v.trim() !== "" ? v.trim() : null;

/** The address on one line, or null for a site that has none. */
export function siteAddressLine(address: unknown): string | null {
  if (typeof address !== "object" || address === null || Array.isArray(address)) return null;
  const a = address as Row;
  const parts = ["line1", "line2", "city", "region", "postcode", "country_code"]
    .map((k) => text(a[k]))
    .filter((v): v is string => v !== null);
  return parts.length === 0 ? null : parts.join(", ");
}

/** Whether a carrier could label a parcel from it: street, postcode and country. */
export function siteAddressIsComplete(address: unknown): boolean {
  if (typeof address !== "object" || address === null || Array.isArray(address)) return false;
  const a = address as Row;
  return (
    text(a["line1"]) !== null && text(a["postcode"]) !== null && text(a["country_code"]) !== null
  );
}
