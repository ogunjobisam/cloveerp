/**
 * The question the form asks so that its total is the record's total.
 *
 * A line left without a price takes the agreed price for that partner and
 * product — the form says so, and `erp.add_document_line` does it. The form did
 * not: the running total counted a blank price as nought, so a goods receipt
 * for ten sacks of oats showed GBP 0.00 and the record came back worth
 * something else, or worth nothing at all and nobody was told.
 *
 * So the form asks the same question the database is about to ask. Which means
 * it has to ask it with the *same answers* — and that is the part with a rule
 * in it, so it lives here where it can be checked without a browser. The site
 * is the case that matters: the form only shows a site picker when the shell's
 * scope has not already answered it, and what it sends is the scope's site. A
 * lookup that left the site out would quietly show the general price while the
 * record took the site's.
 */

/** Where one argument of the lookup is answered from. */
export type PriceLookup = {
  /** The door that answers. */
  fn: string;
  /** Each argument, from a column of the row or, prefixed `form.`, a field of the form. */
  args: Record<string, string>;
  /** What an argument falls back to when the form does not ask it. */
  fixed?: Record<string, string> | undefined;
  /** The arguments that must be answered before there is a question worth asking. */
  needs: string[];
};

/**
 * The arguments for one row's lookup, or null when the row has not yet said
 * enough to be worth asking about.
 *
 * An argument with no answer is left out rather than sent empty: the doors
 * default a missing quantity to one and a missing site to every site, and
 * sending "" would be sending a site that does not exist.
 */
export function priceLookupArgs(
  spec: PriceLookup | undefined,
  row: Record<string, string>,
  formValues: Record<string, string>,
): Record<string, string> | null {
  if (!spec) return null;

  const args: Record<string, string> = {};
  for (const [arg, from] of Object.entries(spec.args)) {
    const held = from.startsWith("form.")
      ? (formValues[from.slice("form.".length)] ?? "")
      : (row[from] ?? "");
    if (held !== "") args[arg] = held;
  }
  for (const [arg, held] of Object.entries(spec.fixed ?? {})) {
    if (args[arg] === undefined && held !== "") args[arg] = held;
  }

  return spec.needs.every((n) => args[n] !== undefined) ? args : null;
}

/** What a catalogue answered, once the form has decided whether it may use it. */
export type ResolvedPrice = { minor: number | null; note: string | null };

/**
 * What the form may show and count, from what the door returned.
 *
 * `erp.add_document_line` keeps a catalogue answer only when its currency is
 * the document's. A form that showed a price in another currency would be
 * showing a figure the record will not carry, so it is treated as no price and
 * the line says why — which is more use than a blank either way.
 */
export function resolvedPrice(
  answer: unknown,
  amountKey: string,
  noteKey: string | undefined,
  documentCurrency: string | undefined,
): ResolvedPrice {
  if (!answer || typeof answer !== "object") return { minor: null, note: null };
  const held = answer as Record<string, unknown>;

  const answered = held["currency"];
  if (
    typeof answered === "string" &&
    answered !== "" &&
    documentCurrency !== undefined &&
    documentCurrency !== "" &&
    answered !== documentCurrency
  ) {
    return {
      minor: null,
      note: `The only price on record is in ${answered}, and this document is in ${documentCurrency}.`,
    };
  }

  const raw = held[amountKey];
  const minor = typeof raw === "number" && Number.isFinite(raw) ? raw : null;
  const note =
    noteKey === undefined ? "" : typeof held[noteKey] === "string" ? String(held[noteKey]) : "";
  return { minor, note: note === "" ? null : note };
}
