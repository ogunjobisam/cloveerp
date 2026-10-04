/**
 * The choices a type-or-pick box offers, each value once.
 *
 * A reason code is kept per category, so a door that lists every category's
 * reasons answers WRONG_QUANTITY twice (once for customer returns, once for
 * supplier returns). The box offered it twice, and React was handed two
 * options with the same key. The value is what is sent, so the first row for a
 * value is the one offered.
 */
export function firstPerValue<T extends { value: string }>(rows: readonly T[]): T[] {
  const seen = new Set<string>();
  const out: T[] = [];
  for (const row of rows) {
    if (seen.has(row.value)) continue;
    seen.add(row.value);
    out.push(row);
  }
  return out;
}
