/**
 * Values as a legacy report prints them, turned into values a door accepts.
 *
 * Money is converted with integer arithmetic on the digits, never through a
 * float: "1234.505" is refused at two places rather than rounded one way or the
 * other by the binary representation, and "£1,234.50" is 123450 because the
 * digits say so. `toMinor` in money.ts is for a person typing a price; an
 * import is a ledger arriving, and a penny lost here is a D31 check that fails
 * on honest data.
 */

/** An exact decimal: `units / 10^scale`. */
export type Decimal = { units: bigint; scale: number };

const MONEY_SYMBOLS = /[£$€]/g;

/**
 * Reads "1,234.50", "(123.45)", "-1234.5", "123.45-", "£1,234.50", "GBP 10".
 * Thousands separators are accepted only where they are well placed, so
 * "1,23" is refused rather than read as 123.
 */
export function parseDecimal(text: string): Decimal | null {
  let s = text.trim().replace(MONEY_SYMBOLS, "").replace(/\s+/g, "");
  s = s.replace(/^[A-Z]{3}(?=[-(0-9.])/, "").replace(/(?<=[0-9.)])[A-Z]{3}$/, "");
  if (s === "") return null;
  let negative = false;
  if (s.startsWith("(") && s.endsWith(")")) {
    negative = true;
    s = s.slice(1, -1);
  }
  if (s.startsWith("-")) {
    negative = !negative;
    s = s.slice(1);
  } else if (s.endsWith("-")) {
    negative = !negative;
    s = s.slice(0, -1);
  } else if (s.startsWith("+")) {
    s = s.slice(1);
  }
  if (!/^(\d{1,3}(,\d{3})+|\d+)?(\.\d+)?$/.test(s) || s === "" || s === ".") return null;
  const [whole = "", frac = ""] = s.replace(/,/g, "").split(".");
  const digits = `${whole}${frac}`.replace(/^0+(?=\d)/, "") || "0";
  const units = BigInt(digits);
  return { units: negative ? -units : units, scale: frac.length };
}

/** `d` rescaled to `places`, or null if that would drop a non-zero digit. */
function rescaleExact(d: Decimal, places: number): bigint | null {
  if (d.scale <= places) return d.units * 10n ** BigInt(places - d.scale);
  const div = 10n ** BigInt(d.scale - places);
  return d.units % div === 0n ? d.units / div : null;
}

/** Half away from zero, the rounding a printed report uses. */
export function roundTo(d: Decimal, places: number): bigint {
  if (d.scale <= places) return d.units * 10n ** BigInt(places - d.scale);
  const div = 10n ** BigInt(d.scale - places);
  const neg = d.units < 0n;
  const abs = neg ? -d.units : d.units;
  const q = abs / div;
  const r = abs % div;
  const rounded = r * 2n >= div ? q + 1n : q;
  return neg ? -rounded : rounded;
}

function toSafe(v: bigint): number | null {
  const n = Number(v);
  return Number.isSafeInteger(n) ? n : null;
}

export type MinorParse =
  | { ok: true; minor: number }
  | { ok: false; reason: "blank" | "not_a_number" | "too_many_places" | "too_large" };

/** A money amount in exact minor units. */
export function parseMinor(text: string, places = 2): MinorParse {
  if (text.trim() === "") return { ok: false, reason: "blank" };
  const d = parseDecimal(text);
  if (!d) return { ok: false, reason: "not_a_number" };
  const scaled = rescaleExact(d, places);
  if (scaled === null) return { ok: false, reason: "too_many_places" };
  const minor = toSafe(scaled);
  return minor === null ? { ok: false, reason: "too_large" } : { ok: true, minor };
}

/** A decimal's canonical text: "12.50" → "12.5", "-0" → "0". */
export function decimalText(d: Decimal): string {
  const neg = d.units < 0n;
  const digits = (neg ? -d.units : d.units).toString().padStart(d.scale + 1, "0");
  let out = d.scale > 0 ? `${digits.slice(0, -d.scale)}.${digits.slice(-d.scale)}` : digits;
  if (out.includes(".")) out = out.replace(/0+$/, "").replace(/\.$/, "");
  return neg && out !== "0" ? `-${out}` : out;
}

/** A quantity as a string the door reads as numeric, or null. */
export function parseQuantity(text: string): string | null {
  const d = parseDecimal(text);
  return d ? decimalText(d) : null;
}

export function multiply(a: Decimal, b: Decimal): Decimal {
  return { units: a.units * b.units, scale: a.scale + b.scale };
}

export function addDecimals(values: readonly Decimal[]): Decimal {
  const scale = Math.max(0, ...values.map((v) => v.scale));
  let units = 0n;
  for (const v of values) units += v.units * 10n ** BigInt(scale - v.scale);
  return { units, scale };
}

const MONTHS: Readonly<Record<string, number>> = {
  jan: 1,
  feb: 2,
  mar: 3,
  apr: 4,
  may: 5,
  jun: 6,
  jul: 7,
  aug: 8,
  sep: 9,
  sept: 9,
  oct: 10,
  nov: 11,
  dec: 12,
};

