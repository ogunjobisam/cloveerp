/**
 * Money, in the units the database actually stores.
 *
 * Every amount in the engine is an integer count of a currency's minor units
 * (spec 4.10) — not a decimal, because a decimal accumulates error and there
 * is no rounding rule that is right for every jurisdiction. The exponent is
 * per currency: `erp_ref.currency.minor_units`, seeded 2 for most, **0 for
 * JPY and KRW**.
 *
 * The app previously divided by 100 unconditionally. For GBP that is right;
 * for JPY it displayed a hundred times the real value, with two decimal places
 * forced onto a currency that has none. It could not have been fixed on the
 * client, because nothing on the public API returned the exponent — that is
 * what `erp_currencies()` is for.
 *
 * The direction that matters more is the other one. A price *input* has to
 * multiply by the same exponent before it reaches `p_unit_price_minor bigint`,
 * and getting that wrong writes a wrong number into the ledger rather than
 * merely showing one.
 */

/** What `public.erp_currencies()` returns. */
export type Currency = { code: string; name: string; minor_units: number };

/**
 * Two is the right default only because most currencies are two.
 *
 * It is used when the currency is unknown to the caller — a document whose
 * currency has not loaded yet — and never in preference to a known exponent.
 */
const DEFAULT_MINOR_UNITS = 2;

export function minorUnitsOf(currencies: Currency[] | undefined, code: string | null): number {
  if (!code) return DEFAULT_MINOR_UNITS;
  const found = currencies?.find((c) => c.code === code);
  return found ? found.minor_units : DEFAULT_MINOR_UNITS;
}

/**
 * Minor units to something a person reads.
 *
 * `minimumFractionDigits` follows the currency rather than being pinned at
 * two, so ¥100 renders as ¥100 and not ¥100.00.
 */
export function formatMinor(
  minor: number | null | undefined,
  code: string,
  minorUnits: number = DEFAULT_MINOR_UNITS,
): string {
  const value = (minor ?? 0) / 10 ** minorUnits;
  try {
    return new Intl.NumberFormat(undefined, {
      style: "currency",
      currency: code,
      minimumFractionDigits: minorUnits,
      maximumFractionDigits: minorUnits,
    }).format(value);
  } catch {
    // An unknown or malformed currency code makes Intl throw. Showing the
    // number with its code beside it is worse than a formatted amount and far
    // better than a blank cell where a value should be.
    return `${value.toFixed(minorUnits)} ${code}`;
  }
}

/**
 * What a person typed, to the integer the database expects.
 *
 * Rounds rather than truncates, because 1.005 typed against a two-place
 * currency is a person meaning 1.01, and returns null for anything that is not
 * a number so a caller can refuse instead of sending NaN.
 */
export function toMinor(
  major: string | number,
  minorUnits: number = DEFAULT_MINOR_UNITS,
): number | null {
  const n = typeof major === "number" ? major : Number(String(major).trim());
  if (!Number.isFinite(n)) return null;
  return Math.round(n * 10 ** minorUnits);
}
