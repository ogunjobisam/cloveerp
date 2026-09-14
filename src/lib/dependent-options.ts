/**
 * A picker whose list follows another choice on the same form.
 *
 * Some records only mean something inside another one: the bucket of a
 * forecast version, the line of a settlement statement, the receivables that
 * line could be matched to. Those forms used to ask for an id typed out of a
 * question somewhere else on the page, which breaks the first rule of a form
 * here — nothing that names an existing record is typed. The doors that list
 * them already exist; what was missing was a picker that asks with the choice
 * made above it.
 *
 * Pure, so what a picker asks with and what it offers can be tested without a
 * browser.
 */

/** The parts of a picker's source that decide what it asks for and what it offers. */
export type DependentSource = {
  args?: Record<string, unknown>;
  /**
   * Door arguments read from other fields on the same form: argument name to
   * field name. The picker waits until each is chosen.
   */
  argsFrom?: Record<string, string>;
  /** The key holding the list, when the door answers with an object. */
  path?: string;
  /**
   * A list inside one record of that list: the record whose `key` equals the
   * value chosen in `field`, and its `path`.
   */
  within?: { field: string; key: string; path: string };
};

/**
 * The arguments the picker asks its door with, or null while a field it
 * depends on has nothing chosen.
 */
export function optionArgs(
  source: DependentSource,
  values: Record<string, string>,
): Record<string, unknown> | null {
  const args: Record<string, unknown> = { ...(source.args ?? {}) };
  for (const [arg, field] of Object.entries(source.argsFrom ?? {})) {
    const chosen = values[field] ?? "";
    if (chosen === "") return null;
    args[arg] = chosen;
  }
  if (source.within && (values[source.within.field] ?? "") === "") return null;
  return args;
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

/** The list a door's answer holds for this picker; empty when it holds none. */
export function optionList(
  source: DependentSource,
  data: unknown,
  values: Record<string, string>,
): unknown[] {
  // A path names a list inside an object; an answer that is already a list is
  // taken as it is, as the pickers always have.
  const record = asRecord(data);
  const answer = source.path && record ? record[source.path] : data;
  const list = Array.isArray(answer) ? answer : [];
  if (!source.within) return list;
  const { field, key, path } = source.within;
  const chosen = values[field] ?? "";
  const holder = list
    .map(asRecord)
    .find((row) => row !== null && String(row[key] ?? "") === chosen);
  const inner = holder?.[path];
  return chosen !== "" && Array.isArray(inner) ? inner : [];
}

/**
 * The rows a line editor arrives holding, read from a door.
 *
 * A delivery raised from a sales order asked the person to retype the order's
 * lines, which is the order's own information typed a second time and the
 * commonest way for the two to disagree. So a line editor may name a door and
 * the choice it follows: once that choice is made, the editor holds one row per
 * record the door answers with, each column taken from the record's `fill` key.
 * The rows stay editable — a quantity lowered, a line removed — and what the
 * person changed is theirs until the choice it follows changes.
 */
export type RowSeed = DependentSource & {
  fn: string;
  /** Column name to the key of each record that fills it. */
  fill: Record<string, string>;
  /** Said when the door answers with nothing to hold. */
  empty?: string;
};

/** A record's field as a text box would hold it. */
function asCell(value: unknown): string {
  return typeof value === "string" ? value : typeof value === "number" ? String(value) : "";
}

/** One row per record the seed's door answered with, its columns filled. */
export function seededRows(
  seed: RowSeed,
  data: unknown,
  values: Record<string, string>,
): Record<string, string>[] {
  return optionList(seed, data, values)
    .map(asRecord)
    .filter((record): record is Record<string, unknown> => record !== null)
    .map((record) =>
      Object.fromEntries(
        Object.entries(seed.fill).map(([column, key]) => [column, asCell(record[key])]),
      ),
    );
}

/**
 * The rows of every line editor, less those seeded from a choice that just
 * changed: the lines of the order chosen before are not the lines of the one
 * chosen now, so the editor starts again from what the new choice holds.
 */
export function dropSeededRows(
  fields: ReadonlyArray<{ name: string; seed?: DependentSource }>,
  rows: Record<string, Record<string, string>[]>,
  name: string,
): Record<string, Record<string, string>[]> {
  const dropped = new Set(
    fields.filter((f) => f.name in rows && followsField(f.seed, name)).map((f) => f.name),
  );
  if (dropped.size === 0) return rows;
  return Object.fromEntries(Object.entries(rows).filter(([key]) => !dropped.has(key)));
}

/** Whether a picker's list follows the field `name`. */
export function followsField(source: DependentSource | undefined, name: string): boolean {
  if (!source) return false;
  return Object.values(source.argsFrom ?? {}).includes(name) || source.within?.field === name;
}

/** The fields whose pickers read `name`: they are cleared when it changes. */
export function dependentFields(
  fields: ReadonlyArray<{ name: string; options?: DependentSource }>,
  name: string,
): string[] {
  return fields.filter((f) => f.name !== name && followsField(f.options, name)).map((f) => f.name);
}

/**
 * The rows of every line editor, with each cell whose picker follows `name`
 * emptied: a line of the blanket order chosen before is not a line of the one
 * chosen now. Rows with nothing to clear are returned as they were.
 */
export function clearDependentCells(
  fields: ReadonlyArray<{
    name: string;
    columns?: ReadonlyArray<{ name: string; options?: DependentSource }>;
  }>,
  rows: Record<string, Record<string, string>[]>,
  name: string,
): Record<string, Record<string, string>[]> {
  let next = rows;
  for (const f of fields) {
    const cleared = (f.columns ?? [])
      .filter((c) => followsField(c.options, name))
      .map((c) => c.name);
    const current = rows[f.name];
    if (cleared.length === 0 || !current) continue;
    next = {
      ...next,
      [f.name]: current.map((row) => {
        const out = { ...row };
        for (const c of cleared) out[c] = "";
        return out;
      }),
    };
  }
  return next;
}