function isoDate(y: number, m: number, d: number): string | null {
  if (m < 1 || m > 12 || d < 1) return null;
  const days = new Date(Date.UTC(y, m, 0)).getUTCDate();
  if (d > days) return null;
  return `${String(y).padStart(4, "0")}-${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
}

function fullYear(y: string): number {
  const n = Number(y);
  return y.length === 2 ? 2000 + n : n;
}

/**
 * A UK date as a report prints it: "30/09/2026", "30/9/26", "30 Sep 2026",
 * "30-Sep-26", "30 September 2026", or ISO already. Day first, always: a UK
 * export has no month-first dates, and guessing between them is how a
 * 3 October invoice becomes a 10 March one.
 */
export function parseUkDate(text: string): string | null {
  const s = text.trim();
  let m = /^(\d{4})-(\d{2})-(\d{2})(?:[T ].*)?$/.exec(s);
  if (m) return isoDate(Number(m[1]), Number(m[2]), Number(m[3]));
  m = /^(\d{1,2})[/.-](\d{1,2})[/.-](\d{2}|\d{4})$/.exec(s);
  if (m) return isoDate(fullYear(m[3] ?? ""), Number(m[2]), Number(m[1]));
  m = /^(\d{1,2})[\s-]+([A-Za-z]{3,9})[\s-]+(\d{2}|\d{4})$/.exec(s);
  if (m) {
    const name = (m[2] ?? "").toLowerCase();
    const month = MONTHS[name.slice(0, 3)];
    if (month === undefined) return null;
    if (name.length > 3 && name !== "sept" && monthName(month) !== name) return null;
    return isoDate(fullYear(m[3] ?? ""), month, Number(m[1]));
  }
  return null;
}

function monthName(month: number): string {
  return new Date(Date.UTC(2000, month - 1, 1))
    .toLocaleString("en-GB", { month: "long", timeZone: "UTC" })
    .toLowerCase();
}

const COUNTRY_ALIASES: Readonly<Record<string, string>> = {
  uk: "GB",
  "u.k.": "GB",
  "great britain": "GB",
  britain: "GB",
  england: "GB",
  scotland: "GB",
  wales: "GB",
  "northern ireland": "GB",
  "united kingdom of great britain and northern ireland": "GB",
  usa: "US",
  "u.s.a.": "US",
  "united states of america": "US",
  "republic of ireland": "IE",
  eire: "IE",
  holland: "NL",
  "the netherlands": "NL",
};

/** Region codes that are not ISO 3166 countries, though a name is printed for them. */
const NOT_COUNTRIES = new Set(["EU", "EZ", "UN", "QO", "UK", "XA", "XB"]);

let countryIndex: Map<string, string> | null = null;

function buildCountryIndex(): Map<string, string> {
  const index = new Map<string, string>();
  const names = new Intl.DisplayNames(["en-GB"], { type: "region", fallback: "none" });
  const A = "A".charCodeAt(0);
  for (let i = 0; i < 26; i++) {
    for (let j = 0; j < 26; j++) {
      const code = String.fromCharCode(A + i, A + j);
      let name: string | undefined;
      try {
        name = names.of(code);
      } catch {
        name = undefined;
      }
      if (name && name !== code && !NOT_COUNTRIES.has(code)) {
        index.set(code.toLowerCase(), code);
        if (!index.has(name.toLowerCase())) index.set(name.toLowerCase(), code);
      }
    }
  }
  for (const [alias, code] of Object.entries(COUNTRY_ALIASES)) index.set(alias, code);
  return index;
}

/** ISO 3166 alpha-2 for a country as a person typed it, or null. */
export function countryToIso2(text: string): string | null {
  const key = text.trim().toLowerCase().replace(/\s+/g, " ");
  if (key === "") return null;
  countryIndex ??= buildCountryIndex();
  return countryIndex.get(key) ?? null;
}

/**
 * A party code from a name, per decision D5: upper case, letters and digits
 * only, twenty characters, and a numeric suffix where the code is taken.
 * `taken` is updated, so the same list of names gives the same codes.
 */
export function deriveCode(name: string, taken: Set<string>, max = 20): string {
  const base =
    name
      .toUpperCase()
      .replace(/[^A-Z0-9]/g, "")
      .slice(0, max) || "PARTY";
  let code = base;
  for (let n = 2; taken.has(code); n++) {
    const suffix = String(n);
    code = `${base.slice(0, max - suffix.length)}${suffix}`;
  }
  taken.add(code);
  return code;
}

export type VatParse = { value: string; wellFormed: boolean };

/**
 * A UK VAT number in the form HMRC prints it: GB plus nine or twelve digits,
 * or GBGD/GBHA plus three. A bare nine digits gains its GB. Anything else is
 * kept as typed and flagged: a foreign VAT number is a real value, just not
 * one this rule can check.
 */
export function normaliseVat(text: string): VatParse | null {
  const s = text
    .trim()
    .toUpperCase()
    .replace(/[\s.-]/g, "");
  if (s === "") return null;
  const withPrefix = /^\d{9}(\d{3})?$/.test(s) ? `GB${s}` : s;
  const wellFormed = /^(GB|XI)(\d{9}|\d{12}|GD\d{3}|HA\d{3})$/.test(withPrefix);
  return { value: withPrefix, wellFormed };
}
