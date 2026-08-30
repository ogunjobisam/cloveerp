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
 * The direction that writes to the ledger, so both of its edge cases are
 * failures I put here myself and a test caught:
 *
 *   - **Empty is not zero.** `Number("")` is `0`, and `0` is finite, so an
 *     untouched price field became a price of nothing rather than a refusal.
 *     A blank input is an absent answer; only a typed `0` is a zero.
 *   - **Multiplying floats loses the rounding.** `1.005 * 100` is
 *     `100.49999999999999`, so `Math.round` gave 100 where a person typing
 *     1.005 against a two-place currency means 1.01. Fixing the scaled value
 *     to more places than any currency has, before rounding, removes the
 *     representation error without pretending to be decimal arithmetic.
 */
export function toMinor(
  major: string | number,
  minorUnits: number = DEFAULT_MINOR_UNITS,
): number | null {
  if (typeof major === "string" && major.trim() === "") return null;
  const n = typeof major === "number" ? major : Number(String(major).trim());
  if (!Number.isFinite(n)) return null;
  // minor_units is constrained to 0..4, so six places is always slack enough.
  return Math.round(Number((n * 10 ** minorUnits).toFixed(6)));
}
