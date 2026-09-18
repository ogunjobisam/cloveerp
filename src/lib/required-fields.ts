/**
 * Which required answers a form is still missing, in the order it asks them.
 *
 * Pressing Create on an empty New goods receipt produced a faint focus ring on
 * Business partner and nothing else: no message, nothing to say Lines was
 * needed too, so the person pressed it again. The browser's own check blocks
 * the submit and stops there, and a line editor is not something it checks at
 * all. So the form checks itself, says what is missing, and says it beside each
 * field as well as at the top.
 */

export type RequiredField = { name: string; kind: string; required?: boolean | undefined };

/** A line counts once anything has been put on it. A blank row is not a line. */
function hasALine(rows: Record<string, string>[] | undefined): boolean {
  return (rows ?? []).some((row) => Object.values(row).some((v) => (v ?? "").trim() !== ""));
}

export function missingRequired(
  fields: readonly RequiredField[],
  values: Readonly<Record<string, string>>,
  rows: Readonly<Record<string, Record<string, string>[]>>,
  lists: Readonly<Record<string, readonly string[]>> = {},
): string[] {
  return fields
    .filter((f) => f.required)
    .filter((f) => {
      if (f.kind === "rows") return !hasALine(rows[f.name]);
      if (f.kind === "multi") return (lists[f.name] ?? []).length === 0;
      return (values[f.name] ?? "").trim() === "";
    })
    .map((f) => f.name);
}
